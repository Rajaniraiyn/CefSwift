import Foundation

/// Assembles a runnable .app from a SwiftPM build, for `swift package cef
/// bundle`: the main executable, its resource bundles and libraries, and its
/// Info.plist; then what Chromium needs, with ``CefEmbedder``, which the
/// Xcode build phase runs too; then signs the app's own libraries, its
/// resource bundles and the app. See docs/bundling.md.
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
    let helper: HelperLink.Products  // compiled helper and startup library
    let frameworkSource: URL         // converted framework inside .cef/dist
    let outputDirectory: URL
    let identity: SigningIdentity
    /// Info.plist keys and entitlements from cefapp.json (DistributionPlan).
    let plan: DistributionPlan
    /// What the app keeps of the framework (cefapp.json `cef`).
    let trim: FrameworkTrimPolicy
    /// Embedded as Contents/embedded.provisionprofile.
    let provisioningProfile: URL?
    /// A keychain to find the identity in (`codesign --keychain`).
    let signingKeychain: String?
    /// Where the entitlements files passed to codesign are written.
    let workDirectory: URL
    /// Chrome extensions the app ships (cefapp.json `extensions`).
    var extensions: [URL] = []

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
        // Where CefSwift's targets, Xcode's Bundle.module and that of
        // SwiftPM's Swift Build system look: Bundle.main.resourceURL.
        // (SwiftPM's older native build system, Swift 6.1's default, looks
        // in the app's root, which signing forbids.)
        var resourceBundles: [URL] = []
        if !product.resourceBundles.isEmpty {
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        }
        for bundle in product.resourceBundles {
            let destination = resources.appendingPathComponent(bundle.lastPathComponent)
            try CefEmbedder.copyPreservingLinks(bundle, to: destination)
            resourceBundles.append(destination)
        }
        var libraries: [URL] = []
        for library in product.libraries {
            let destination = frameworks.appendingPathComponent(library.lastPathComponent)
            try CefEmbedder.copyPreservingLinks(library, to: destination)
            libraries.append(destination)
        }

        let infoPlist = mainInfoPlist()
        try Plist.write(infoPlist, to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        if let provisioningProfile {
            try fm.copyItem(at: provisioningProfile, to: contents.appendingPathComponent("embedded.provisionprofile"))
        }

        // Find libraries in the bundle, never in the build directory.
        try CefEmbedder.fixRunPaths(of: executable, adding: libraries.isEmpty ? nil : "@executable_path/../Frameworks")
        for library in libraries {
            if library.pathExtension == "framework" {
                let binary = library.appendingPathComponent(library.deletingPathExtension().lastPathComponent)
                try CefEmbedder.fixRunPaths(of: binary.resolvingSymlinksInPath(), adding: "@loader_path/../../..")
            } else {
                try CefEmbedder.fixRunPaths(of: library, adding: "@loader_path")
            }
        }

        let embedder = CefEmbedder(
            executableName: appName, bundleIdentifier: bundleIdentifier,
            minimumSystemVersion: minimumSystemVersion, version: version, build: build, helper: helper,
            frameworkSource: frameworkSource, identity: identity, plan: plan, trim: trim,
            signingKeychain: signingKeychain, workDirectory: workDirectory, extensions: extensions)
        let signer = try embedder.embed(into: contents, appInfoPlist: infoPlist,
                                        architectures: product.architectures).signer

        for library in libraries {
            try signer.sign(library, isLibrary: true)
        }
        // A resource bundle with an Info.plist is signed like code; a flat
        // one is sealed as resources by the app's signature.
        for bundle in resourceBundles
        where fm.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
            try signer.sign(bundle, isLibrary: true)
        }
        try signer.sign(app, entitlements: plan.appEntitlements, name: "app")
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
            "NSHighResolutionCapable": .bool(true),
            "NSSupportsAutomaticGraphicsSwitching": .bool(true),
        ]
        var info = Plist.merge(Plist.merge(base, CefInfoPlist.required), plan.appInfoPlist)
        // Localized resource bundles make the app localized: say so, so that
        // macOS picks the app's language, and Chromium's with it, from
        // these (CefRuntime.Localization.application).
        let localizations = FrameworkTrim.resourceLocalizations(in: product.resourceBundles)
        if info["CFBundleLocalizations"] == nil, !localizations.isEmpty {
            info["CFBundleLocalizations"] = .array(localizations.map { .string($0) })
        }
        return info
    }
}

/// The Info.plist keys every CefSwift app needs, whoever builds it.
enum CefInfoPlist {
    static let required: PlistDictionary = [
        // CefSwift creates its CefApplication subclass at launch, before
        // anything else uses NSApp.
        "NSPrincipalClass": .string("NSApplication"),
        // Chromium's allocator does not work with the nano malloc zone.
        "LSEnvironment": .dictionary(["MallocNanoZone": .string("0")]),
    ]
}
