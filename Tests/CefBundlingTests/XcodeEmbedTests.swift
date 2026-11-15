import Foundation
import Testing
@testable import CefBundling

// The Xcode build phase (`cefswift embed`) driven by a fake Xcode build
// environment: what it reads from Xcode's build settings, the app's
// Info.plist and entitlements, and what it decides from them.

/// A temporary directory laid out as Xcode lays out a build of `App.app`.
private struct FakeXcodeBuild {
    let root: URL
    var app: URL { root.appendingPathComponent("Products/App.app") }
    var temp: URL { root.appendingPathComponent("Intermediates/App.build") }
    var infoPlist: URL { app.appendingPathComponent("Contents/Info.plist") }
    var xcent: URL { temp.appendingPathComponent("App.app.xcent") }

    init(info: PlistDictionary = [:], entitlements: PlistDictionary? = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var base: PlistDictionary = [
            "CFBundleExecutable": .string("App"),
            "CFBundleIdentifier": .string("com.example.app"),
            "CFBundleShortVersionString": .string("2.0"),
            "CFBundleVersion": .string("7"),
            "LSMinimumSystemVersion": .string("15.0"),
        ]
        for (key, value) in info { base[key] = value }
        try Plist.write(base, to: infoPlist)
        if let entitlements { try Plist.write(entitlements, to: xcent) }
    }

    /// The build settings Xcode exports to a Run Script phase.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "ACTION": "build",
            "CODESIGNING_FOLDER_PATH": app.path,
            "TARGET_BUILD_DIR": app.deletingLastPathComponent().path,
            "WRAPPER_NAME": "App.app",
            "WRAPPER_EXTENSION": "app",
            "FULL_PRODUCT_NAME": "App.app",
            "INFOPLIST_PATH": "App.app/Contents/Info.plist",
            "EXECUTABLE_NAME": "App",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
            "TARGET_TEMP_DIR": temp.path,
            "PROJECT_DIR": root.path,
            "ARCHS": "arm64",
            "ONLY_ACTIVE_ARCH": "NO",
            "EXPANDED_CODE_SIGN_IDENTITY": "-",
            "EXPANDED_CODE_SIGN_IDENTITY_NAME": "-",
            "ENABLE_HARDENED_RUNTIME": "NO",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "CEFSWIFT_PACKAGE_DIR": "/CefSwift",
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct XcodeEmbedTests {
    @Test func readsTheBuildFromXcodesSettings() throws {
        let fake = try FakeXcodeBuild()
        defer { fake.remove() }
        let build = try XcodeEmbed(environment: fake.environment()).build()
        #expect(build.app == fake.app)
        #expect(build.executableName == "App")
        #expect(build.platform == "macosarm64")
        #expect(build.entitlementsURL == fake.xcent)
        #expect(build.cacheDirectory.path == fake.root.appendingPathComponent(".cef").path)
        #expect(build.manifest.path == "/CefSwift/CEF_VERSION.json")
        #expect(build.scratchDirectory == fake.temp.appendingPathComponent("CefSwift"))

        // The active architecture of a Debug build; CEF_… overrides.
        let debug = try XcodeEmbed(environment: fake.environment([
            "ARCHS": "arm64 x86_64", "ONLY_ACTIVE_ARCH": "YES", "NATIVE_ARCH_ACTUAL": "x86_64",
            "CEF_CACHE_DIR": "/var/cef", "CEF_FLAVOR": "standard",
        ])).build()
        #expect(debug.platform == "macosx64")
        #expect(debug.cacheDirectory.path == "/var/cef")
        #expect(debug.flavor == "standard")
    }

    @Test func refusesWhatThePhaseCannotDo() throws {
        let fake = try FakeXcodeBuild()
        defer { fake.remove() }
        // A universal Release build: one CEF distribution has one architecture.
        let universal = #expect(throws: BundlingError.self) {
            try XcodeEmbed(environment: fake.environment(["ARCHS": "arm64 x86_64"])).build()
        }
        #expect(universal?.message.contains("ARCHS = $(NATIVE_ARCH_ACTUAL)") == true)
        let sandboxed = #expect(throws: BundlingError.self) {
            try XcodeEmbed(environment: fake.environment(["ENABLE_USER_SCRIPT_SANDBOXING": "YES"])).build()
        }
        #expect(sandboxed?.message.contains("ENABLE_USER_SCRIPT_SANDBOXING = NO") == true)
        #expect(throws: BundlingError.self) {
            try XcodeEmbed(environment: ["EXECUTABLE_NAME": "App"]).build()
        }
    }

    @Test func signsLikeXcode() {
        let adHoc = XcodeEmbed(environment: ["EXPANDED_CODE_SIGN_IDENTITY": "-"]).identity()
        #expect(adHoc == .adHoc)
        let unsigned = XcodeEmbed(environment: ["CODE_SIGNING_ALLOWED": "NO", "EXPANDED_CODE_SIGN_IDENTITY": "ABC"])
        #expect(unsigned.identity() == .adHoc)
        let team = XcodeEmbed(environment: [
            "EXPANDED_CODE_SIGN_IDENTITY": "0123456789ABCDEF0123456789ABCDEF01234567",
            "EXPANDED_CODE_SIGN_IDENTITY_NAME": "Apple Development: Jane Doe (PERSONAL01)",
            "DEVELOPMENT_TEAM": "TEAM123456",
        ]).identity()
        #expect(team.name == "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(team.kind == .development)
        #expect(team.teamIdentifier == "TEAM123456")
        let flags = XcodeEmbed(environment: ["OTHER_CODE_SIGN_FLAGS": "--keychain /k.keychain --timestamp"])
            .otherCodeSignFlags()
        #expect(flags.keychain == "/k.keychain")
        #expect(flags.timestamp == true)
    }

    @Test func helpersFollowTheAppsEntitlements() throws {
        // A Debug build: Xcode's get-task-allow, and camera access turned on
        // with ENABLE_RESOURCE_ACCESS_CAMERA.
        let fake = try FakeXcodeBuild(
            info: ["NSCameraUsageDescription": .string("Video calls.")],
            entitlements: ["com.apple.security.get-task-allow": .bool(true),
                           "com.apple.security.device.camera": .bool(true)])
        defer { fake.remove() }
        let embed = XcodeEmbed(environment: fake.environment())
        let settings = try embed.settings(build: try embed.build())
        let helpers = settings.plan.helperEntitlements
        #expect(helpers[.base]?["com.apple.security.device.camera"] == .bool(true))
        #expect(helpers[.renderer]?["com.apple.security.cs.allow-jit"] == .bool(true))
        // A debugger can attach to the helpers as it can to the app.
        for kind in HelperKind.allCases {
            #expect(helpers[kind]?["com.apple.security.get-task-allow"] == .bool(true))
        }
        #expect(settings.missingEntitlements.isEmpty)
        // Xcode's keys stay; CefSwift's required ones are added.
        #expect(settings.infoPlist["CFBundleIdentifier"] == .string("com.example.app"))
        #expect(settings.infoPlist["NSCameraUsageDescription"] == .string("Video calls."))
        #expect(settings.infoPlist["LSEnvironment"] == .dictionary(["MallocNanoZone": .string("0")]))
        #expect(settings.infoPlist["NSPrincipalClass"] == .string("NSApplication"))
    }

    @Test func theAppSandboxIsAnError() throws {
        let fake = try FakeXcodeBuild(entitlements: ["com.apple.security.app-sandbox": .bool(true)])
        defer { fake.remove() }
        let embed = XcodeEmbed(environment: fake.environment())
        let error = #expect(throws: BundlingError.self) { try embed.settings(build: try embed.build()) }
        #expect(error?.message.contains("ENABLE_APP_SANDBOX = NO") == true)
        #expect(error?.message.contains("MachPortRendezvousServer") == true)
    }

    @Test func aTeamlessHardenedBuildNeedsLibraryValidationOff() throws {
        let fake = try FakeXcodeBuild()
        defer { fake.remove() }
        let embed = XcodeEmbed(environment: fake.environment(["ENABLE_HARDENED_RUNTIME": "YES"]))
        let settings = try embed.settings(build: try embed.build())
        #expect(settings.missingEntitlements.map(\.key) == [Capability.disableLibraryValidation])
        #expect(settings.missingEntitlements.first?.reason.contains("RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION") == true)
        #expect(settings.plan.helperEntitlements[.gpu]?[Capability.disableLibraryValidation] == .bool(true))

        // With RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION, as Xcode signs it.
        let allowed = try FakeXcodeBuild(entitlements: [Capability.disableLibraryValidation: .bool(true)])
        defer { allowed.remove() }
        let allowedEmbed = XcodeEmbed(environment: allowed.environment(["ENABLE_HARDENED_RUNTIME": "YES"]))
        #expect(try allowedEmbed.settings(build: try allowedEmbed.build()).missingEntitlements.isEmpty)
    }

    @Test func capabilityNeedsAUsageDescriptionInXcodesTerms() throws {
        let fake = try FakeXcodeBuild()
        defer { fake.remove() }
        let embed = XcodeEmbed(environment: fake.environment(["CEF_CAPABILITIES": "microphone"]))
        let error = #expect(throws: BundlingError.self) { try embed.settings(build: try embed.build()) }
        #expect(error?.message.contains("INFOPLIST_KEY_") == true)
    }

    @Test func cefSettingsWinOverASharedCefappJSON() throws {
        let fake = try FakeXcodeBuild(info: ["NSMicrophoneUsageDescription": .string("Calls.")])
        defer { fake.remove() }
        let config = fake.root.appendingPathComponent("cefapp.json")
        try Data("""
        {
          "bundleIdentifier": "com.example.other",
          "capabilities": ["microphone", "defaultBrowser"],
          "cef": { "localizations": "all", "softwareGPUFallback": "exclude" },
        }
        """.utf8).write(to: config)
        let embed = XcodeEmbed(environment: fake.environment([
            "CEF_APP_CONFIG": "cefapp.json", "CEF_LOCALIZATIONS": "en fr",
        ]))
        let settings = try embed.settings(build: try embed.build())
        #expect(settings.trim.localizations == .list(["en", "fr"]))
        #expect(settings.trim.includesSoftwareGPU == false)
        // From cefapp.json's capabilities: the URL types, and the base
        // helper's microphone access.
        #expect(settings.infoPlist["CFBundleURLTypes"] != nil)
        #expect(settings.plan.helperEntitlements[.base]?["com.apple.security.device.audio-input"] == .bool(true))
        // Xcode's bundle identifier, not cefapp.json's.
        #expect(settings.infoPlist["CFBundleIdentifier"] == .string("com.example.app"))
        #expect(Log.line(ofKey: "bundleIdentifier", in: config) == 2)
    }

    @Test func diagnosticsReadAsXcodeIssues() {
        let file = URL(fileURLWithPath: "/p/cefapp.json")
        #expect(Log.format("warning", "w", file: file, line: 3, style: .xcode) == "/p/cefapp.json:3: warning: w")
        #expect(Log.format("error", "e", file: nil, line: nil, style: .xcode) == "error: e")
        #expect(Log.format("warning", "w", file: nil, line: nil, style: .plugin) == "[cef] warning: w")
    }

    // MARK: Incremental builds

    /// The stamp of an incremental build of `fake` with `extra` settings,
    /// as `run()` computes it, and the phase and build it was made for.
    private func embedStamp(_ fake: FakeXcodeBuild, _ extra: [String: String] = [:], tool: URL? = nil) throws
        -> (stamp: String, embed: XcodeEmbed, build: XcodeEmbed.Build, settings: XcodeEmbed.Settings) {
        let embed = XcodeEmbed(environment: fake.environment(extra))
        let build = try embed.build()
        let settings = try embed.settings(build: build)
        let helper = HelperLink.Products(executable: fake.root.appendingPathComponent("helper"),
                                         startupLibrary: fake.root.appendingPathComponent("startup"))
        let embedder = embed.embedder(build: build, settings: settings, frameworkSource: nil, helper: helper)
        let stamp = embed.stamp(
            cef: "156.0.28", build: build, settings: settings, embedder: embedder,
            appInfoPlist: XcodeEmbed.embeddingInfoPlist(settings.infoPlist, app: build.app), helper: helper,
            tool: tool ?? fake.root.appendingPathComponent("cefswift"))
        return (stamp, embed, build, settings)
    }

    /// The parts an embedded app has, and the stamp of the run that
    /// embedded them.
    private func markEmbedded(_ fake: FakeXcodeBuild, stamp: String, build: XcodeEmbed.Build) throws {
        let frameworks = fake.app.appendingPathComponent("Contents/Frameworks")
        for part in [BuiltProduct.cefFrameworkName, HelperLink.startupLibraryName]
            + HelperKind.allCases.map({ "\($0.appName(for: build.executableName)).app" }) {
            try FileManager.default.createDirectory(at: frameworks.appendingPathComponent(part), withIntermediateDirectories: true)
        }
        try Data(stamp.utf8).write(to: build.stampFile)
    }

    /// The review's case: a Debug build signs the helpers with
    /// get-task-allow; turning it off with the same identity must sign
    /// them again, though the entitlement keys stay the same.
    @Test func anEntitlementValueChangeEmbedsAgain() throws {
        let fake = try FakeXcodeBuild(entitlements: ["com.apple.security.get-task-allow": .bool(true)])
        defer { fake.remove() }
        let development = [
            "EXPANDED_CODE_SIGN_IDENTITY": "0123456789ABCDEF0123456789ABCDEF01234567",
            "EXPANDED_CODE_SIGN_IDENTITY_NAME": "Apple Development: Someone (ABCDE12345)", "DEVELOPMENT_TEAM": "ABCDE12345",
        ]
        let first = try embedStamp(fake, development)
        try markEmbedded(fake, stamp: first.stamp, build: first.build)
        #expect(!first.embed.needsEmbedding(build: first.build, stamp: try embedStamp(fake, development).stamp))

        try Plist.write(["com.apple.security.get-task-allow": .bool(false)], to: fake.xcent)
        let second = try embedStamp(fake, development)
        // What a key-only fingerprint could not tell apart.
        for kind in HelperKind.allCases {
            let before = first.settings.plan.helperEntitlements[kind] ?? [:]
            let after = second.settings.plan.helperEntitlements[kind] ?? [:]
            #expect(Set(before.keys) == Set(after.keys) && before != after, "\(kind)")
        }
        #expect(second.embed.needsEmbedding(build: second.build, stamp: second.stamp))
    }

    /// Every other input of trimming and signing changes the stamp; the
    /// same inputs keep it.
    @Test func everyEmbeddingInputIsInTheStamp() throws {
        let fake = try FakeXcodeBuild(info: ["NSCameraUsageDescription": .string("Calls.")])
        defer { fake.remove() }
        let base = try embedStamp(fake).stamp
        #expect(try embedStamp(fake).stamp == base)
        var changed: [String: String] = [:]

        // Signing.
        changed["identity"] = try embedStamp(fake, [
            "EXPANDED_CODE_SIGN_IDENTITY": "0123456789ABCDEF0123456789ABCDEF01234567",
            "EXPANDED_CODE_SIGN_IDENTITY_NAME": "Apple Development: Someone (ABCDE12345)", "DEVELOPMENT_TEAM": "ABCDE12345",
        ]).stamp
        changed["keychain"] = try embedStamp(fake, ["OTHER_CODE_SIGN_FLAGS": "--keychain /tmp/k.keychain"]).stamp
        changed["timestamp"] = try embedStamp(fake, ["OTHER_CODE_SIGN_FLAGS": "--timestamp"]).stamp
        changed["hardened runtime"] = try embedStamp(fake, ["ENABLE_HARDENED_RUNTIME": "YES"]).stamp
        // Trimming.
        changed["CEF_LOCALIZATIONS"] = try embedStamp(fake, ["CEF_LOCALIZATIONS": "en fr"]).stamp
        changed["CEF_SOFTWARE_GPU_FALLBACK"] = try embedStamp(fake, ["CEF_SOFTWARE_GPU_FALLBACK": "exclude"]).stamp
        // The tool, rebuilt.
        let tool = fake.root.appendingPathComponent("tool")
        try Data("one".utf8).write(to: tool)
        let toolBefore = try embedStamp(fake, tool: tool).stamp
        try Data("two!".utf8).write(to: tool)
        #expect(try embedStamp(fake, tool: tool).stamp != toolBefore, "tool")
        // cefapp.json's contents, even where the settings read the same.
        let config = fake.root.appendingPathComponent("cefapp.json")
        try Data(#"{ "capabilities": [] }"#.utf8).write(to: config)
        let configBefore = try embedStamp(fake, ["CEF_APP_CONFIG": "cefapp.json"]).stamp
        try Data(#"{ "capabilities": [], "usageDescriptions": { "NSCameraUsageDescription": "Other." } }"#.utf8).write(to: config)
        #expect(try embedStamp(fake, ["CEF_APP_CONFIG": "cefapp.json"]).stamp != configBefore, "cefapp.json")
        for (input, stamp) in changed { #expect(stamp != base, "\(input)") }

        // The app's localizations, from an .lproj directory as well as
        // its Info.plist: they decide which locale packs stay.
        try FileManager.default.createDirectory(
            at: fake.app.appendingPathComponent("Contents/Resources/fr.lproj"), withIntermediateDirectories: true)
        let localized = try embedStamp(fake).stamp
        #expect(localized != base, "localizations")
        // An Info.plist value the helpers copy.
        var info = try Plist.read(fake.infoPlist)
        info["NSCameraUsageDescription"] = .string("Video calls.")
        try Plist.write(info, to: fake.infoPlist)
        #expect(try embedStamp(fake).stamp != localized, "usage description")
    }

    @Test func argumentsParseLikeSwiftPMs() throws {
        var arguments = Arguments(["App.app", "--format=dmg", "--sign", "-", "--json", "--capability", "a",
                                   "--capability", "b", "--no-timestamp"])
        let format = arguments.option("format")
        let sign = arguments.option("sign")
        let json = arguments.flag("json")
        let capabilities = arguments.options("capability")
        let timestamp = try arguments.toggle("timestamp")
        let app = arguments.positional()
        #expect(format == "dmg")
        #expect(sign == "-")
        #expect(json)
        #expect(capabilities == ["a", "b"])
        #expect(timestamp == false)
        #expect(app == "App.app")
        #expect(arguments.remaining.isEmpty)
    }
}

/// The parts the Xcode build phase and `cef bundle` both put in an app,
/// with the real framework: needs `CEF_FRAMEWORK_PATH`, as the loader tests
/// do, and `xcrun clang` to make a stand-in executable and libraries.
@Suite struct CefEmbedderTests {
    static var framework: URL? {
        guard let path = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: path)
        if url.lastPathComponent == FrameworkLayout.frameworkName { url.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Versions/A").path) ? url : nil
    }

    private func compile(_ source: String, to output: URL, dynamicLibrary: Bool = false) throws {
        let file = output.deletingPathExtension().appendingPathExtension("c")
        try Data(source.utf8).write(to: file)
        var arguments = ["clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wl,-headerpad_max_install_names",
                         file.path, "-o", output.path]
        if dynamicLibrary { arguments += ["-dynamiclib", "-install_name", "@rpath/\(output.lastPathComponent)"] }
        try Shell.runChecked("/usr/bin/xcrun", arguments, hint: "clang failed")
    }

    @Test(.enabled(if: CefEmbedderTests.framework != nil, "Set CEF_FRAMEWORK_PATH to embed the real framework."))
    func embedsSignsAndPassesTheDoctor() throws {
        let fake = try FakeXcodeBuild()
        defer { fake.remove() }
        let work = fake.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let executable = fake.app.appendingPathComponent("Contents/MacOS/App")
        try compile("int main(void) { return 0; }", to: executable)
        let startup = work.appendingPathComponent("libcefswift_helper_startup.dylib")
        try compile("void cefswift_startup(void) {}", to: startup, dynamicLibrary: true)
        let helperBinary = work.appendingPathComponent("cefswift-helper")
        try compile("int main(void) { return 0; }", to: helperBinary)
        let helper = try HelperLink.prepare(startup: startup, helper: helperBinary, framework: Self.framework!,
                                            in: work.appendingPathComponent("helper"))

        let embed = XcodeEmbed(environment: fake.environment(["CEF_SOFTWARE_GPU_FALLBACK": "exclude"]))
        let settings = try embed.settings(build: try embed.build())
        let embedder = CefEmbedder(
            executableName: "App", bundleIdentifier: "com.example.app", minimumSystemVersion: "15.0",
            version: "2.0", build: "7", helper: helper, frameworkSource: Self.framework, identity: .adHoc,
            plan: settings.plan, trim: settings.trim, signingKeychain: nil,
            workDirectory: work.appendingPathComponent("signing"))
        let result = try embedder.embed(into: fake.app.appendingPathComponent("Contents"),
                                        appInfoPlist: settings.infoPlist, architectures: ["arm64"])
        #expect(result.trim.locales.kept == ["en"])

        let frameworks = fake.app.appendingPathComponent("Contents/Frameworks")
        for kind in HelperKind.allCases {
            let helperApp = frameworks.appendingPathComponent("\(kind.appName(for: "App")).app")
            let info = try Plist.read(helperApp.appendingPathComponent("Contents/Info.plist"))
            #expect(info["CFBundleIdentifier"] == .string("com.example.app" + kind.bundleIdentifierSuffix))
            #expect(info["CFBundleShortVersionString"] == .string("2.0"))
            let verify = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", helperApp.path])
            #expect(verify.exitCode == 0, "\(verify.stderr)")
        }
        #expect(!FileManager.default.fileExists(atPath: frameworks.appendingPathComponent(
            "\(BuiltProduct.cefFrameworkName)/Versions/A/Libraries/libvk_swiftshader.dylib").path))

        // cef doctor's checks, on the app as Xcode is about to sign it.
        var app = BundleFacts.Part(name: "App.app", path: fake.app.path, infoPlist: settings.infoPlist)
        app.kind = .adHoc
        let report = Doctor.evaluate(try DoctorInspector.inspect(fake.app, describingApp: app))
        let nested = report.sections.first { $0.name == "Nested code" }?.checks ?? []
        #expect(!nested.isEmpty)
        #expect(nested.allSatisfy { $0.status == .ok }, "\(nested.map { "\($0.title): \($0.detail)" })")
    }
}
