import Foundation
import PackagePlugin

/// `swift package cef <bundle|embed|doctor|package|notarize|info>`.
///
/// Pre-approve the needed sandbox permissions on the command line:
///   swift package --allow-writing-to-package-directory \
///                 --allow-network-connections all \
///                 cef bundle --product Browser
@main
struct CefPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        guard let subcommand = arguments.first, subcommand != "--help", subcommand != "help" else {
            print(Self.usage)
            if arguments.first == nil {
                throw CefPluginError("Missing subcommand. See usage above.")
            }
            return
        }
        var extractor = ArgumentExtractor(Array(arguments.dropFirst()))

        switch subcommand {
        case "bundle":
            try await bundle(context: context, extractor: &extractor)
        case "embed":
            try embed(context: context, extractor: &extractor)
        case "info":
            try info(context: context, extractor: &extractor)
        case "doctor":
            try doctor(context: context, extractor: &extractor)
        case "package":
            try package(context: context, extractor: &extractor)
        case "notarize":
            try notarize(context: context, extractor: &extractor)
        default:
            print(Self.usage)
            throw CefPluginError(
                "Unknown subcommand '\(subcommand)'. Expected one of: bundle, embed, doctor, package, " +
                "notarize, info."
            )
        }
    }

    static let usage = """
    USAGE: swift package [--allow-writing-to-package-directory --allow-network-connections all] cef <subcommand>

    SUBCOMMANDS:
      bundle --product <Name> [--configuration debug|release] [--output <dir>] [--bundle-id <id>]
             [--name <DisplayName>] [--version <1.2.3>] [--build <42>]
             [--config <cefapp.json>] [--sign <identity|->] [--team-id <ID>] [--keychain <file>]
             [--capability <name>]... [--info-plist <file>]... [--entitlements <file>]
             [--provisioning-profile <file>] [--[no-]hardened-runtime] [--[no-]timestamp]
             [--package zip|dmg] [--notarize --keychain-profile <name>]
          Build <Name>, compile the helper, then assemble and sign <Name>.app
          (framework + five helper apps + Info.plists + entitlements).
          Settings come from cefapp.json next to the target's sources (or
          --config); options override it. --sign '-' signs ad hoc; without it,
          the first "Apple Development", else "Developer ID Application"
          identity, else ad hoc. The hardened runtime defaults to on for Apple
          team identities, the secure timestamp to on for Developer ID.
          --capability adds to cefapp.json "capabilities": \(Capability.all.map(\.name).joined(separator: ", ")).
          --package and --notarize run the commands below on the result.
          Default output: <packageDir>/dist/<Name>.app.

      embed <App.app> [--configuration debug|release] [--config <cefapp.json>]
            [--sign <identity|->] [--team-id <ID>] [--keychain <file>] [--capability <name>]...
            [--info-plist <file>]... [--[no-]hardened-runtime] [--[no-]timestamp] [--sign-app]
            [--entitlements <file>] [--provisioning-profile <file>]
          Add the framework, the helpers' startup library and the five helper
          apps to an app another tool built, such as an Xcode app target (run
          it from a Run Script build phase; see docs/bundling.md), and sign
          them. Names and identifiers come from the app's Info.plist. The app
          itself is signed only with --sign-app; Xcode signs it after the
          build phases.

      doctor <App.app> | --product <Name> [--json]
          Inspect a built bundle: signature, hardened runtime, each helper's
          entitlements, the embedded profile, Info.plist usage descriptions,
          Gatekeeper, stapling and quarantine; then, per feature, whether it
          works and what is missing. Exits non-zero when it finds errors.

      package <App.app> | --product <Name> [--format zip|dmg] [--sign <identity>] [--output <dir>]
          Wrap the app in a zip (ditto) or disk image (hdiutil; signed with
          --sign). Default: zip, next to the app.

      notarize <App.app> | --product <Name> --keychain-profile <name> [--format zip|dmg]
               [--sign <identity>]
          Package, submit with 'xcrun notarytool submit --wait', and staple the
          ticket. Create the profile once with 'xcrun notarytool store-credentials'.
          cefapp.json "notarization": {"keychainProfile", "format"} sets defaults.

      info
          Print the CEF framework the package graph resolved: its version,
          where SwiftPM got it, and its architectures.
    """

    // MARK: - bundle

    private func bundle(context: PluginContext, extractor: inout ArgumentExtractor) async throws {
        let productName = extractor.extractOption(named: "product").last
        let configurationName = extractor.extractOption(named: "configuration").last ?? "release"
        let outputPath = extractor.extractOption(named: "output").last
        let bundleIDOption = extractor.extractOption(named: "bundle-id").last
        let nameOption = extractor.extractOption(named: "name").last
        let versionOption = extractor.extractOption(named: "version").last
        let buildOption = extractor.extractOption(named: "build").last
        let configPath = extractor.extractOption(named: "config").last
        let signOption = extractor.extractOption(named: "sign").last
        let teamOption = extractor.extractOption(named: "team-id").last
        let keychainOption = extractor.extractOption(named: "keychain").last
        let capabilityOptions = extractor.extractOption(named: "capability")
        let infoPlistOptions = extractor.extractOption(named: "info-plist")
        let entitlementsOption = extractor.extractOption(named: "entitlements").last
        let profileOption = extractor.extractOption(named: "provisioning-profile").last
        let hardenedRuntime = try Self.toggle(&extractor, "hardened-runtime")
        let timestamp = try Self.toggle(&extractor, "timestamp")
        let packageFormat = extractor.extractOption(named: "package").last
        let notarize = extractor.extractFlag(named: "notarize") > 0
        let keychainProfileOption = extractor.extractOption(named: "keychain-profile").last
        // Undocumented: bundle prebuilt executables, or skip straight to the
        // `swift build` fallback.
        let testExe = extractor.extractOption(named: "_test-exe").last
        let testHelperExe = extractor.extractOption(named: "_test-helper-exe").last
        let forceCLIBuild = extractor.extractFlag(named: "_force-cli-build") > 0
        try rejectLeftovers(extractor)

        guard let productName else {
            throw CefPluginError(
                "Missing --product. Example: swift package --allow-writing-to-package-directory " +
                "--allow-network-connections all cef bundle --product Browser"
            )
        }
        let configuration = try Self.configuration(configurationName)

        // 1. Settings, checked before anything slow runs. cefapp.json sits
        // beside the target's sources.
        let appConfig = try CefAppConfig.load(
            near: targetDirectory(named: productName, in: context.package),
            explicit: configPath.map { packageRelative($0, context: context) })
        if let appConfig { print("[cef] Settings: \(appConfig.source.path)") }
        let appName = nameOption ?? productName
        let displayName = nameOption ?? appConfig?.displayName ?? productName
        let bundleID = bundleIDOption
            ?? appConfig?.bundleIdentifier
            ?? "com.cefswift.\(productName.lowercased())"
        let signing = try signingSetup(
            config: appConfig, context: context, bundleIdentifier: bundleID, signOption: signOption,
            teamOption: teamOption, keychainOption: keychainOption, capabilityOptions: capabilityOptions,
            infoPlistOptions: infoPlistOptions, entitlementsOption: entitlementsOption,
            profileOption: profileOption, hardenedRuntime: hardenedRuntime, timestamp: timestamp)
        let (identity, plan) = (signing.identity, signing.plan)
        let notarization = try notarizationSettings(
            notarize: notarize, keychainProfile: keychainProfileOption, format: packageFormat,
            config: appConfig, identity: identity, plan: plan)

        // 2. The framework SwiftPM fetched for the binary target.
        let artifact = try FrameworkArtifact.find(in: context.package)
        print("[cef] Framework: \(artifact.framework.path)")

        // 3. Build the product. If it depends on the ChromiumEmbeddedFramework
        // product, it links the framework, so dyld loads it at launch.
        let mainExecutable: URL
        if let testExe {
            mainExecutable = URL(fileURLWithPath: testExe)
            print("[cef] Bundling prebuilt \(mainExecutable.path)")
        } else {
            mainExecutable = try buildProduct(
                named: productName, kind: .executable, configuration: configuration, context: context,
                linkerFlags: [], forceCLIBuild: forceCLIBuild
            )
        }
        warnIfNotLinked(mainExecutable, target: productName)
        let minimumSystemVersion = appConfig?.minimumSystemVersion
            ?? MachOVersion.minimumSystemVersion(of: mainExecutable) ?? "14.0"

        // 4. Build the helper against the framework.
        let helper = try buildHelper(
            artifact: artifact, configuration: configuration, context: context,
            prebuilt: testHelperExe, forceCLIBuild: forceCLIBuild)

        let outputDirectory = outputPath.map { packageRelative($0, context: context) }
            ?? context.package.directoryURL.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 5. Assemble and sign.
        signing.printSummary()
        let bundler = AppBundler(
            appURL: outputDirectory.appendingPathComponent("\(appName).app"),
            appName: appName,
            displayName: displayName,
            bundleIdentifier: bundleID,
            minimumSystemVersion: minimumSystemVersion,
            version: versionOption ?? appConfig?.version ?? "1.0",
            build: buildOption ?? appConfig?.build ?? "1",
            mainExecutable: mainExecutable,
            helperExecutable: helper.executable,
            helperStartupLibrary: helper.startupLibrary,
            frameworkSource: artifact.framework,
            architectures: FrameworkArtifact.architectures(of: mainExecutable),
            identity: identity,
            plan: plan,
            provisioningProfile: identity.kind.hasAppleTeam ? signing.distribution.profileURL : nil,
            signingKeychain: signing.keychain,
            workDirectory: signing.workDirectory
        )
        let app = try bundler.assemble()
        let keychain = signing.keychain

        print("")
        print("[cef] Created \(app.path)")
        print("[cef] Run it with: open \"\(app.path)\"")
        print("[cef] Check it with: swift package cef doctor \"\(app.path)\"")

        if let notarization {
            let archive = try Notarizer.package(app, format: notarization.format, output: nil,
                                                identity: identity.name, keychain: keychain)
            if let keychainProfile = notarization.keychainProfile {
                try Notarizer.notarize(archive: archive, app: app, keychainProfile: keychainProfile)
            }
        }
    }

    // MARK: - embed

    /// Adds Chromium's parts to an app built elsewhere. From an Xcode Run
    /// Script phase, with the identity Xcode signs with:
    ///   swift package --package-path <CefSwift> --allow-writing-to-directory "$TARGET_BUILD_DIR" \
    ///       --allow-network-connections all cef embed "$CODESIGNING_FOLDER_PATH" \
    ///       --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}"
    private func embed(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        let configurationName = extractor.extractOption(named: "configuration").last ?? "release"
        let configPath = extractor.extractOption(named: "config").last
        let signOption = extractor.extractOption(named: "sign").last
        let teamOption = extractor.extractOption(named: "team-id").last
        let keychainOption = extractor.extractOption(named: "keychain").last
        let capabilityOptions = extractor.extractOption(named: "capability")
        let infoPlistOptions = extractor.extractOption(named: "info-plist")
        let entitlementsOption = extractor.extractOption(named: "entitlements").last
        let profileOption = extractor.extractOption(named: "provisioning-profile").last
        let hardenedRuntime = try Self.toggle(&extractor, "hardened-runtime")
        let timestamp = try Self.toggle(&extractor, "timestamp")
        let signApp = extractor.extractFlag(named: "sign-app") > 0
        let testHelperExe = extractor.extractOption(named: "_test-helper-exe").last
        let forceCLIBuild = extractor.extractFlag(named: "_force-cli-build") > 0
        let positional = extractor.remainingArguments.filter { !$0.hasPrefix("--") }
        guard positional.count == 1, let appPath = positional.first else {
            throw CefPluginError("Pass one app: swift package cef embed <App.app> [options].")
        }
        extractor = ArgumentExtractor(extractor.remainingArguments.filter { $0 != appPath })
        try rejectLeftovers(extractor)
        let configuration = try Self.configuration(configurationName)

        let app = packageRelative(appPath, context: context)
        let info = try Plist.read(app.appendingPathComponent("Contents/Info.plist"))
        guard let executableName = info["CFBundleExecutable"]?.stringValue,
              let bundleID = info["CFBundleIdentifier"]?.stringValue else {
            throw CefPluginError("\(app.path) needs CFBundleExecutable and CFBundleIdentifier in its Info.plist. " +
                                 "Run the phase after Xcode has written the app's Info.plist.")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        let appConfig = try configPath.map { try CefAppConfig.decode(Data(contentsOf: packageRelative($0, context: context)),
                                                                     source: packageRelative($0, context: context)) }
        let signing = try signingSetup(
            config: appConfig, context: context, bundleIdentifier: bundleID, signOption: signOption,
            teamOption: teamOption, keychainOption: keychainOption, capabilityOptions: capabilityOptions,
            infoPlistOptions: infoPlistOptions, entitlementsOption: entitlementsOption,
            profileOption: profileOption, hardenedRuntime: hardenedRuntime, timestamp: timestamp)

        let artifact = try FrameworkArtifact.find(in: context.package)
        print("[cef] Framework: \(artifact.framework.path)")
        if FileManager.default.fileExists(atPath: executable.path) {
            warnIfNotLinked(executable, target: executableName)
        }
        let helper = try buildHelper(
            artifact: artifact, configuration: configuration, context: context,
            prebuilt: testHelperExe, forceCLIBuild: forceCLIBuild)
        let appArchitectures = FrameworkArtifact.architectures(of: executable)
        let missing = appArchitectures.subtracting(FrameworkArtifact.architectures(of: helper.executable))
        if !missing.isEmpty {
            print("[cef] warning: the app is built for \(missing.sorted().joined(separator: ", ")) as well, but the " +
                  "helper only for this Mac's architecture; Chromium cannot start its processes there.")
        }

        signing.printSummary()
        let bundler = AppBundler(
            appURL: app,
            appName: executableName,
            displayName: info["CFBundleDisplayName"]?.stringValue ?? executableName,
            bundleIdentifier: bundleID,
            minimumSystemVersion: info["LSMinimumSystemVersion"]?.stringValue
                ?? MachOVersion.minimumSystemVersion(of: executable) ?? "14.0",
            version: info["CFBundleShortVersionString"]?.stringValue ?? "1.0",
            build: info["CFBundleVersion"]?.stringValue ?? "1",
            mainExecutable: nil,
            helperExecutable: helper.executable,
            helperStartupLibrary: helper.startupLibrary,
            frameworkSource: artifact.framework,
            architectures: appArchitectures,
            identity: signing.identity,
            plan: signing.plan,
            provisioningProfile: nil,
            signingKeychain: signing.keychain,
            workDirectory: signing.workDirectory
        )
        try bundler.embed(signApp: signApp)
        print("[cef] Added the framework, the startup library and five helper apps to \(app.path)")
        if !signApp, !signing.plan.appEntitlements.isEmpty {
            print("[cef] The app's own signature needs these entitlements (CODE_SIGN_ENTITLEMENTS in Xcode): " +
                  signing.plan.appEntitlements.keys.sorted().joined(separator: ", "))
        }
    }

    // MARK: - shared steps

    private static func configuration(_ name: String) throws -> PackageManager.BuildConfiguration {
        switch name {
        case "debug": return .debug
        case "release": return .release
        default: throw CefPluginError("Invalid --configuration '\(name)'. Use 'debug' or 'release'.")
        }
    }

    private struct SigningSetup {
        var identity: SigningIdentity
        var keychain: String?
        var workDirectory: URL
        var distribution: ResolvedDistribution
        var plan: DistributionPlan

        func printSummary() {
            print("[cef] Signing \(identity.kind.displayName)" +
                  (identity.teamIdentifier.map { ", team \($0)" } ?? "") +
                  (plan.hardenedRuntime ? ", hardened runtime" : "") +
                  (plan.secureTimestamp ? ", secure timestamp" : "") +
                  (distribution.profileURL.map { ", with \($0.lastPathComponent)" } ?? ""))
        }
    }

    /// The identity, the entitlements and Info.plist keys, and the
    /// provisioning profile's checks, before anything slow runs.
    private func signingSetup(
        config appConfig: CefAppConfig?, context: PluginContext, bundleIdentifier bundleID: String,
        signOption: String?, teamOption: String?, keychainOption: String?, capabilityOptions: [String],
        infoPlistOptions: [String], entitlementsOption: String?, profileOption: String?,
        hardenedRuntime: Bool?, timestamp: Bool?
    ) throws -> SigningSetup {
        let keychain = (keychainOption.map { packageRelative($0, context: context) }
            ?? appConfig?.signingKeychain.map { appConfig!.resolve($0) })?.path
        let workDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("signing")
        let (identity, certificateSHA1) = try Signing.resolveIdentity(
            flag: signOption, configValue: appConfig?.signingIdentity,
            teamIdentifier: teamOption ?? appConfig?.teamIdentifier, keychain: keychain,
            workDirectory: workDirectory)
        if identity.isAdHoc {
            print("[cef] note: an ad-hoc signed app loses its keychain \"Always Allow\" grant on every " +
                  "rebuild — see CefSafeStoragePolicy.")
        }
        let distribution = try distributionSettings(
            config: appConfig, context: context, bundleIdentifier: bundleID, identity: identity,
            certificateSHA1: certificateSHA1, capabilityOptions: capabilityOptions,
            infoPlistOptions: infoPlistOptions, entitlementsOption: entitlementsOption,
            profileOption: profileOption, hardenedRuntime: hardenedRuntime, timestamp: timestamp)
        let plan = try distribution.settings.plan()
        for warning in plan.warnings { print("[cef] warning: \(warning)") }
        if let profile = distribution.settings.profile, identity.kind.hasAppleTeam {
            let problems = profile.problems(
                bundleIdentifier: bundleID, identity: identity, certificateSHA1: certificateSHA1,
                entitlements: plan.appEntitlements)
            for problem in problems where !problem.isError { print("[cef] warning: \(problem.message)") }
            let errors = problems.filter(\.isError).map(\.message)
            if !errors.isEmpty {
                throw CefPluginError("The provisioning profile does not fit this bundle:\n  " +
                                     errors.joined(separator: "\n  "))
            }
        }
        return SigningSetup(identity: identity, keychain: keychain, workDirectory: workDirectory,
                            distribution: distribution, plan: plan)
    }

    private func buildHelper(
        artifact: FrameworkArtifact, configuration: PackageManager.BuildConfiguration, context: PluginContext,
        prebuilt: String?, forceCLIBuild: Bool
    ) throws -> HelperBuilder.Products {
        if let prebuilt {
            return .init(
                executable: URL(fileURLWithPath: prebuilt),
                startupLibrary: URL(fileURLWithPath: prebuilt).deletingLastPathComponent()
                    .appendingPathComponent(HelperBuilder.startupLibraryName))
        }
        return try HelperBuilder(
            framework: artifact.framework,
            workDirectory: context.pluginWorkDirectoryURL.appendingPathComponent("helper")
        ).build { product, kind, linkerFlags in
            try buildProduct(
                named: product, kind: kind, configuration: configuration, context: context,
                linkerFlags: linkerFlags, forceCLIBuild: forceCLIBuild)
        }
    }

    /// An app that does not link the framework still runs (CefKit loads it
    /// with `dlopen`), but holds about 12 MB of the framework's pointers as
    /// private memory (docs/architecture.md).
    private func warnIfNotLinked(_ executable: URL, target: String) {
        guard !FrameworkArtifact.isLinked(by: executable) else { return }
        print("[cef] warning: \(executable.lastPathComponent) does not link the CEF framework, so it loads it " +
              "after launch and keeps about 12 MB more private memory. Add " +
              ".product(name: \"\(FrameworkArtifact.targetName)\", package: \"CefSwift\") to the dependencies " +
              "of \(target) (in Xcode: add the \(FrameworkArtifact.targetName) package product to the app target).")
    }

    /// `--name` / `--no-name`: true, false, or nil when neither is given.
    private static func toggle(_ extractor: inout ArgumentExtractor, _ name: String) throws -> Bool? {
        let on = extractor.extractFlag(named: name) > 0
        let off = extractor.extractFlag(named: "no-\(name)") > 0
        if on && off { throw CefPluginError("Pass either --\(name) or --no-\(name), not both.") }
        return on ? true : off ? false : nil
    }

    private func packageRelative(_ path: String, context: PluginContext) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: context.package.directoryURL)
            .standardizedFileURL
    }

    /// The directory of a target's sources: the closest directory that holds
    /// all of them. (`Target.directoryURL` needs tools version 6.1.)
    private func targetDirectory(named name: String, in package: Package) -> URL? {
        guard let target = package.targets.first(where: { $0.name == name }) as? SourceModuleTarget else {
            return nil
        }
        let directories = target.sourceFiles.map { $0.url.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = directories.first else { return nil }
        for components in directories.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common))
    }

    private struct ResolvedDistribution {
        var settings: DistributionSettings
        var profileURL: URL?
    }

    /// Reads the files cefapp.json and the options name, with options taking
    /// precedence.
    private func distributionSettings(
        config: CefAppConfig?, context: PluginContext, bundleIdentifier: String, identity: SigningIdentity,
        certificateSHA1: String?, capabilityOptions: [String], infoPlistOptions: [String],
        entitlementsOption: String?, profileOption: String?, hardenedRuntime: Bool?, timestamp: Bool?
    ) throws -> ResolvedDistribution {
        var settings = DistributionSettings(bundleIdentifier: bundleIdentifier, identity: identity)
        settings.certificateSHA1 = certificateSHA1
        settings.capabilities = (config?.capabilities ?? []) + capabilityOptions
        settings.usageDescriptions = config?.usageDescriptions ?? [:]
        if let infoPlist = config?.infoPlist {
            settings.infoPlistOverlays.append(("\(config!.source.lastPathComponent) infoPlist", infoPlist))
        }
        for path in infoPlistOptions {
            let url = packageRelative(path, context: context)
            settings.infoPlistOverlays.append((url.path, try Plist.read(url)))
        }
        if let url = entitlementsOption.map({ packageRelative($0, context: context) })
            ?? config?.entitlements.map({ config!.resolve($0) }) {
            settings.appEntitlementsFile = (url.lastPathComponent, try Plist.read(url))
        }
        for (name, path) in config?.helperEntitlements ?? [:] {
            guard let helper = HelperKind(rawValue: name), let config else { continue }
            let url = config.resolve(path)
            settings.helperEntitlementFiles[helper] = (url.lastPathComponent, try Plist.read(url))
        }
        let profileURL = profileOption.map { packageRelative($0, context: context) }
            ?? config?.provisioningProfile.map { config!.resolve($0) }
        if let profileURL {
            settings.profile = try Signing.decodeProfile(at: profileURL)
        }
        settings.hardenedRuntime = hardenedRuntime ?? config?.hardenedRuntime
        settings.secureTimestamp = timestamp ?? config?.timestamp
        return ResolvedDistribution(settings: settings, profileURL: profileURL)
    }

    private struct NotarizationSettings {
        var format: Notarizer.Format
        var keychainProfile: String?
    }

    /// What `bundle --package/--notarize` asks for, checked up front so a
    /// long build does not end in a configuration error.
    private func notarizationSettings(
        notarize: Bool, keychainProfile: String?, format: String?, config: CefAppConfig?,
        identity: SigningIdentity, plan: DistributionPlan
    ) throws -> NotarizationSettings? {
        guard notarize || format != nil else { return nil }
        let formatName = format ?? config?.notarization?.format ?? "zip"
        guard let parsed = Notarizer.Format(rawValue: formatName) else {
            throw CefPluginError("Invalid package format '\(formatName)'. Use 'zip' or 'dmg'.")
        }
        guard notarize else { return NotarizationSettings(format: parsed, keychainProfile: nil) }
        guard let profile = keychainProfile ?? config?.notarization?.keychainProfile else {
            throw CefPluginError(
                "--notarize needs a notarytool keychain profile: pass --keychain-profile <name> or set " +
                "\"notarization\": {\"keychainProfile\": \"<name>\"} in cefapp.json. Create it once with " +
                "'xcrun notarytool store-credentials <name>'.")
        }
        guard identity.kind == .developerID, plan.hardenedRuntime, plan.secureTimestamp else {
            throw CefPluginError(
                "Notarization needs a Developer ID Application signature with the hardened runtime and a " +
                "secure timestamp; this bundle is signed \(identity.kind.displayName)" +
                (plan.hardenedRuntime ? "" : ", without the hardened runtime") +
                (plan.secureTimestamp ? "" : ", without a secure timestamp") + ".")
        }
        return NotarizationSettings(format: parsed, keychainProfile: profile)
    }

    // MARK: - doctor, package, notarize

    /// The app a subcommand works on: a path, or `--product` in `dist/`.
    private func appArgument(context: PluginContext, extractor: inout ArgumentExtractor, command: String) throws -> URL {
        let product = extractor.extractOption(named: "product").last
        let positional = extractor.remainingArguments.filter { !$0.hasPrefix("--") }
        if let path = positional.first {
            extractor = ArgumentExtractor(extractor.remainingArguments.filter { $0 != path })
            return packageRelative(path, context: context)
        }
        if let product {
            return context.package.directoryURL.appendingPathComponent("dist/\(product).app")
        }
        throw CefPluginError("Missing the app: swift package cef \(command) <App.app> (or --product <Name>).")
    }

    private func doctor(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        let json = extractor.extractFlag(named: "json") > 0
        let app = try appArgument(context: context, extractor: &extractor, command: "doctor")
        try rejectLeftovers(extractor)
        let report = Doctor.evaluate(try DoctorInspector.inspect(app))
        print(json ? try report.json() : report.text())
        if report.errorCount > 0 {
            throw CefPluginError("cef doctor found \(report.errorCount) error(s) in \(app.lastPathComponent).")
        }
    }

    private func package(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        let format = extractor.extractOption(named: "format").last ?? "zip"
        let sign = extractor.extractOption(named: "sign").last
        let keychain = extractor.extractOption(named: "keychain").last
        let output = extractor.extractOption(named: "output").last
        let app = try appArgument(context: context, extractor: &extractor, command: "package")
        try rejectLeftovers(extractor)
        guard let parsed = Notarizer.Format(rawValue: format) else {
            throw CefPluginError("Invalid --format '\(format)'. Use 'zip' or 'dmg'.")
        }
        _ = try Notarizer.package(app, format: parsed, output: output.map { packageRelative($0, context: context) },
                                  identity: sign, keychain: keychain)
    }

    private func notarize(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        let profile = extractor.extractOption(named: "keychain-profile").last
        let format = extractor.extractOption(named: "format").last ?? "zip"
        let sign = extractor.extractOption(named: "sign").last
        let keychain = extractor.extractOption(named: "keychain").last
        let app = try appArgument(context: context, extractor: &extractor, command: "notarize")
        try rejectLeftovers(extractor)
        guard let profile else {
            throw CefPluginError(
                "Missing --keychain-profile <name>. Create the profile once with " +
                "'xcrun notarytool store-credentials <name>' (an app-specific password or an App Store " +
                "Connect API key).")
        }
        guard let parsed = Notarizer.Format(rawValue: format) else {
            throw CefPluginError("Invalid --format '\(format)'. Use 'zip' or 'dmg'.")
        }
        if parsed == .dmg, sign == nil {
            throw CefPluginError("--format dmg needs --sign <Developer ID Application identity> to sign the disk image.")
        }
        let archive = try Notarizer.package(app, format: parsed, output: nil, identity: sign, keychain: keychain)
        try Notarizer.notarize(archive: archive, app: app, keychainProfile: profile)
    }

    /// Builds a product through SwiftPM and returns the built file. A
    /// product SwiftPM cannot build that way, such as one from a
    /// dependency, falls back to `swift build` in the package that
    /// declares it.
    private func buildProduct(
        named productName: String,
        kind: PackageManager.BuildResult.BuiltArtifact.Kind,
        configuration: PackageManager.BuildConfiguration,
        context: PluginContext,
        linkerFlags: [String],
        forceCLIBuild: Bool
    ) throws -> URL {
        print("[cef] Building product '\(productName)' (\(configuration))…")
        let fileName = kind == .dynamicLibrary ? "lib\(productName).dylib" : productName

        let proxyFailure: String
        if forceCLIBuild {
            proxyFailure = "skipped (--_force-cli-build)"
        } else {
            do {
                var parameters = PackageManager.BuildParameters(
                    configuration: configuration, logging: .concise, echoLogs: true)
                parameters.otherLinkerFlags = linkerFlags
                let result = try packageManager.build(.product(productName), parameters: parameters)
                let artifacts = result.builtArtifacts.filter { $0.kind == kind }
                if result.succeeded,
                   let artifact = artifacts.first(where: { $0.url.lastPathComponent == fileName })
                       ?? (kind == .executable ? artifacts.first : nil) {
                    return artifact.url
                }
                proxyFailure = result.succeeded ? "the build produced no \(fileName)" : result.logText
            } catch {
                proxyFailure = "\(error)"
            }
        }

        // The running `swift package` holds the lock on the invoking package's
        // .build directory, so the fallback builds into its own scratch path.
        // A product of a dependency, such as CefSwift's helper, builds in the
        // package that declares it.
        let providerRoot = HelperBuilder.isHelperProduct(productName)
            ? (HelperBuilder.cefSwiftPackageDirectory(in: context.package) ?? context.package.directoryURL)
            : context.package.directoryURL
        let configName = configuration == .release ? "release" : "debug"
        let scratch = context.pluginWorkDirectoryURL.appendingPathComponent("fallback-build")
        print("[cef] PackageManager build of '\(productName)' did not yield a binary; " +
              "falling back to 'swift build --package-path \(providerRoot.path)'…")
        let status = try Shell.runStreaming("/usr/bin/swift", [
            "build",
            // The plugin sandbox already confines the build, and a nested
            // sandbox cannot be applied inside it.
            "--disable-sandbox",
            "--package-path", providerRoot.path,
            "--scratch-path", scratch.path,
            "--configuration", configName,
            "--product", productName,
        ] + linkerFlags.flatMap { ["-Xlinker", $0] })
        let binary = scratch
            .appendingPathComponent(configName)
            .appendingPathComponent(fileName)
        guard status == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw CefPluginError(
                "Could not build product '\(productName)'.\n" +
                "  SwiftPM build: \(proxyFailure)\n" +
                "  CLI fallback ('swift build --package-path \(providerRoot.path) --product \(productName)') " +
                "exited \(status) and \(binary.path) does not exist.\n" +
                "  Fix the build errors above, or check that the product name is spelled exactly as in Package.swift."
            )
        }
        return binary
    }

    // MARK: - info

    private func info(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        try rejectLeftovers(extractor)
        let artifact = try FrameworkArtifact.find(in: context.package)
        let info = (try? Plist.read(artifact.framework.appendingPathComponent("Resources/Info.plist"))) ?? [:]
        print("CefSwift — CEF framework")
        if let directory = HelperBuilder.cefSwiftPackageDirectory(in: context.package),
           let data = try? Data(contentsOf: directory.appendingPathComponent("CEF_VERSION.json")),
           let pin = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("  CEF version:      \(pin["cef"] as? String ?? "?")")
            print("  Chromium version: \(pin["chromium"] as? String ?? "?")")
        }
        print("  Framework:        \(info["CFBundleShortVersionString"]?.stringValue ?? "?") (CFBundleShortVersionString)")
        print("  From:             \(artifact.origin)")
        print("  XCFramework:      \(artifact.xcframework.path)")
        print("  Architectures:    \(FrameworkArtifact.architectures(of: artifact.binary).sorted().joined(separator: ", "))")
    }

    // MARK: - shared

    private func rejectLeftovers(_ extractor: ArgumentExtractor) throws {
        guard extractor.remainingArguments.isEmpty else {
            throw CefPluginError(
                "Unrecognized arguments: \(extractor.remainingArguments.joined(separator: " ")).\n\(Self.usage)"
            )
        }
    }
}
