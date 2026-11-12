import Foundation

/// Optional per-product overrides, read from `cefapp.json` next to the
/// product target's sources.
struct CefAppConfig: Decodable {
    var bundleIdentifier: String?
    var displayName: String?
    var minimumSystemVersion: String?
    /// `CFBundleShortVersionString`, the version users see. `--version`
    /// takes precedence.
    var version: String?
    /// `CFBundleVersion`, the build number. `--build` takes precedence.
    var build: String?
    /// The codesigning identity, or "-" for ad hoc. `--sign` takes
    /// precedence.
    var signingIdentity: String?

    static func load(near targetDirectory: URL?) -> CefAppConfig? {
        guard let targetDirectory else { return nil }
        let url = targetDirectory.appendingPathComponent("cefapp.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CefAppConfig.self, from: data)
        } catch {
            print("[cef] warning: ignoring malformed \(url.path): \(error)")
            return nil
        }
    }
}

/// Assembles a runnable .app: the main executable and its Info.plist, the CEF
/// framework, and five helper apps sharing one binary; then signs them
/// inside out — framework, helpers, app. See docs/bundling.md.
struct AppBundler {
    /// Each helper's name suffix and bundle identifier suffix.
    static let helpers: [(suffix: String?, bundleIDSuffix: String)] = [
        (nil, ".helper"),
        ("Alerts", ".helper.alerts"),
        ("GPU", ".helper.gpu"),
        ("Plugin", ".helper.plugin"),
        ("Renderer", ".helper.renderer"),
    ]

    let appName: String              // bundle + executable name, e.g. "Browser"
    let displayName: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let version: String              // CFBundleShortVersionString
    let build: String                // CFBundleVersion
    let mainExecutable: URL          // built product binary
    let helperExecutable: URL        // built cef-helper binary
    let frameworkSource: URL         // converted framework inside .cef/dist
    let outputDirectory: URL
    let signingIdentity: String      // codesign identity; "-" = ad-hoc

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

        try writePlist(mainInfoPlist(), to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        // `cp -R` keeps the framework's symlinks.
        let frameworkDest = frameworks.appendingPathComponent(frameworkSource.lastPathComponent)
        try Shell.runChecked(
            "/bin/cp", ["-R", frameworkSource.path, frameworkDest.path],
            hint: "Could not copy the CEF framework into the app bundle. Check disk space and permissions."
        )

        let helperAppURLs = try Self.helpers.map {
            try makeHelperApp(in: frameworks, suffix: $0.suffix, bundleIDSuffix: $0.bundleIDSuffix)
        }

        try codesign(frameworkDest)
        for helperApp in helperAppURLs { try codesign(helperApp) }
        try codesign(appURL)

        return appURL
    }

    // MARK: - Helpers

    private func makeHelperApp(in frameworks: URL, suffix: String?, bundleIDSuffix: String) throws -> URL {
        let fm = FileManager.default
        // Chromium finds helpers by these exact names.
        let helperName = suffix.map { "\(appName) Helper (\($0))" } ?? "\(appName) Helper"
        let helperApp = frameworks.appendingPathComponent("\(helperName).app")
        let contents = helperApp.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        try fm.copyItem(at: helperExecutable, to: macOS.appendingPathComponent(helperName))
        try writePlist(
            helperInfoPlist(helperName: helperName, bundleIDSuffix: bundleIDSuffix),
            to: contents.appendingPathComponent("Info.plist")
        )
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        return helperApp
    }

    private func mainInfoPlist() -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": appName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": appName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": minimumSystemVersion,
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            // Chromium's allocator does not work with the nano malloc zone.
            "LSEnvironment": ["MallocNanoZone": "0"],
        ]
    }

    private func helperInfoPlist(helperName: String, bundleIDSuffix: String) -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": helperName,
            "CFBundleIdentifier": bundleIdentifier + bundleIDSuffix,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": helperName,
            "CFBundleDisplayName": helperName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": minimumSystemVersion,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "LSUIElement": true,
            "LSFileQuarantineEnabled": true,
        ]
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0
        )
        try data.write(to: url)
    }

    private func codesign(_ path: URL) throws {
        // No hardened runtime: loading the framework would need entitlements.
        // No secure timestamp, so signing works offline.
        try Shell.runChecked(
            "/usr/bin/codesign",
            ["--force", "--timestamp=none", "--sign", signingIdentity, path.path],
            hint: signingIdentity == "-"
                ? "Ad-hoc signing needs no certificate, so the bundle layout is likely invalid. Run " +
                  "'swift package cef clean', then bundle again to re-download the framework."
                : "Check that the identity '\(signingIdentity)' is valid ('security find-identity -v -p codesigning') " +
                  "and that its private key is accessible, or pass '--sign -' for ad-hoc signing."
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
