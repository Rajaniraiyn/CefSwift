import Foundation

/// Assembles a runnable .app: the main executable, its resource bundles and
/// libraries, its Info.plist, the CEF framework, the helpers' startup
/// library, and five helper apps sharing one binary; then signs them inside
/// out: the framework's libraries, the framework, the startup library, the
/// app's libraries and resource bundles, each helper, the app. See
/// docs/bundling.md.
///
/// The bundle is built in a staging directory beside the destination,
/// which it replaces only once every part is in place, runs on the
/// product's architectures and is signed. A failure leaves the previous
/// app as it was.
struct AppBundler {
    let appName: String              // bundle + executable name, e.g. "Browser"
    let displayName: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let version: String              // CFBundleShortVersionString
    let build: String                // CFBundleVersion
    let product: BuiltProduct        // the built executable, resources and libraries
    let helperExecutable: URL        // compiled helper binary (HelperBuilder)
    let helperStartupLibrary: URL    // the helper's startup library (HelperBuilder)
    let frameworkSource: URL         // converted framework inside .cef/dist
    let outputDirectory: URL
    let identity: SigningIdentity
    /// Info.plist keys and entitlements from cefapp.json (DistributionPlan).
    let plan: DistributionPlan
    /// Embedded as Contents/embedded.provisionprofile.
    let provisioningProfile: URL?
    /// A keychain to find the identity in (`codesign --keychain`).
    let signingKeychain: String?
    /// Where the entitlements files passed to codesign are written.
    let workDirectory: URL

    var appURL: URL { outputDirectory.appendingPathComponent("\(appName).app") }

    func assemble() throws -> URL {
        try FrameworkLayout.validate(framework: frameworkSource)
        try StagedDirectory.replace(appURL) { try assemble(at: $0) }
        return appURL
    }

    private func assemble(at app: URL) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let frameworks = contents.appendingPathComponent("Frameworks")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent(appName)
        try fm.copyItem(at: product.executable, to: executable)
        // SwiftPM's generated Bundle.module looks in Bundle.main.resourceURL
        // first.
        var resourceBundles: [URL] = []
        if !product.resourceBundles.isEmpty {
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        }
        for bundle in product.resourceBundles {
            let destination = resources.appendingPathComponent(bundle.lastPathComponent)
            try copyPreservingLinks(bundle, to: destination)
            resourceBundles.append(destination)
        }
        var libraries: [URL] = []
        for library in product.libraries {
            let destination = frameworks.appendingPathComponent(library.lastPathComponent)
            try copyPreservingLinks(library, to: destination)
            libraries.append(destination)
        }

        try Plist.write(mainInfoPlist(), to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        if let provisioningProfile {
            try fm.copyItem(at: provisioningProfile, to: contents.appendingPathComponent("embedded.provisionprofile"))
        }

        let frameworkDest = frameworks.appendingPathComponent(frameworkSource.lastPathComponent)
        try copyPreservingLinks(frameworkSource, to: frameworkDest)

        let startupLibrary = frameworks.appendingPathComponent(HelperBuilder.startupLibraryName)
        try fm.copyItem(at: helperStartupLibrary, to: startupLibrary)
        let helperApps = try HelperKind.allCases.map { ($0, try makeHelperApp(in: frameworks, kind: $0)) }

        // Find libraries in the bundle, never in the build directory.
        try fixRunPaths(of: executable, adding: libraries.isEmpty ? nil : "@executable_path/../Frameworks")
        for library in libraries {
            if library.pathExtension == "framework" {
                let binary = library.appendingPathComponent(library.deletingPathExtension().lastPathComponent)
                try fixRunPaths(of: binary.resolvingSymlinksInPath(), adding: "@loader_path/../../..")
            } else {
                try fixRunPaths(of: library, adding: "@loader_path")
            }
        }
        try fixRunPaths(of: startupLibrary, adding: nil)
        for (kind, helperApp) in helperApps {
            try fixRunPaths(of: helperApp.appendingPathComponent("Contents/MacOS/\(kind.appName(for: appName))"),
                            adding: nil)
        }
        try checkArchitectures(in: contents)

        // Inside out, each item before what contains it, and without
        // --deep. Every library a helper loads carries the app's identity,
        // which library validation under the hardened runtime requires;
        // CEF ships its libraries linker-signed ad hoc.
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        for library in try Self.machOFiles(in: frameworkDest.appendingPathComponent("Versions/A/Libraries")) {
            try codesign(library, entitlements: [:], isLibrary: true)
        }
        try codesign(frameworkDest, entitlements: [:], isLibrary: true)
        try codesign(startupLibrary, entitlements: [:], isLibrary: true)
        for library in libraries {
            try codesign(library, entitlements: [:], isLibrary: true)
        }
        // A resource bundle with an Info.plist is signed like code; a flat
        // one is sealed as resources by the app's signature.
        for bundle in resourceBundles
        where fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            try codesign(bundle, entitlements: [:], isLibrary: true)
        }
        for (kind, helperApp) in helperApps {
            try codesign(helperApp, entitlements: plan.helperEntitlements[kind] ?? [:], name: kind.rawValue)
        }
        try codesign(app, entitlements: plan.appEntitlements, name: "app")
    }

    // MARK: - Helpers

    private func makeHelperApp(in frameworks: URL, kind: HelperKind) throws -> URL {
        let fm = FileManager.default
        // Chromium finds helpers by these exact names.
        let helperName = kind.appName(for: appName)
        let helperApp = frameworks.appendingPathComponent("\(helperName).app")
        let contents = helperApp.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        try fm.copyItem(at: helperExecutable, to: macOS.appendingPathComponent(helperName))
        try Plist.write(
            helperInfoPlist(helperName: helperName, kind: kind),
            to: contents.appendingPathComponent("Info.plist")
        )
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        return helperApp
    }

    func mainInfoPlist() -> PlistDictionary {
        let base: PlistDictionary = [
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(appName),
            "CFBundleIdentifier": .string(bundleIdentifier),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(appName),
            "CFBundleDisplayName": .string(displayName),
            "CFBundlePackageType": .string("APPL"),
            "CFBundleShortVersionString": .string(version),
            "CFBundleVersion": .string(build),
            "LSMinimumSystemVersion": .string(minimumSystemVersion),
            "NSPrincipalClass": .string("NSApplication"),
            "NSHighResolutionCapable": .bool(true),
            "NSSupportsAutomaticGraphicsSwitching": .bool(true),
            // Chromium's allocator does not work with the nano malloc zone.
            "LSEnvironment": .dictionary(["MallocNanoZone": .string("0")]),
        ]
        return Plist.merge(base, plan.appInfoPlist)
    }

    private func helperInfoPlist(helperName: String, kind: HelperKind) -> PlistDictionary {
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
        return Plist.merge(Plist.merge(base, kind.infoPlist), plan.helperInfoPlist)
    }

    /// `cp -R`, which keeps a framework's symlinks.
    private func copyPreservingLinks(_ source: URL, to destination: URL) throws {
        try Shell.runChecked(
            "/bin/cp", ["-R", source.path, destination.path],
            hint: "Could not copy \(source.lastPathComponent) into the app bundle. Check disk space and permissions."
        )
    }

    /// Removes the run paths that point into the build machine's build
    /// directory or toolchain, and adds `runPath` when the binary lacks it.
    private func fixRunPaths(of binary: URL, adding runPath: String?) throws {
        guard let file = MachOFile(contentsOf: binary) else {
            throw CefPluginError("\(binary.path) is not a Mach-O file.")
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

    /// Every Mach-O file in the bundle must have the product's
    /// architectures.
    private func checkArchitectures(in contents: URL) throws {
        let root = contents.deletingLastPathComponent().path + "/"
        var mismatched: [String] = []
        for file in try Self.machOFiles(in: contents) {
            guard let architectures = MachOFile(contentsOf: file)?.architectures else { continue }
            if product.architectures.contains(where: { !architectures.contains($0) }) {
                mismatched.append("\(file.path.replacingOccurrences(of: root, with: "")) " +
                                  "(\(architectures.joined(separator: ", ")))")
            }
        }
        guard mismatched.isEmpty else {
            throw CefPluginError(
                "\(product.executable.lastPathComponent) is built for " +
                "\(product.architectures.joined(separator: ", ")), but these parts of the bundle are not:\n  " +
                mismatched.joined(separator: "\n  ") +
                "\n  Build every part for the same architecture, and bundle the CEF distribution for it " +
                "(--platform). The previous app, if any, is unchanged.")
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

    /// Signs one item. Libraries and the framework take no options or
    /// entitlements: those apply to executables, and a library runs with
    /// those of the process that loads it.
    private func codesign(_ path: URL, entitlements: PlistDictionary, name: String? = nil, isLibrary: Bool = false) throws {
        var arguments = ["--force", "--sign", identity.name]
        if plan.hardenedRuntime, !isLibrary { arguments += ["--options", "runtime"] }
        // A secure timestamp needs Apple's timestamp server; without one,
        // signing works offline.
        arguments.append(plan.secureTimestamp ? "--timestamp" : "--timestamp=none")
        if let signingKeychain { arguments += ["--keychain", signingKeychain] }
        if !entitlements.isEmpty {
            let file = workDirectory.appendingPathComponent("\(name ?? path.lastPathComponent).entitlements")
            try Plist.write(entitlements, to: file)
            arguments += ["--entitlements", file.path]
        }
        try Shell.runChecked(
            "/usr/bin/codesign", arguments + [path.path],
            hint: identity.isAdHoc
                ? "Ad-hoc signing needs no certificate, so the bundle layout is likely invalid. Run " +
                  "'swift package cef clean', then bundle again to re-download the framework."
                : "Check that the identity '\(identity.name)' is valid ('security find-identity -v -p codesigning') " +
                  "and that its private key is accessible, or pass '--sign -' for ad-hoc signing." +
                  (signingKeychain == nil ? "" : " SwiftPM's plugin sandbox can hide keychains that are not in " +
                      "the search list; add it with 'security list-keychains -d user -s …'.") +
                  (plan.secureTimestamp ? " A secure timestamp needs a network connection; --no-timestamp skips it." : "")
        )
    }
}
