import Foundation

/// Optional per-product overrides, read from `cefapp.json` next to the
/// product target's sources (DESIGN.md §Plugin).
struct CefAppConfig: Decodable {
    var bundleIdentifier: String?
    var displayName: String?
    var minimumSystemVersion: String?
    /// Codesigning identity ("-" = ad-hoc). Precedence: --sign flag >
    /// cefapp.json > auto-detected identity.
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

/// Assembles a runnable macOS .app bundle per DESIGN.md pinned facts:
/// main executable, generated Info.plist, the converted CEF framework, five
/// helper apps (same binary, load-bearing names), then codesign inside-out
/// (framework → helpers → main app) with the chosen identity ("-" = ad-hoc).
struct AppBundler {
    /// Helper suffix → bundle-id suffix. Order is the signing order.
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

    @discardableResult
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

        // Main executable.
        try fm.copyItem(at: mainExecutable, to: macOS.appendingPathComponent(appName))

        // Main Info.plist + PkgInfo.
        try writePlist(mainInfoPlist(), to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        // CEF framework — copy preserving the versioned-bundle symlinks.
        let frameworkDest = frameworks.appendingPathComponent(frameworkSource.lastPathComponent)
        try Shell.runChecked(
            "/bin/cp", ["-R", frameworkSource.path, frameworkDest.path],
            hint: "Could not copy the CEF framework into the app bundle. Check disk space and permissions."
        )

        // Five helper apps.
        var helperAppURLs: [URL] = []
        for helper in Self.helpers {
            helperAppURLs.append(try makeHelperApp(
                in: frameworks, suffix: helper.suffix, bundleIDSuffix: helper.bundleIDSuffix
            ))
        }

        // Codesign, inside-out: framework first, then helpers, then the app.
        try codesign(frameworkDest)
        for helperApp in helperAppURLs { try codesign(helperApp) }
        try codesign(appURL)

        return appURL
    }

    // MARK: - Helpers

    private func makeHelperApp(in frameworks: URL, suffix: String?, bundleIDSuffix: String) throws -> URL {
        let fm = FileManager.default
        // Names are load-bearing: "<App> Helper" / "<App> Helper (Suffix)".
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
            // Required by CEF/Chromium on macOS.
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
            // No dock icon / app switcher entry for helper processes.
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
        // No hardened runtime (it would break dlopen of the CEF framework
        // without extra entitlements); --timestamp=none keeps real-identity
        // signing fast and offline-safe.
        try Shell.runChecked(
            "/usr/bin/codesign",
            ["--force", "--timestamp=none", "--sign", signingIdentity, path.path],
            hint: signingIdentity == "-"
                ? "Ad-hoc signing requires no certificates; if this fails, the bundle layout may be invalid " +
                  "(codesign is picky about framework symlinks). Re-run 'swift package cef download' to rebuild the framework."
                : "Check that the identity '\(signingIdentity)' is valid ('security find-identity -v -p codesigning') " +
                  "and that its private key is accessible, or pass '--sign -' for ad-hoc signing."
        )
    }
}
