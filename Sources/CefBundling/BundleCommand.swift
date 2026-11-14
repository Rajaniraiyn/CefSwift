import Foundation

/// `cefswift bundle`: the settings and assembly half of `swift package cef
/// bundle`. The command plugin locates and builds the product with SwiftPM
/// and passes what it built; everything about the bundle is decided here.
///
/// The plugin runs it twice: with `--check` before it builds, so that a
/// mistake in the settings stops the command before anything slow runs,
/// then with the built files.
struct BundleCommand {
    // Facts the plugin passes.
    var productName: String
    var packageDirectory: URL
    /// The product's executable target's sources, where cefapp.json sits.
    var sourceDirectory: URL?
    var workDirectory: URL
    var outputDirectory: URL
    // The build, absent with --check.
    var executable: URL?
    var resourceBundles: [String] = []
    var helper: URL?
    var helperStartup: URL?
    var framework: URL?
    var isCheckOnly = false

    // The user's options.
    var configPath: String?
    var bundleIDOption: String?
    var nameOption: String?
    var versionOption: String?
    var buildOption: String?
    var signOption: String?
    var teamOption: String?
    var keychainOption: String?
    var capabilityOptions: [String] = []
    var infoPlistOptions: [String] = []
    var entitlementsOption: String?
    var profileOption: String?
    var localizationsOption: String?
    var softwareGPUOption: String?
    var hardenedRuntime: Bool?
    var timestamp: Bool?
    var packageFormat: String?
    var notarize = false
    var keychainProfileOption: String?

    static let usage = """
    USAGE: cefswift bundle --product-name <Name> --package-directory <dir> --work-directory <dir>
                           --output <dir> [--source-directory <dir>] [--check]
                           [--executable <file> --resource-bundle <name>... --helper <file>
                            --helper-startup <file> --framework <dir>]
                           [the options of 'swift package cef bundle']
    Run by the cef command plugin; see 'swift package cef help'.
    """

    init(arguments: [String]) throws {
        var args = Arguments(arguments)
        guard let productName = args.option("product-name"),
              let packageDirectory = args.option("package-directory"),
              let workDirectory = args.option("work-directory"),
              let outputDirectory = args.option("output") else {
            throw BundlingError("Missing --product-name, --package-directory, --work-directory or --output.\n\(Self.usage)")
        }
        self.productName = productName
        self.packageDirectory = URL(fileURLWithPath: packageDirectory)
        self.workDirectory = URL(fileURLWithPath: workDirectory)
        self.outputDirectory = URL(fileURLWithPath: outputDirectory)
        sourceDirectory = args.option("source-directory").map { URL(fileURLWithPath: $0) }
        executable = args.option("executable").map { URL(fileURLWithPath: $0) }
        resourceBundles = args.options("resource-bundle")
        helper = args.option("helper").map { URL(fileURLWithPath: $0) }
        helperStartup = args.option("helper-startup").map { URL(fileURLWithPath: $0) }
        framework = args.option("framework").map { URL(fileURLWithPath: $0) }
        isCheckOnly = args.flag("check")

        configPath = args.option("config")
        bundleIDOption = args.option("bundle-id")
        nameOption = args.option("name")
        versionOption = args.option("version")
        buildOption = args.option("build")
        signOption = args.option("sign")
        teamOption = args.option("team-id")
        keychainOption = args.option("keychain")
        capabilityOptions = args.options("capability")
        infoPlistOptions = args.options("info-plist")
        entitlementsOption = args.option("entitlements")
        profileOption = args.option("provisioning-profile")
        localizationsOption = args.option("localizations")
        softwareGPUOption = args.option("software-gpu-fallback")
        hardenedRuntime = try args.toggle("hardened-runtime")
        timestamp = try args.toggle("timestamp")
        packageFormat = args.option("package")
        notarize = args.flag("notarize")
        keychainProfileOption = args.option("keychain-profile")
        try args.rejectLeftovers(usage: Self.usage)
    }

    private func packageRelative(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: packageDirectory).standardizedFileURL
    }

    func run() throws {
        // A second run resolves the same settings; say them once.
        Log.isQuiet = !isCheckOnly
        let settings = try resolveSettings()
        Log.isQuiet = false
        if isCheckOnly { return }
        guard let executable, let helper, let helperStartup, let framework else {
            throw BundlingError("Missing --executable, --helper, --helper-startup or --framework.\n\(Self.usage)")
        }

        let product = try BuiltProduct.collect(executable: executable, resourceBundleNames: resourceBundles)
        for item in product.resourceBundles + product.libraries {
            Log.info("Includes \(item.lastPathComponent)")
        }
        let helperProducts = try HelperLink.prepare(
            startup: helperStartup, helper: helper, framework: framework,
            in: workDirectory.appendingPathComponent("helper"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let identity = settings.identity
        let plan = settings.plan
        Log.info("Signing \(identity.kind.displayName)" +
                 (identity.teamIdentifier.map { ", team \($0)" } ?? "") +
                 (plan.hardenedRuntime ? ", hardened runtime" : "") +
                 (plan.secureTimestamp ? ", secure timestamp" : "") +
                 (settings.profileURL.map { ", with \($0.lastPathComponent)" } ?? ""))
        let bundler = AppBundler(
            appName: settings.appName,
            displayName: settings.displayName,
            bundleIdentifier: settings.bundleIdentifier,
            minimumSystemVersion: settings.config?.minimumSystemVersion ?? product.deploymentTarget ?? "14.0",
            version: versionOption ?? settings.config?.version ?? "1.0",
            build: buildOption ?? settings.config?.build ?? "1",
            product: product,
            helper: helperProducts,
            frameworkSource: framework,
            outputDirectory: outputDirectory,
            identity: identity,
            plan: plan,
            trim: settings.trim,
            provisioningProfile: identity.kind.hasAppleTeam ? settings.profileURL : nil,
            signingKeychain: settings.keychain,
            workDirectory: workDirectory.appendingPathComponent("signing"),
            extensions: settings.config.map { config in (config.extensions ?? []).map(config.resolve) } ?? [])
        let app = try bundler.assemble()

        print("")
        Log.info("Created \(app.path)")
        Log.info("Run it with: open \"\(app.path)\"")
        Log.info("Check it with: swift package --allow-writing-to-package-directory " +
                 "--allow-network-connections all cef doctor \"\(app.path)\"")

        if let notarization = settings.notarization {
            let archive = try Notarizer.package(app, format: notarization.format, output: nil,
                                                identity: identity.name, keychain: settings.keychain)
            if let keychainProfile = notarization.keychainProfile {
                try Notarizer.notarize(archive: archive, app: app, keychainProfile: keychainProfile)
            }
        }
    }

    struct Settings {
        var config: CefAppConfig?
        var appName: String
        var displayName: String
        var bundleIdentifier: String
        var keychain: String?
        var identity: SigningIdentity
        var plan: DistributionPlan
        var profileURL: URL?
        var trim: FrameworkTrimPolicy
        var notarization: NotarizationSettings?
    }

    /// cefapp.json beside the sources of the product's executable target,
    /// with the options over it, checked.
    func resolveSettings() throws -> Settings {
        let config = try CefAppConfig.load(near: sourceDirectory, explicit: configPath.map(packageRelative))
        if let config { Log.info("Settings: \(config.source.path)") }
        let appName = nameOption ?? productName
        let displayName = nameOption ?? config?.displayName ?? productName
        let bundleID = bundleIDOption ?? config?.bundleIdentifier ?? "com.cefswift.\(productName.lowercased())"
        let keychain = (keychainOption.map(packageRelative) ?? config?.signingKeychain.map { config!.resolve($0) })?.path
        let (identity, certificateSHA1) = try Signing.resolveIdentity(
            flag: signOption, configValue: config?.signingIdentity,
            teamIdentifier: teamOption ?? config?.teamIdentifier, keychain: keychain,
            workDirectory: workDirectory.appendingPathComponent("signing"))
        if identity.isAdHoc {
            Log.info("note: an ad-hoc signed app loses its keychain \"Always Allow\" grant on every " +
                     "rebuild — see CefRuntime.SafeStoragePolicy.")
        }

        var settings = DistributionSettings(bundleIdentifier: bundleID, identity: identity)
        settings.certificateSHA1 = certificateSHA1
        settings.capabilities = (config?.capabilities ?? []) + capabilityOptions
        settings.usageDescriptions = config?.usageDescriptions ?? [:]
        if let config, let infoPlist = config.infoPlist {
            settings.infoPlistOverlays.append(("\(config.source.lastPathComponent) infoPlist", infoPlist))
        }
        for path in infoPlistOptions {
            let url = packageRelative(path)
            settings.infoPlistOverlays.append((url.path, try Plist.read(url)))
        }
        if let url = entitlementsOption.map(packageRelative) ?? config?.entitlements.map({ config!.resolve($0) }) {
            settings.appEntitlementsFile = (url.lastPathComponent, try Plist.read(url))
        }
        if let config {
            for (name, path) in config.helperEntitlements ?? [:] {
                guard let helper = HelperKind(rawValue: name) else { continue }
                let url = config.resolve(path)
                settings.helperEntitlementFiles[helper] = (url.lastPathComponent, try Plist.read(url))
            }
        }
        let profileURL = profileOption.map(packageRelative) ?? config?.provisioningProfile.map { config!.resolve($0) }
        if let profileURL {
            settings.profile = try Signing.decodeProfile(at: profileURL)
        }
        settings.hardenedRuntime = hardenedRuntime ?? config?.hardenedRuntime
        settings.secureTimestamp = timestamp ?? config?.timestamp

        let plan = try settings.plan()
        for warning in plan.warnings { Log.warning(warning) }
        if let profile = settings.profile, identity.kind.hasAppleTeam {
            let problems = profile.problems(
                bundleIdentifier: bundleID, identity: identity, certificateSHA1: certificateSHA1,
                entitlements: plan.appEntitlements)
            for problem in problems where !problem.isError { Log.warning(problem.message) }
            let errors = problems.filter(\.isError).map(\.message)
            if !errors.isEmpty {
                throw BundlingError("The provisioning profile does not fit this bundle:\n  " +
                                    errors.joined(separator: "\n  "))
            }
        }
        let trim = try (config ?? CefAppConfig()).trimPolicy(
            localizationsOption: localizationsOption, softwareGPUOption: softwareGPUOption)
        let notarization = try notarizationSettings(config: config, identity: identity, plan: plan)
        return Settings(config: config, appName: appName, displayName: displayName, bundleIdentifier: bundleID,
                        keychain: keychain, identity: identity, plan: plan, profileURL: profileURL, trim: trim,
                        notarization: notarization)
    }

    struct NotarizationSettings {
        var format: Notarizer.Format
        var keychainProfile: String?
    }

    /// What `--package/--notarize` asks for, checked up front so a long
    /// build does not end in a configuration error.
    private func notarizationSettings(
        config: CefAppConfig?, identity: SigningIdentity, plan: DistributionPlan
    ) throws -> NotarizationSettings? {
        guard notarize || packageFormat != nil else { return nil }
        let formatName = packageFormat ?? config?.notarization?.format ?? "zip"
        guard let parsed = Notarizer.Format(rawValue: formatName) else {
            throw BundlingError("Invalid package format '\(formatName)'. Use 'zip' or 'dmg'.")
        }
        guard notarize else { return NotarizationSettings(format: parsed, keychainProfile: nil) }
        guard let profile = keychainProfileOption ?? config?.notarization?.keychainProfile else {
            throw BundlingError(
                "--notarize needs a notarytool keychain profile: pass --keychain-profile <name> or set " +
                "\"notarization\": {\"keychainProfile\": \"<name>\"} in cefapp.json. Create it once with " +
                "'xcrun notarytool store-credentials <name>'.")
        }
        guard identity.kind == .developerID, plan.hardenedRuntime, plan.secureTimestamp else {
            throw BundlingError(
                "Notarization needs a Developer ID Application signature with the hardened runtime and a " +
                "secure timestamp; this bundle is signed \(identity.kind.displayName)" +
                (plan.hardenedRuntime ? "" : ", without the hardened runtime") +
                (plan.secureTimestamp ? "" : ", without a secure timestamp") + ".")
        }
        return NotarizationSettings(format: parsed, keychainProfile: profile)
    }
}
