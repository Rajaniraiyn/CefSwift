import Foundation
import PackagePlugin

#if arch(arm64)
private let hostCefPlatform = "macosarm64"
#else
private let hostCefPlatform = "macosx64"
#endif

/// `swift package cef <download|bundle|doctor|package|notarize|info|clean>`.
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
        case "download":
            try download(context: context, extractor: &extractor)
        case "bundle":
            try await bundle(context: context, extractor: &extractor)
        case "info":
            try info(context: context, extractor: &extractor)
        case "clean":
            try clean(context: context)
        case "doctor":
            try doctor(context: context, extractor: &extractor)
        case "package":
            try package(context: context, extractor: &extractor)
        case "notarize":
            try notarize(context: context, extractor: &extractor)
        default:
            print(Self.usage)
            throw CefPluginError(
                "Unknown subcommand '\(subcommand)'. Expected one of: download, bundle, doctor, package, " +
                "notarize, info, clean."
            )
        }
    }

    static let usage = """
    USAGE: swift package [--allow-writing-to-package-directory --allow-network-connections all] cef <subcommand>

    SUBCOMMANDS:
      download [--platform macosarm64|macosx64] [--flavor minimal|standard]
               [--cef-version <V>] [--manifest <path>]
          Download the pinned CEF distribution into .cef/, verify, extract, and
          convert the framework to the versioned bundle layout. Idempotent.
          --cef-version must match the manifest; to use another version, pass
          --manifest with a manifest pinned to it.

      bundle --product <Name> [--configuration debug|release] [--flavor minimal|standard]
             [--platform macosarm64|macosx64] [--output <dir>] [--bundle-id <id>]
             [--name <DisplayName>] [--manifest <path>] [--version <1.2.3>] [--build <42>]
             [--config <cefapp.json>] [--sign <identity|->] [--team-id <ID>] [--keychain <file>]
             [--capability <name>]... [--info-plist <file>]... [--entitlements <file>]
             [--provisioning-profile <file>] [--[no-]hardened-runtime] [--[no-]timestamp]
             [--package zip|dmg] [--notarize --keychain-profile <name>]
             [--localizations application|all|<list>] [--software-gpu-fallback include|exclude]
          Build <Name>, compile the helper, then assemble and sign <Name>.app
          (framework + five helper apps + Info.plists + entitlements).
          --localizations chooses Chromium's locale packs: those of the app's
          localizations (CFBundleLocalizations), its development language and
          English (application, the default), all of them, or those of a
          list such as en,fr. --software-gpu-fallback exclude leaves out
          SwiftShader (about 16 MiB). cefapp.json "cef": {"localizations",
          "softwareGPUFallback"} sets defaults.
          Settings come from cefapp.json next to the target's sources (or
          --config); options override it. --sign '-' signs ad hoc; without it,
          the first "Apple Development", else "Developer ID Application"
          identity, else ad hoc. The hardened runtime defaults to on for Apple
          team identities, the secure timestamp to on for Developer ID.
          --capability adds to cefapp.json "capabilities": \(Capability.all.map(\.name).joined(separator: ", ")).
          --package and --notarize run the commands below on the result.
          Default output: <packageDir>/dist/<Name>.app.

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
          Print the pinned CEF version and the state of the .cef/ cache.

      clean
          Remove the .cef/ cache directory.
    """

    // MARK: - download

    private func download(context: PluginContext, extractor: inout ArgumentExtractor) throws {
        let manifestPath = extractor.extractOption(named: "manifest").last
        let platform = extractor.extractOption(named: "platform").last ?? hostCefPlatform
        let flavor = extractor.extractOption(named: "flavor").last ?? "minimal"
        let cefVersionOverride = extractor.extractOption(named: "cef-version").last
        try rejectLeftovers(extractor)

        let manifest = try CefManifest.resolve(context: context, explicitPath: manifestPath)
        // A manifest only has checksums for the version it pins.
        if let cefVersionOverride, cefVersionOverride != manifest.cef {
            throw CefPluginError(
                "--cef-version \(cefVersionOverride) does not match the version \(manifest.cef) pinned by " +
                "\(manifest.sourceURL.path). Pass --manifest with a manifest pinned to \(cefVersionOverride), " +
                "or update CEF_VERSION.json with Scripts/update-cef.py."
            )
        }

        let downloader = Downloader(cacheRoot: cacheRoot(context: context))
        let dist = try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor)
        print("[cef] Framework: \(downloader.frameworkURL(in: dist).path)")
    }

    // MARK: - bundle

    private func bundle(context: PluginContext, extractor: inout ArgumentExtractor) async throws {
        let manifestPath = extractor.extractOption(named: "manifest").last
        let productName = extractor.extractOption(named: "product").last
        let configurationName = extractor.extractOption(named: "configuration").last ?? "release"
        let platform = extractor.extractOption(named: "platform").last ?? hostCefPlatform
        let flavor = extractor.extractOption(named: "flavor").last ?? "minimal"
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
        let localizationsOption = extractor.extractOption(named: "localizations").last
        let softwareGPUOption = extractor.extractOption(named: "software-gpu-fallback").last
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
        let configuration: PackageManager.BuildConfiguration
        switch configurationName {
        case "debug": configuration = .debug
        case "release": configuration = .release
        default:
            throw CefPluginError("Invalid --configuration '\(configurationName)'. Use 'debug' or 'release'.")
        }

        // SwiftPM builds for the architecture it runs on; the CEF
        // distribution must match it.
        guard platform == hostCefPlatform else {
            throw CefPluginError(
                "--platform \(platform) does not match this build's architecture: SwiftPM builds " +
                "\(productName) for \(hostCefPlatform == "macosarm64" ? "arm64" : "x86_64") here, and a bundle " +
                "cannot mix architectures. To bundle for Intel on Apple silicon, run the command under Rosetta: " +
                "arch -x86_64 swift package … cef bundle.")
        }

        // 1. Settings, checked before anything slow runs. cefapp.json sits
        // beside the sources of the product's executable target.
        let located = try LocatedProduct.locate(productName, in: context.package)
        let appConfig = try CefAppConfig.load(
            near: located.sourceDirectory,
            explicit: configPath.map { packageRelative($0, context: context) })
        if let appConfig { print("[cef] Settings: \(appConfig.source.path)") }
        let appName = nameOption ?? productName
        let displayName = nameOption ?? appConfig?.displayName ?? productName
        let bundleID = bundleIDOption
            ?? appConfig?.bundleIdentifier
            ?? "com.cefswift.\(productName.lowercased())"
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
        let trim = try (appConfig ?? CefAppConfig()).trimPolicy(
            localizationsOption: localizationsOption, softwareGPUOption: softwareGPUOption)
        let notarization = try notarizationSettings(
            notarize: notarize, keychainProfile: keychainProfileOption, format: packageFormat,
            config: appConfig, identity: identity, plan: plan)

        // 2. The CEF distribution, downloaded on first use.
        let manifest = try CefManifest.resolve(context: context, explicitPath: manifestPath)
        let downloader = Downloader(cacheRoot: cacheRoot(context: context))
        let dist = try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor)
        let framework = downloader.frameworkURL(in: dist)

        // 3. Build the product, linked to the framework (see
        // frameworkLinkerFlags).
        let mainExecutable: URL
        if let testExe {
            mainExecutable = URL(fileURLWithPath: testExe)
            print("[cef] Bundling prebuilt \(mainExecutable.path)")
        } else {
            mainExecutable = try buildProduct(
                named: productName, kind: .executable, configuration: configuration, context: context,
                // Room for the run path AppBundler adds.
                linkerFlags: Self.frameworkLinkerFlags(framework) + ["-headerpad_max_install_names"],
                forceCLIBuild: forceCLIBuild
            )
        }
        let product = try BuiltProduct.collect(
            executable: mainExecutable, resourceBundleNames: located.resourceBundleNames)
        for item in product.resourceBundles + product.libraries {
            print("[cef] Includes \(item.lastPathComponent)")
        }
        let minimumSystemVersion = appConfig?.minimumSystemVersion ?? product.deploymentTarget ?? "14.0"

        // 4. Build the helper against the framework.
        let helper: HelperBuilder.Products
        if let testHelperExe {
            helper = .init(
                executable: URL(fileURLWithPath: testHelperExe),
                startupLibrary: URL(fileURLWithPath: testHelperExe).deletingLastPathComponent()
                    .appendingPathComponent(HelperBuilder.startupLibraryName))
        } else {
            helper = try HelperBuilder(
                framework: framework,
                workDirectory: context.pluginWorkDirectoryURL.appendingPathComponent("helper")
            ).build { product, kind, linkerFlags in
                try buildProduct(
                    named: product, kind: kind, configuration: configuration, context: context,
                    linkerFlags: linkerFlags, forceCLIBuild: forceCLIBuild)
            }
        }

        let outputDirectory = outputPath.map { packageRelative($0, context: context) }
            ?? context.package.directoryURL.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 5. Assemble and sign.
        print("[cef] Signing \(identity.kind.displayName)" +
              (identity.teamIdentifier.map { ", team \($0)" } ?? "") +
              (plan.hardenedRuntime ? ", hardened runtime" : "") +
              (plan.secureTimestamp ? ", secure timestamp" : "") +
              (distribution.profileURL != nil ? ", with \(distribution.profileURL!.lastPathComponent)" : ""))
        let bundler = AppBundler(
            appName: appName,
            displayName: displayName,
            bundleIdentifier: bundleID,
            minimumSystemVersion: minimumSystemVersion,
            version: versionOption ?? appConfig?.version ?? "1.0",
            build: buildOption ?? appConfig?.build ?? "1",
            product: product,
            helperExecutable: helper.executable,
            helperStartupLibrary: helper.startupLibrary,
            frameworkSource: framework,
            outputDirectory: outputDirectory,
            identity: identity,
            plan: plan,
            trim: trim,
            provisioningProfile: identity.kind.hasAppleTeam ? distribution.profileURL : nil,
            signingKeychain: keychain,
            workDirectory: workDirectory
        )
        let app = try bundler.assemble()

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

    /// Links the app to the framework, weakly, so that dyld loads it at
    /// launch. A library loaded at launch has its pointers fixed up by the
    /// kernel as pages are read in, which keeps about 12 MB of the
    /// framework's data clean, shared memory; one loaded later with
    /// `dlopen` holds it as private memory. CefKit's own `dlopen` of the
    /// framework then returns the library already loaded. The link is weak,
    /// so an executable run outside the bundle still starts and finds the
    /// framework the usual way.
    static func frameworkLinkerFlags(_ framework: URL) -> [String] {
        ["-F", framework.deletingLastPathComponent().path, "-weak_framework", "Chromium Embedded Framework"]
    }

    /// Builds a product through SwiftPM and returns the built file. A
    /// product SwiftPM cannot build that way, such as one from a
    /// dependency, falls back to `swift build` in the package that declares
    /// it.
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
        // A product builds in the package that declares it: the invoking
        // package for the app, CefSwift for the helper.
        let providerRoot = (try? LocatedProduct.locate(productName, in: context.package))?.package.directoryURL
            ?? context.package.directoryURL
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
        let manifestPath = extractor.extractOption(named: "manifest").last
        try rejectLeftovers(extractor)

        let manifest = try CefManifest.resolve(context: context, explicitPath: manifestPath)
        let downloader = Downloader(cacheRoot: cacheRoot(context: context))
        let fm = FileManager.default

        print("CefSwift — pinned CEF distribution")
        print("  CEF version:      \(manifest.cef)")
        print("  Chromium version: \(manifest.chromium)")
        print("  Channel:          \(manifest.channel)")
        print("  Manifest:         \(manifest.sourceURL.path)")
        print("  Cache root:       \(downloader.cacheRoot.path)")
        print("")
        print("  Platforms / flavors:")
        for (platform, flavors) in manifest.platforms.sorted(by: { $0.key < $1.key }) {
            for (flavor, artifact) in flavors.sorted(by: { $0.key < $1.key }) {
                let dist = downloader.distURL(cefVersion: manifest.cef, platform: platform, flavor: flavor)
                let tarball = downloader.downloadsDirectory.appendingPathComponent(artifact.name)
                let state: String
                if downloader.isPrepared(dist: dist) {
                    state = "prepared"
                } else if fm.fileExists(atPath: dist.path) {
                    state = "incomplete (run download again)"
                } else if fm.fileExists(atPath: tarball.path) {
                    state = "downloaded (not extracted)"
                } else {
                    state = "not downloaded"
                }
                print("    \(platform)/\(flavor)  (\(artifact.size / 1_000_000) MB)  —  \(state)")
            }
        }
        print("")
        print("  Download with: swift package --allow-writing-to-package-directory " +
              "--allow-network-connections all cef download")
    }

    // MARK: - clean

    private func clean(context: PluginContext) throws {
        let root = cacheRoot(context: context)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
            print("[cef] Removed \(root.path)")
        } else {
            print("[cef] Nothing to clean (\(root.path) does not exist).")
        }
    }

    // MARK: - shared

    /// `.cef/` in the invoking package, the one directory the plugin may
    /// write to.
    private func cacheRoot(context: PluginContext) -> URL {
        context.package.directoryURL.appendingPathComponent(".cef")
    }

    private func rejectLeftovers(_ extractor: ArgumentExtractor) throws {
        guard extractor.remainingArguments.isEmpty else {
            throw CefPluginError(
                "Unrecognized arguments: \(extractor.remainingArguments.joined(separator: " ")).\n\(Self.usage)"
            )
        }
    }
}
