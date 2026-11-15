import CryptoKit
import Foundation

/// `cefswift embed`: the Xcode build phase. Xcode builds, embeds and signs
/// the app as it always does; this phase, run by Scripts/xcode-embed.sh
/// after Xcode's own phases, adds what Chromium needs with the same
/// ``CefEmbedder`` that `swift package cef bundle` uses, signed with the
/// build's identity, and then checks the result with `cef doctor`'s
/// checks. Xcode signs the app afterwards.
///
/// Everything comes from the build settings the phase sees in its
/// environment: Xcode's own for what Xcode owns (bundle identifier,
/// version, signing identity, team, hardened runtime, the app's
/// entitlements and Info.plist), and `CEF_…` settings for what only
/// CefSwift has. `CEF_APP_CONFIG` names a cefapp.json to share those with
/// `swift package cef bundle`; a `CEF_…` setting wins over it.
struct XcodeEmbed {
    /// The build settings this phase reads, with what each maps to in
    /// cefapp.json. The Xcode column of docs/bundling.md's table.
    static let cefSettings: [(setting: String, key: String)] = [
        ("CEF_APP_CONFIG", "(the file itself)"),
        ("CEF_CAPABILITIES", "capabilities"),
        ("CEF_LOCALIZATIONS", "cef.localizations"),
        ("CEF_SOFTWARE_GPU_FALLBACK", "cef.softwareGPUFallback"),
        ("CEF_EXTENSIONS", "extensions"),
        ("CEF_HELPER_ENTITLEMENTS_HELPER", "helperEntitlements.helper"),
        ("CEF_HELPER_ENTITLEMENTS_ALERTS", "helperEntitlements.alerts"),
        ("CEF_HELPER_ENTITLEMENTS_GPU", "helperEntitlements.gpu"),
        ("CEF_HELPER_ENTITLEMENTS_PLUGIN", "helperEntitlements.plugin"),
        ("CEF_HELPER_ENTITLEMENTS_RENDERER", "helperEntitlements.renderer"),
        ("CEF_CACHE_DIR", "(.cef in the package, for swift package cef)"),
        ("CEF_MANIFEST", "(--manifest)"),
        ("CEF_FLAVOR", "(--flavor)"),
        ("CEF_DOCTOR", "(cef doctor)"),
        ("CEF_EMBED_FRAMEWORK", "(none)"),
    ]

    /// cefapp.json keys whose setting Xcode owns, and that setting.
    static let xcodeOwnedKeys: [(key: String, setting: String)] = [
        ("bundleIdentifier", "PRODUCT_BUNDLE_IDENTIFIER"),
        ("displayName", "INFOPLIST_KEY_CFBundleDisplayName"),
        ("version", "MARKETING_VERSION"),
        ("build", "CURRENT_PROJECT_VERSION"),
        ("minimumSystemVersion", "MACOSX_DEPLOYMENT_TARGET"),
        ("signingIdentity", "CODE_SIGN_IDENTITY"),
        ("teamIdentifier", "DEVELOPMENT_TEAM"),
        ("signingKeychain", "OTHER_CODE_SIGN_FLAGS (--keychain)"),
        ("hardenedRuntime", "ENABLE_HARDENED_RUNTIME"),
        ("timestamp", "OTHER_CODE_SIGN_FLAGS (--timestamp)"),
        ("entitlements", "CODE_SIGN_ENTITLEMENTS"),
        ("provisioningProfile", "PROVISIONING_PROFILE_SPECIFIER"),
        ("notarization", "Xcode's Organizer, or xcrun notarytool"),
    ]

    /// Capabilities Xcode turns on with an entitlement, which the helpers
    /// that run the feature need too.
    static let capabilitiesFromEntitlements: [(entitlement: String, capability: String)] = [
        ("com.apple.security.device.camera", "camera"),
        ("com.apple.security.device.audio-input", "microphone"),
    ]

    /// Build settings that give the app an entitlement a capability needs.
    static let entitlementSettings: [String: String] = [
        "com.apple.security.device.camera": "ENABLE_RESOURCE_ACCESS_CAMERA = YES",
        "com.apple.security.device.audio-input": "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES",
        "com.apple.security.personal-information.location": "ENABLE_RESOURCE_ACCESS_LOCATION = YES",
        "com.apple.security.device.bluetooth": "ENABLE_RESOURCE_ACCESS_BLUETOOTH = YES",
        "com.apple.security.device.usb": "ENABLE_RESOURCE_ACCESS_USB = YES",
        "com.apple.security.automation.apple-events": "ENABLE_RESOURCE_ACCESS_APPLE_EVENTS = YES",
        Capability.disableLibraryValidation: "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES",
    ]

    let environment: [String: String]

    func setting(_ name: String) -> String? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    func isYes(_ name: String) -> Bool { setting(name)?.uppercased() == "YES" }

    /// A path build setting, relative to the project's directory.
    func path(_ name: String) -> URL? {
        setting(name).map { path in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                relativeTo: URL(fileURLWithPath: setting("PROJECT_DIR") ?? FileManager.default.currentDirectoryPath,
                                isDirectory: true)).standardizedFileURL
        }
    }

    // MARK: - What the build is

    struct Build {
        var app: URL
        var executableName: String
        var infoPlistURL: URL
        var entitlementsURL: URL?
        var architectures: [String]
        var platform: String
        var cacheDirectory: URL
        var manifest: URL
        var flavor: String
        var packageDirectory: URL
        var scratchDirectory: URL
        var stampFile: URL
        var workDirectory: URL
    }

    func build() throws -> Build {
        guard let app = setting("CODESIGNING_FOLDER_PATH").map({ URL(fileURLWithPath: $0) })
                ?? zip2(setting("TARGET_BUILD_DIR"), setting("WRAPPER_NAME")).map({ URL(fileURLWithPath: $0).appendingPathComponent($1) })
        else {
            throw BundlingError("cefswift embed runs from a Run Script phase of an Xcode app target: " +
                                "CODESIGNING_FOLDER_PATH is not set. See docs/bundling.md#xcode.")
        }
        guard setting("WRAPPER_EXTENSION") ?? app.pathExtension == "app" else {
            throw BundlingError("\(app.lastPathComponent) is not an app; add the CefSwift phase to the app target.")
        }
        if isYes("ENABLE_USER_SCRIPT_SANDBOXING") {
            throw BundlingError(
                "User Script Sandboxing is on for this target, so the CefSwift phase cannot read the CEF cache " +
                "or write the helper apps. Set ENABLE_USER_SCRIPT_SANDBOXING = NO (Build Settings > User Script " +
                "Sandboxing).")
        }
        let infoPlistURL = zip2(setting("TARGET_BUILD_DIR"), setting("INFOPLIST_PATH"))
            .map { URL(fileURLWithPath: $0).appendingPathComponent($1) }
            ?? app.appendingPathComponent("Contents/Info.plist")
        let info = (try? Plist.read(infoPlistURL)) ?? [:]
        guard let executableName = setting("EXECUTABLE_NAME") ?? info["CFBundleExecutable"]?.stringValue else {
            throw BundlingError("EXECUTABLE_NAME is not set.")
        }
        // Debug builds have the active architecture only; Release builds
        // every one in ARCHS, unless ONLY_ACTIVE_ARCH.
        let archs: [String]
        if isYes("ONLY_ACTIVE_ARCH"), let active = setting("NATIVE_ARCH_ACTUAL") ?? setting("CURRENT_ARCH") {
            archs = [active]
        } else {
            archs = (setting("ARCHS") ?? "arm64").split(separator: " ").map(String.init)
        }
        let platform: String
        switch archs {
        case ["arm64"]: platform = "macosarm64"
        case ["x86_64"]: platform = "macosx64"
        default:
            throw BundlingError(
                "This build is for \(archs.joined(separator: " and ")), but CEF's distributions hold one " +
                "architecture each. Set ARCHS = $(NATIVE_ARCH_ACTUAL) for this target (see docs/bundling.md#xcode).")
        }
        guard let packageDirectory = setting("CEFSWIFT_PACKAGE_DIR").map({ URL(fileURLWithPath: $0) }) else {
            throw BundlingError("CEFSWIFT_PACKAGE_DIR is not set; run cefswift embed through Scripts/xcode-embed.sh.")
        }
        let tempDirectory = URL(fileURLWithPath: setting("TARGET_TEMP_DIR") ?? NSTemporaryDirectory())
        let entitlements = setting("FULL_PRODUCT_NAME").map { tempDirectory.appendingPathComponent("\($0).xcent") }
        return Build(
            app: app,
            executableName: executableName,
            infoPlistURL: infoPlistURL,
            entitlementsURL: entitlements.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            architectures: archs,
            platform: platform,
            cacheDirectory: path("CEF_CACHE_DIR")
                ?? URL(fileURLWithPath: setting("PROJECT_DIR") ?? ".").appendingPathComponent(".cef"),
            manifest: path("CEF_MANIFEST") ?? packageDirectory.appendingPathComponent("CEF_VERSION.json"),
            flavor: setting("CEF_FLAVOR") ?? "minimal",
            packageDirectory: packageDirectory,
            scratchDirectory: setting("CEFSWIFT_SCRATCH_DIR").map { URL(fileURLWithPath: $0) }
                ?? tempDirectory.appendingPathComponent("CefSwift"),
            stampFile: tempDirectory.appendingPathComponent("cefswift-embed.json"),
            workDirectory: tempDirectory.appendingPathComponent("CefSwiftEmbed"))
    }

    // MARK: - Signing

    /// The identity Xcode signs this build with, so that the parts this
    /// phase signs match the app.
    func identity() -> SigningIdentity {
        guard setting("CODE_SIGNING_ALLOWED")?.uppercased() != "NO",
              let identity = setting("EXPANDED_CODE_SIGN_IDENTITY"), identity != "-" else {
            return .adHoc
        }
        let name = setting("EXPANDED_CODE_SIGN_IDENTITY_NAME") ?? setting("CODE_SIGN_IDENTITY") ?? identity
        let kind = SignatureKind(certificateName: name)
        return SigningIdentity(name: identity, kind: kind == .adHoc ? .other : kind,
                               teamIdentifier: kind.hasAppleTeam ? setting("DEVELOPMENT_TEAM") : nil)
    }

    /// `--keychain <file>` and `--timestamp` from OTHER_CODE_SIGN_FLAGS.
    func otherCodeSignFlags() -> (keychain: String?, timestamp: Bool?) {
        let flags = (setting("OTHER_CODE_SIGN_FLAGS") ?? "").split(separator: " ").map(String.init)
        var keychain = setting("CODE_SIGN_KEYCHAIN")
        if let index = flags.firstIndex(of: "--keychain"), index + 1 < flags.count { keychain = flags[index + 1] }
        let timestamp: Bool? = flags.contains("--timestamp") ? true : flags.contains("--timestamp=none") ? false : nil
        return (keychain, timestamp)
    }

    // MARK: - Settings

    struct Settings {
        var config: CefAppConfig?
        var identity: SigningIdentity
        var keychain: String?
        var appEntitlements: PlistDictionary
        var plan: DistributionPlan
        var trim: FrameworkTrimPolicy
        /// What the app is missing that the plan needs: entitlement → why.
        var missingEntitlements: [(key: String, reason: String)]
        /// The Info.plist after this phase's additions.
        var infoPlist: PlistDictionary
    }

    /// The CEF settings and the plan, from the build settings, the app's
    /// Info.plist and entitlements as Xcode produced them, and cefapp.json.
    func settings(build: Build) throws -> Settings {
        let config = try path("CEF_APP_CONFIG").map { url -> CefAppConfig in
            guard let config = try CefAppConfig.load(near: nil, explicit: url) else {
                throw BundlingError("CEF_APP_CONFIG names \(url.path), which does not exist.")
            }
            return config
        }
        let info = try Plist.read(build.infoPlistURL)
        let bundleIdentifier = setting("PRODUCT_BUNDLE_IDENTIFIER") ?? info["CFBundleIdentifier"]?.stringValue ?? ""
        if let config { reportXcodeOwnedKeys(in: config, info: info, bundleIdentifier: bundleIdentifier) }

        let identity = identity()
        let flags = otherCodeSignFlags()
        let appEntitlements: PlistDictionary
        if let url = build.entitlementsURL {
            appEntitlements = try Plist.read(url)
        } else {
            appEntitlements = isYes("ENABLE_APP_SANDBOX") ? ["com.apple.security.app-sandbox": .bool(true)] : [:]
        }

        var settings = DistributionSettings(bundleIdentifier: bundleIdentifier, identity: identity)
        settings.signerManagesProfile = true
        settings.existingInfoPlistKeys = Set(info.keys)
        var capabilities = setting("CEF_CAPABILITIES").map { $0.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
            ?? config?.capabilities ?? []
        for (entitlement, capability) in Self.capabilitiesFromEntitlements
        where appEntitlements[entitlement]?.isGranting == true && !capabilities.contains(capability) {
            capabilities.append(capability)
        }
        settings.capabilities = capabilities
        settings.usageDescriptions = config?.usageDescriptions ?? [:]
        if let config, let infoPlist = config.infoPlist {
            settings.infoPlistOverlays.append(("\(config.source.lastPathComponent) infoPlist", infoPlist))
        }
        settings.appEntitlementsFile = (build.entitlementsURL?.lastPathComponent ?? "the app's entitlements", appEntitlements)
        for helper in HelperKind.allCases {
            let name = "CEF_HELPER_ENTITLEMENTS_\(helper.rawValue.uppercased())"
            if let url = path(name) ?? config?.helperEntitlements?[helper.rawValue].map({ config!.resolve($0) }) {
                settings.helperEntitlementFiles[helper] = (url.lastPathComponent, try Plist.read(url))
            }
        }
        settings.hardenedRuntime = isYes("ENABLE_HARDENED_RUNTIME")
        settings.secureTimestamp = flags.timestamp
        let plan: DistributionPlan
        do {
            plan = try settings.plan()
        } catch let error as BundlingError {
            throw BundlingError(Self.xcodeWording(error.message))
        }
        // The app's entitlements are Xcode's, so the plan's note that it
        // adds disable-library-validation to them does not apply; a missing
        // one is an error below.
        for warning in plan.warnings where !warning.hasPrefix("the hardened runtime with") {
            Log.warning(Self.xcodeWording(warning))
        }

        // The app's entitlements are Xcode's: say what the plan needs that
        // they lack, and where to set it.
        var missing: [(String, String)] = []
        for (key, value) in plan.appEntitlements.sorted(by: { $0.key < $1.key })
        where value.isGranting && appEntitlements[key]?.isGranting != true && key != "com.apple.security.get-task-allow" {
            missing.append((key, Self.entitlementSettings[key].map { "set \($0)" } ?? "add it to CODE_SIGN_ENTITLEMENTS"))
        }

        var trim = FrameworkTrimPolicy()
        if let config { trim = try config.trimPolicy(localizationsOption: nil, softwareGPUOption: nil) }
        if let value = setting("CEF_LOCALIZATIONS") {
            trim.localizations = try FrameworkTrimPolicy.localizations(
                fromOption: value.split(separator: " ").joined(separator: ","))
        }
        if let value = setting("CEF_SOFTWARE_GPU_FALLBACK") {
            trim.includesSoftwareGPU = try FrameworkTrimPolicy.includesSoftwareGPU(
                from: value, source: "CEF_SOFTWARE_GPU_FALLBACK")
        }

        // Xcode's Info.plist wins; CefSwift's required keys and the
        // capabilities' fill in what it lacks.
        let infoPlist = Plist.merge(Plist.merge(CefInfoPlist.required, plan.appInfoPlist), info)
        return Settings(config: config, identity: identity, keychain: flags.keychain, appEntitlements: appEntitlements,
                        plan: plan, trim: trim, missingEntitlements: missing, infoPlist: infoPlist)
    }

    /// cefapp.json keys an Xcode build takes from Xcode instead: a warning,
    /// at the key's line, for each that disagrees with Xcode's value.
    private func reportXcodeOwnedKeys(in config: CefAppConfig, info: PlistDictionary, bundleIdentifier: String) {
        let xcodeValues: [String: String?] = [
            "bundleIdentifier": bundleIdentifier,
            "displayName": info["CFBundleDisplayName"]?.stringValue ?? info["CFBundleName"]?.stringValue,
            "version": info["CFBundleShortVersionString"]?.stringValue,
            "build": info["CFBundleVersion"]?.stringValue,
            "minimumSystemVersion": info["LSMinimumSystemVersion"]?.stringValue ?? setting("MACOSX_DEPLOYMENT_TARGET"),
        ]
        let configValues: [String: String?] = [
            "bundleIdentifier": config.bundleIdentifier, "displayName": config.displayName,
            "version": config.version, "build": config.build, "minimumSystemVersion": config.minimumSystemVersion,
        ]
        for (key, setting) in Self.xcodeOwnedKeys {
            guard let configValue = configValues[key] ?? nil else { continue }
            let xcodeValue = xcodeValues[key] ?? nil
            if configValue != xcodeValue {
                Log.warning("cefapp.json sets \(key) to \"\(configValue)\", but Xcode builds take it from " +
                            "\(setting)" + (xcodeValue.map { " (\"\($0)\")" } ?? "") + ".",
                            file: config.source, line: Log.line(ofKey: key, in: config.source))
            }
        }
    }

    /// Rewrites the plugin's wording ("cefapp.json signingIdentity",
    /// "--sign") into Xcode's.
    static func xcodeWording(_ message: String) -> String {
        var text = message
        for (from, to) in [
            ("(--sign or cefapp.json signingIdentity)", "(CODE_SIGN_IDENTITY)"),
            ("Add it to cefapp.json:\n  \"usageDescriptions\"", "Set INFOPLIST_KEY_<key> in Build Settings, or add to cefapp.json:\n  \"usageDescriptions\""),
            ("set provisioningProfile", "choose a provisioning profile in Signing & Capabilities"),
            ("(set teamIdentifier)", "(set DEVELOPMENT_TEAM)"),
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    // MARK: - Run

    func run() throws {
        Log.style = .xcode
        let build = try build()
        let settings = try settings(build: build)
        for (key, reason) in settings.missingEntitlements {
            let why = key == Capability.disableLibraryValidation
                ? "This build has the hardened runtime and no team, so library validation would refuse CEF's framework."
                : "A capability needs it; without it the feature fails silently under the hardened runtime."
            Log.error("The app lacks the entitlement \(key). \(why) Fix: \(reason).")
        }
        if !settings.missingEntitlements.isEmpty {
            throw BundlingError("The app's entitlements are missing what CefSwift needs (above).")
        }

        // Xcode's own Info.plist, with CefSwift's keys added.
        if (try? Plist.read(build.infoPlistURL)) != settings.infoPlist {
            try Plist.write(settings.infoPlist, to: build.infoPlistURL)
        }

        let manifest = try CefManifest.load(from: build.manifest)
        let existingFramework = build.app.appendingPathComponent("Contents/Frameworks/\(BuiltProduct.cefFrameworkName)")
        // CEF_EMBED_FRAMEWORK = NO: Xcode embeds the framework itself, from
        // a binary framework product the target depends on (the
        // XCFramework of pull request #27); this phase keeps that copy.
        var frameworkSource: URL?
        if setting("CEF_EMBED_FRAMEWORK")?.uppercased() != "NO" {
            let downloader = Downloader(cacheRoot: build.cacheDirectory)
            let dist = try downloader.ensure(manifest: manifest, platform: build.platform, flavor: build.flavor)
            frameworkSource = downloader.frameworkURL(in: dist)
        }

        let framework = frameworkSource ?? existingFramework
        let built = try buildHelper(build: build, framework: framework)
        let helper = HelperLink.Products(
            executable: build.workDirectory.appendingPathComponent("helper/\(HelperLink.helperProduct)"),
            startupLibrary: build.workDirectory.appendingPathComponent("helper/\(HelperLink.startupLibraryName)"))
        let embedder = embedder(build: build, settings: settings, frameworkSource: frameworkSource, helper: helper)
        let trimInfo = Self.embeddingInfoPlist(settings.infoPlist, app: build.app)
        let stamp = stamp(cef: manifest.cef, build: build, settings: settings, embedder: embedder,
                          appInfoPlist: trimInfo, helper: built, tool: Self.toolExecutable)
        if !needsEmbedding(build: build, stamp: stamp) {
            Log.info("Chromium's framework and helpers are up to date in \(build.app.lastPathComponent).")
        } else {
            _ = try HelperLink.prepare(startup: built.startupLibrary, helper: built.executable, framework: framework,
                                       in: helper.executable.deletingLastPathComponent())
            try embedder.embed(into: build.app.appendingPathComponent("Contents"), appInfoPlist: trimInfo,
                               architectures: build.architectures)
            try Data(stamp.utf8).write(to: build.stampFile)
            Log.info("Embedded Chromium's framework, \(HelperLink.startupLibraryName) and five helper apps, " +
                     "signed \(settings.identity.kind.displayName)" +
                     (settings.plan.hardenedRuntime ? " with the hardened runtime" : "") + ".")
        }

        if setting("CEF_DOCTOR")?.uppercased() != "NO" {
            try doctor(build: build, settings: settings)
        }
    }

    /// Builds the helper and its startup library with SwiftPM, in release,
    /// into a scratch directory of this build: they are CefSwift's code and
    /// the same for every configuration of the app. Returns the built files,
    /// before ``HelperLink/prepare(startup:helper:framework:in:)``.
    private func buildHelper(build: Build, framework: URL) throws -> HelperLink.Products {
        // The tool's own directory: Scripts/xcode-embed.sh built it with
        // the same package, scratch path and configuration.
        let binDirectory = setting("CEFSWIFT_BIN_DIR").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let startup = binDirectory.appendingPathComponent("lib\(HelperLink.startupProduct).dylib")
        let helper = binDirectory.appendingPathComponent(HelperLink.helperProduct)
        let flags = HelperLink.helperLinkerFlags(startupLibrary: startup, framework: framework)

        // SwiftPM takes seconds to find a build up to date; skip it when
        // the products are newer than the sources they are built from and
        // were linked against this framework.
        let stampFile = build.scratchDirectory.appendingPathComponent("cefswift-helper.flags")
        let stamp = flags.joined(separator: "\n")
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp,
           let builtAt = [startup, helper].compactMap(Self.modificationDate).min(),
           let newest = Self.newestSource(of: HelperLink.sourceDirectories, in: build.packageDirectory),
           newest < builtAt {
            return HelperLink.Products(executable: helper, startupLibrary: startup)
        }

        func swiftBuild(_ product: String, _ linkerFlags: [String]) throws {
            let arguments = ["swift", "build", "--package-path", build.packageDirectory.path,
                             "--scratch-path", build.scratchDirectory.path, "--configuration", "release",
                             "--product", product] + linkerFlags.flatMap { ["-Xlinker", $0] }
            Log.info("Building \(product)…")
            let status = try Shell.runStreaming("/usr/bin/xcrun", arguments, environment: Self.swiftEnvironment(environment))
            guard status == 0 else {
                throw BundlingError("'xcrun \(arguments.joined(separator: " "))' failed with exit code \(status).")
            }
        }
        try swiftBuild(HelperLink.startupProduct, HelperLink.startupLinkerFlags)
        try swiftBuild(HelperLink.helperProduct, flags)
        for product in [startup, helper] where !FileManager.default.fileExists(atPath: product.path) {
            throw BundlingError("SwiftPM built no \(product.path).")
        }
        try Data(stamp.utf8).write(to: stampFile)
        return HelperLink.Products(executable: helper, startupLibrary: startup)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The newest modification date of Package.swift and of the files under
    /// `directories` of the package; nil when one cannot be read.
    static func newestSource(of directories: [String], in package: URL) -> Date? {
        guard var newest = modificationDate(package.appendingPathComponent("Package.swift")) else { return nil }
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: package.appendingPathComponent(directory), includingPropertiesForKeys: [.contentModificationDateKey])
            else { return nil }
            for case let url as URL in enumerator {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > newest {
                    newest = date
                }
            }
        }
        return newest
    }

    /// The environment for SwiftPM: Xcode's build settings (SDKROOT, ARCHS,
    /// deployment targets and the like) would otherwise leak into its build.
    static func swiftEnvironment(_ environment: [String: String]) -> [String: String] {
        var clean: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "DEVELOPER_DIR", "TMPDIR", "USER", "LOGNAME"] {
            if let value = environment[key] { clean[key] = value }
        }
        return clean
    }

    /// The embedder for this build: Xcode's Info.plist and identity, the
    /// plan, and the helper this phase built.
    func embedder(build: Build, settings: Settings, frameworkSource: URL?, helper: HelperLink.Products) -> CefEmbedder {
        let info = settings.infoPlist
        return CefEmbedder(
            executableName: build.executableName,
            bundleIdentifier: info["CFBundleIdentifier"]?.stringValue ?? "",
            minimumSystemVersion: info["LSMinimumSystemVersion"]?.stringValue ?? setting("MACOSX_DEPLOYMENT_TARGET") ?? "14.0",
            version: info["CFBundleShortVersionString"]?.stringValue ?? "1.0",
            build: info["CFBundleVersion"]?.stringValue ?? "1",
            helper: helper,
            frameworkSource: frameworkSource,
            identity: settings.identity,
            plan: settings.plan,
            trim: settings.trim,
            signingKeychain: settings.keychain,
            workDirectory: build.workDirectory.appendingPathComponent("signing"),
            extensions: extensions(config: settings.config))
    }

    /// `CEF_EXTENSIONS`, paths relative to the project's directory separated
    /// by spaces, or else cefapp.json's `extensions`.
    func extensions(config: CefAppConfig?) -> [URL] {
        if let value = setting("CEF_EXTENSIONS") {
            let base = URL(fileURLWithPath: setting("PROJECT_DIR") ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            return value.split(separator: " ").map {
                URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL
            }
        }
        return config.map { config in (config.extensions ?? []).map(config.resolve) } ?? []
    }

    /// The Info.plist the embedder trims and makes the helpers' from: the
    /// app's, with the localizations macOS picks the app's language from,
    /// its .lproj directories as well as CFBundleLocalizations.
    static func embeddingInfoPlist(_ info: PlistDictionary, app: URL) -> PlistDictionary {
        var localizations = FrameworkTrim.appLocalizations(infoPlist: info)
        for localization in FrameworkTrim.resourceLocalizations(in: [app]) where !localizations.contains(localization) {
            localizations.append(localization)
        }
        var embedding = info
        embedding["CFBundleLocalizations"] = .array(localizations.map { .string($0) })
        return embedding
    }

    /// This tool's executable: a rebuilt tool may embed differently.
    static var toolExecutable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// Everything that decides the embedded parts, as text. When it is the
    /// last run's and the parts are in the app, an incremental build skips
    /// copying, trimming and signing; so it holds every input of those, in
    /// full: entitlement values and not only their keys, the Info.plist the
    /// helpers' are made from and the framework trimmed by (localizations
    /// included), the identity, keychain and signing flags, the CEF version
    /// and framework, the architectures, cefapp.json's bytes, and the
    /// helper, startup library and this tool as built.
    func stamp(cef: String, build: Build, settings: Settings, embedder: CefEmbedder, appInfoPlist: PlistDictionary,
               helper: HelperLink.Products, tool: URL) -> String {
        func fileStamp(_ url: URL) -> String {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? Int) ?? 0
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(date)"
        }
        let config = settings.config.map { config -> String in
            let data = (try? Data(contentsOf: config.source)) ?? Data()
            return config.source.path + "@" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let helperEntitlements = HelperKind.allCases.map { kind in
            "entitlements.\(kind.rawValue)=\(Self.canonical(.dictionary(settings.plan.helperEntitlements[kind] ?? [:])))"
        }
        let parts: [String] = [
            "cef=\(cef)", "framework=\(embedder.frameworkSource?.path ?? "embedded")", "flavor=\(build.flavor)",
            "architectures=\(build.architectures.joined(separator: ","))",
            "executable=\(embedder.executableName)", "id=\(embedder.bundleIdentifier)",
            "version=\(embedder.version)", "build=\(embedder.build)", "min=\(embedder.minimumSystemVersion)",
            "identity=\(settings.identity.name)", "kind=\(settings.identity.kind)",
            "team=\(settings.identity.teamIdentifier ?? "")", "keychain=\(settings.keychain ?? "")",
            "runtime=\(settings.plan.hardenedRuntime)", "timestamp=\(settings.plan.secureTimestamp)",
            "trim=\(settings.trim)", "config=\(config ?? "none")",
            "helper=\(fileStamp(helper.executable))", "startup=\(fileStamp(helper.startupLibrary))",
            "tool=\(tool.path)@\(fileStamp(tool))",
            "app.entitlements=\(Self.canonical(.dictionary(settings.appEntitlements)))",
            "info=\(Self.canonical(.dictionary(appInfoPlist)))",
        ] + helperEntitlements
        return parts.joined(separator: "\n") + "\n"
    }

    /// A property-list value as text, the same for the same value:
    /// dictionaries by sorted key, strings quoted.
    static func canonical(_ value: PlistValue) -> String {
        switch value {
        case .string(let string): return string.debugDescription
        case .bool(let bool): return bool ? "true" : "false"
        case .integer(let integer): return "\(integer)"
        case .real(let real): return "\(real)"
        case .date(let date): return "date(\(date.timeIntervalSince1970))"
        case .data(let data): return "data(\(data.base64EncodedString()))"
        case .array(let array): return "[" + array.map(canonical).joined(separator: ",") + "]"
        case .dictionary(let dictionary):
            return "{" + dictionary.keys.sorted().map { $0.debugDescription + ":" + canonical(dictionary[$0]!) }
                .joined(separator: ",") + "}"
        }
    }

    func needsEmbedding(build: Build, stamp: String) -> Bool {
        let fm = FileManager.default
        let frameworks = build.app.appendingPathComponent("Contents/Frameworks")
        let parts = [BuiltProduct.cefFrameworkName, HelperLink.startupLibraryName]
            + HelperKind.allCases.map { "\($0.appName(for: build.executableName)).app" }
        guard parts.allSatisfy({ fm.fileExists(atPath: frameworks.appendingPathComponent($0).path) }),
              let previous = try? String(contentsOf: build.stampFile, encoding: .utf8) else { return true }
        return previous != stamp
    }

    /// `cef doctor`'s checks on the app as Xcode is about to sign it, as
    /// Xcode errors and warnings. The app's own signature is the one Xcode
    /// gives it after this phase, so the app part is described, not read;
    /// distribution checks (Gatekeeper, notarization) wait for an exported
    /// app: run `cefswift doctor` on it.
    private func doctor(build: Build, settings: Settings) throws {
        var app = BundleFacts.Part(name: build.app.lastPathComponent, path: build.app.path, infoPlist: settings.infoPlist)
        app.kind = settings.identity.kind
        app.teamIdentifier = settings.identity.teamIdentifier
        app.isHardenedRuntime = settings.plan.hardenedRuntime
        app.hasSecureTimestamp = settings.plan.secureTimestamp
        app.entitlements = settings.appEntitlements
        var facts = try DoctorInspector.inspect(build.app, describingApp: app)
        // Xcode signs the app's own libraries and resource bundles after
        // this phase, with the app; check the parts this phase signed.
        let ours = [BuiltProduct.cefFrameworkName, HelperLink.startupLibraryName]
        facts.libraries = facts.libraries.filter { part in
            ours.contains(part.name) || part.path.contains("/\(BuiltProduct.cefFrameworkName)/")
        }
        // A build to run from Xcode searches the build directory for the
        // package's dynamic frameworks (PackageFrameworks): Xcode's own
        // design. An archive must not.
        if setting("ACTION") != "install", let products = setting("BUILT_PRODUCTS_DIR") {
            facts.linkageProblems.removeAll { $0.contains(products) }
        }
        let report = Doctor.evaluate(facts)
        var errors = 0
        for section in report.sections where !["Provisioning profile", "Distribution"].contains(section.name) {
            for check in section.checks where check.status == .error || check.status == .warning {
                let fix = check.fix.flatMap { $0.contains("cef bundle") || $0.contains("--") ? nil : " Fix: \($0)" } ?? ""
                let message = "cef doctor: \(check.title): \(check.detail)\(fix)"
                if check.status == .error {
                    errors += 1
                    Log.error(message)
                } else {
                    Log.warning(message)
                }
            }
        }
        if errors > 0 {
            throw BundlingError("cef doctor found \(errors) error(s) in \(build.app.lastPathComponent).")
        }
    }
}

private func zip2(_ a: String?, _ b: String?) -> (String, String)? {
    guard let a, let b else { return nil }
    return (a, b)
}
