import Foundation

/// Optional per-product overrides, read from `cefapp.json` next to the
/// product target's sources.
struct CefAppConfig: Decodable {
    var bundleIdentifier: String?
    var displayName: String?
    var minimumSystemVersion: String?
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
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
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
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
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
