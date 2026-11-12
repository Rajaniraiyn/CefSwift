import Foundation

/// Assembles a runnable .app: the main executable and its Info.plist, the CEF
/// framework, the helpers' startup library, and five helper apps sharing
/// one binary; then signs them inside out: the framework's libraries, the
/// framework, the startup library, each helper, the app. See
/// docs/bundling.md.
struct AppBundler {
    let appName: String              // bundle + executable name, e.g. "Browser"
    let displayName: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let version: String              // CFBundleShortVersionString
    let build: String                // CFBundleVersion
    let mainExecutable: URL          // built product binary
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
        let fm = FileManager.default
        try FrameworkLayout.validate(framework: frameworkSource)

        if fm.fileExists(atPath: appURL.path) {
            try fm.removeItem(at: appURL)
        }

        let contents = appURL.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let frameworks = contents.appendingPathComponent("Frameworks")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)

        try fm.copyItem(at: mainExecutable, to: macOS.appendingPathComponent(appName))

        try Plist.write(mainInfoPlist(), to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        if let provisioningProfile {
            try fm.copyItem(at: provisioningProfile, to: contents.appendingPathComponent("embedded.provisionprofile"))
        }

        // `cp -R` keeps the framework's symlinks.
        let frameworkDest = frameworks.appendingPathComponent(frameworkSource.lastPathComponent)
        try Shell.runChecked(
            "/bin/cp", ["-R", frameworkSource.path, frameworkDest.path],
            hint: "Could not copy the CEF framework into the app bundle. Check disk space and permissions."
        )

        let startupLibrary = frameworks.appendingPathComponent(HelperBuilder.startupLibraryName)
        try fm.copyItem(at: helperStartupLibrary, to: startupLibrary)
        let helperApps = try HelperKind.allCases.map { ($0, try makeHelperApp(in: frameworks, kind: $0)) }

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
        for (kind, helperApp) in helperApps {
            try codesign(helperApp, entitlements: plan.helperEntitlements[kind] ?? [:], name: kind.rawValue)
        }
        try codesign(appURL, entitlements: plan.appEntitlements, name: "app")

        return appURL
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

/// Reads a Mach-O executable's deployment target — the `minos` of its
/// `LC_BUILD_VERSION` (or `LC_VERSION_MIN_MACOSX`) load command, which
/// SwiftPM sets from the package's `platforms`.
enum MachOVersion {
    static func minimumSystemVersion(of executable: URL) -> String? {
        guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe), data.count >= 32 else { return nil }
        func uint32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }
        var base = 0
        // A universal binary: read the first architecture's slice.
        if uint32(0, bigEndian: true) == 0xCAFE_BABE {
            guard let offset = uint32(16, bigEndian: true) else { return nil }
            base = Int(offset)
        }
        guard uint32(base) == 0xFEED_FACF, let commandCount = uint32(base + 16) else { return nil }
        var offset = base + 32  // sizeof(mach_header_64)
        for _ in 0..<commandCount {
            guard let command = uint32(offset), let size = uint32(offset + 4), size > 0 else { return nil }
            switch command {
            case 0x32:  // LC_BUILD_VERSION: cmd, cmdsize, platform, minos
                return uint32(offset + 12).map(format)
            case 0x24:  // LC_VERSION_MIN_MACOSX: cmd, cmdsize, version
                return uint32(offset + 8).map(format)
            default:
                offset += Int(size)
            }
        }
        return nil
    }

    /// `xxxx.yy.zz` nibbles as "major.minor[.patch]".
    private static func format(_ version: UInt32) -> String {
        let major = version >> 16, minor = (version >> 8) & 0xFF, patch = version & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
