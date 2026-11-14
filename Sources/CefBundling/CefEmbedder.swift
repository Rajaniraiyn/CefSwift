import Foundation

/// Puts what Chromium needs into an app bundle that already has its
/// executable and Info.plist, and signs those parts, inside out: the
/// framework (trimmed), the helpers' startup library, and the five helper
/// apps sharing one binary. The app itself is signed by the caller, last:
/// `AppBundler` for `swift package cef bundle`, Xcode for the Xcode build
/// phase (`cefswift embed`). Both run this, so a bundle is the same either
/// way. See docs/bundling.md.
struct CefEmbedder {
    /// The app's executable name, which the helpers' names derive from.
    let executableName: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let version: String              // CFBundleShortVersionString
    let build: String                // CFBundleVersion
    let helper: HelperLink.Products
    /// The converted framework in the CEF cache, or nil when the app
    /// already has it in `Contents/Frameworks` (Xcode embedded it).
    let frameworkSource: URL?
    let identity: SigningIdentity
    let plan: DistributionPlan
    let trim: FrameworkTrimPolicy
    let signingKeychain: String?
    /// Where the entitlements files passed to codesign are written.
    let workDirectory: URL

    /// What `embed` printed about the framework, for the caller's log.
    struct Result {
        var trim: FrameworkTrim.Result
        var signer: Signer
    }

    /// Embeds into `contents` (`<App>.app/Contents`), whose Info.plist is
    /// `appInfoPlist`. `architectures` are the app executable's; every part
    /// must have them.
    @discardableResult
    func embed(into contents: URL, appInfoPlist: PlistDictionary, architectures: [String]) throws -> Result {
        let fm = FileManager.default
        let frameworks = contents.appendingPathComponent("Frameworks")
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)

        let framework = frameworks.appendingPathComponent(BuiltProduct.cefFrameworkName)
        if let frameworkSource {
            try FrameworkLayout.validate(framework: frameworkSource)
            try? fm.removeItem(at: framework)
            try Self.copyPreservingLinks(frameworkSource, to: framework)
        } else {
            try FrameworkLayout.validate(framework: framework)
        }
        // Before signing, which seals what is left.
        let trimmed = try FrameworkTrim.apply(
            trim, to: framework, appLocalizations: FrameworkTrim.appLocalizations(infoPlist: appInfoPlist),
            developmentLanguage: FrameworkTrim.developmentLanguage(infoPlist: appInfoPlist))
        print("[cef] Locale packs: \(trimmed.locales.kept.sorted().joined(separator: ", "))" +
              (trimmed.locales.removed.isEmpty ? "" : " (\(trimmed.locales.removed.count) others left out, " +
                  "\(FrameworkTrim.formatted(trimmed.removedLocaleBytes)))"))
        for mapping in trimmed.locales.mapping where mapping.pack == nil {
            Log.warning("Chromium has no locale pack for the localization \(mapping.localization); " +
                  "it shows its own interface in \(FrameworkTrim.developmentLanguage(infoPlist: appInfoPlist)) there.")
        }
        if !trim.includesSoftwareGPU {
            print("[cef] Software GPU fallback (SwiftShader) left out, \(FrameworkTrim.formatted(trimmed.removedSoftwareGPUBytes))")
        }

        let startupLibrary = frameworks.appendingPathComponent(HelperLink.startupLibraryName)
        try? fm.removeItem(at: startupLibrary)
        try fm.copyItem(at: helper.startupLibrary, to: startupLibrary)
        let helperApps = try HelperKind.allCases.map { ($0, try makeHelperApp(in: frameworks, kind: $0, appInfoPlist: appInfoPlist)) }

        try Self.fixRunPaths(of: startupLibrary, adding: nil)
        for (kind, helperApp) in helperApps {
            try Self.fixRunPaths(of: helperApp.appendingPathComponent("Contents/MacOS/\(kind.appName(for: executableName))"),
                                 adding: nil)
        }
        try Self.checkArchitectures(in: contents, required: architectures, executableName: executableName)

        // Inside out, each item before what contains it, and without
        // --deep. Every library a helper loads carries the app's identity,
        // which library validation under the hardened runtime requires;
        // CEF ships its libraries linker-signed ad hoc.
        let signer = Signer(identity: identity, plan: plan, keychain: signingKeychain, workDirectory: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        for library in try Self.machOFiles(in: framework.appendingPathComponent("Versions/A/Libraries")) {
            try signer.sign(library, isLibrary: true)
        }
        try signer.sign(framework, isLibrary: true)
        try signer.sign(startupLibrary, isLibrary: true)
        for (kind, helperApp) in helperApps {
            try signer.sign(helperApp, entitlements: plan.helperEntitlements[kind] ?? [:], name: kind.rawValue)
        }
        return Result(trim: trimmed, signer: signer)
    }

    private func makeHelperApp(in frameworks: URL, kind: HelperKind, appInfoPlist: PlistDictionary) throws -> URL {
        let fm = FileManager.default
        // Chromium finds helpers by these exact names.
        let helperName = kind.appName(for: executableName)
        let helperApp = frameworks.appendingPathComponent("\(helperName).app")
        try? fm.removeItem(at: helperApp)
        let contents = helperApp.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        try fm.copyItem(at: helper.executable, to: macOS.appendingPathComponent(helperName))
        try Plist.write(helperInfoPlist(helperName: helperName, kind: kind, appInfoPlist: appInfoPlist),
                        to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        return helperApp
    }

    func helperInfoPlist(helperName: String, kind: HelperKind, appInfoPlist: PlistDictionary) -> PlistDictionary {
        let base: PlistDictionary = [
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(helperName),
            "CFBundleIdentifier": .string(bundleIdentifier + kind.bundleIdentifierSuffix),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(helperName),
            "CFBundleDisplayName": .string(helperName),
            "CFBundlePackageType": .string("APPL"),
            "CFBundleShortVersionString": .string(version),
            "CFBundleVersion": .string(build),
            "LSMinimumSystemVersion": .string(minimumSystemVersion),
            "NSSupportsAutomaticGraphicsSwitching": .bool(true),
            "LSUIElement": .bool(true),
            "LSFileQuarantineEnabled": .bool(true),
        ]
        // Helpers that use a protected resource need its usage description
        // too, in case macOS attributes the access to the helper.
        let usageDescriptions = appInfoPlist.filter { $0.key.hasPrefix("NS") && $0.key.hasSuffix("UsageDescription") }
        return Plist.merge(Plist.merge(base, kind.infoPlist), usageDescriptions)
    }

    // MARK: - Shared steps

    /// Copies with `cp -R`, which keeps a framework's symlinks, cloning
    /// files where the volume can (`-c`).
    static func copyPreservingLinks(_ source: URL, to destination: URL) throws {
        try Shell.runChecked(
            "/bin/cp", ["-Rc", source.path, destination.path],
            hint: "Could not copy \(source.lastPathComponent) into the app bundle. Check disk space and permissions."
        )
    }

    /// Removes the run paths that point into the build machine's build
    /// directory or toolchain, and adds `runPath` when the binary lacks it.
    static func fixRunPaths(of binary: URL, adding runPath: String?) throws {
        guard let file = MachOFile(contentsOf: binary) else {
            throw BundlingError("\(binary.path) is not a Mach-O file.")
        }
        var arguments = BuiltProduct.buildMachineRunPaths(of: file).flatMap { ["-delete_rpath", $0] }
        if let runPath, file.slices.first?.runPaths.contains(runPath) != true {
            arguments += ["-add_rpath", runPath]
        }
        guard !arguments.isEmpty else { return }
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool"] + arguments + [binary.path],
            hint: "Could not change the run paths of \(binary.lastPathComponent); link it with " +
                "-headerpad_max_install_names to leave room for them.")
    }

    /// Every Mach-O file in the bundle must have the executable's
    /// architectures.
    static func checkArchitectures(in contents: URL, required: [String], executableName: String) throws {
        let root = contents.deletingLastPathComponent().path + "/"
        var mismatched: [String] = []
        for file in try machOFiles(in: contents) {
            guard let architectures = MachOFile(contentsOf: file)?.architectures else { continue }
            if required.contains(where: { !architectures.contains($0) }) {
                mismatched.append("\(file.path.replacingOccurrences(of: root, with: "")) " +
                                  "(\(architectures.joined(separator: ", ")))")
            }
        }
        guard mismatched.isEmpty else {
            throw BundlingError(
                "\(executableName) is built for \(required.joined(separator: ", ")), but these parts of the " +
                "bundle are not:\n  " + mismatched.joined(separator: "\n  ") +
                "\n  Build every part for the same architecture, and bundle the CEF distribution for it. " +
                "CEF's distributions hold one architecture each, so an app built for several (an Xcode " +
                "Release build with ARCHS = $(ARCHS_STANDARD)) needs ARCHS = $(NATIVE_ARCH_ACTUAL).")
        }
    }

    /// The Mach-O files under `directory`, found by their magic number.
    static func machOFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        else { return [] }
        let machOMagics: Set<[UInt8]> = [
            [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE],  // thin, little-endian
            [0xCA, 0xFE, 0xBA, 0xBE],                            // universal
        ]
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let magic = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            if machOMagics.contains(Array(magic)) { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// Signs one item at a time with the bundle's identity and the plan's
/// options.
struct Signer {
    let identity: SigningIdentity
    let plan: DistributionPlan
    let keychain: String?
    let workDirectory: URL

    /// Libraries and the framework take no options or entitlements: those
    /// apply to executables, and a library runs with those of the process
    /// that loads it.
    func sign(_ path: URL, entitlements: PlistDictionary = [:], name: String? = nil, isLibrary: Bool = false) throws {
        var arguments = ["--force", "--sign", identity.name]
        if plan.hardenedRuntime, !isLibrary { arguments += ["--options", "runtime"] }
        // A secure timestamp needs Apple's timestamp server; without one,
        // signing works offline.
        arguments.append(plan.secureTimestamp ? "--timestamp" : "--timestamp=none")
        if let keychain { arguments += ["--keychain", keychain] }
        if !entitlements.isEmpty {
            let file = workDirectory.appendingPathComponent("\(name ?? path.lastPathComponent).entitlements")
            try Plist.write(entitlements, to: file)
            arguments += ["--entitlements", file.path]
        }
        try Shell.runChecked(
            "/usr/bin/codesign", arguments + [path.path],
            hint: identity.isAdHoc
                ? "Ad-hoc signing needs no certificate, so the bundle layout is likely invalid. Delete the " +
                  "CEF cache (.cef) and build again to re-download the framework."
                : "Check that the identity '\(identity.name)' is valid ('security find-identity -v -p codesigning') " +
                  "and that its private key is accessible, or sign ad hoc ('-')." +
                  (keychain == nil ? "" : " SwiftPM's plugin sandbox can hide keychains that are not in " +
                      "the search list; add it with 'security list-keychains -d user -s …'.") +
                  (plan.secureTimestamp ? " A secure timestamp needs a network connection; --no-timestamp skips it." : "")
        )
    }
}
