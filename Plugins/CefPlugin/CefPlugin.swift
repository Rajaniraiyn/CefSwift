import Foundation
import PackagePlugin

#if arch(arm64)
private let hostCefPlatform = "macosarm64"
#else
private let hostCefPlatform = "macosx64"
#endif

/// `swift package cef <download|bundle|info|clean>`.
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
        default:
            print(Self.usage)
            throw CefPluginError(
                "Unknown subcommand '\(subcommand)'. Expected one of: download, bundle, info, clean."
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
             [--name <DisplayName>] [--manifest <path>] [--sign <identity|->]
             [--version <1.2.3>] [--build <42>]
          Build <Name>, compile the helper, then assemble a runnable <Name>.app
          (framework + five helper apps + Info.plists + codesign).
          --version / --build: CFBundleShortVersionString / CFBundleVersion.
          Precedence: option > cefapp.json "version"/"build" > 1.0 / 1.
          LSMinimumSystemVersion: cefapp.json "minimumSystemVersion", else the
          deployment target the product was built for (the package's
          platforms), else 14.0.
          --sign: codesign identity; '-' forces ad-hoc. Default: auto-detect
          (first "Apple Development", else "Developer ID Application", else
          ad-hoc). Precedence: --sign > cefapp.json "signingIdentity" > auto.
          Default output: <packageDir>/dist/<Name>.app.
          Optional per-product overrides: cefapp.json next to the target sources.

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
        let signOption = extractor.extractOption(named: "sign").last
        let versionOption = extractor.extractOption(named: "version").last
        let buildOption = extractor.extractOption(named: "build").last
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

        // 1. The CEF distribution, downloaded on first use.
        let manifest = try CefManifest.resolve(context: context, explicitPath: manifestPath)
        let downloader = Downloader(cacheRoot: cacheRoot(context: context))
        let dist = try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor)
        let framework = downloader.frameworkURL(in: dist)

        // 2. Build the product, linked to the framework (see
        // frameworkLinkerFlags).
        let mainExecutable: URL
        if let testExe {
            mainExecutable = URL(fileURLWithPath: testExe)
            print("[cef] Bundling prebuilt \(mainExecutable.path)")
        } else {
            mainExecutable = try buildProduct(
                named: productName, configuration: configuration, context: context,
                manifest: manifest, linkerFlags: Self.frameworkLinkerFlags(framework),
                forceCLIBuild: forceCLIBuild
            )
        }

        // 3. Per-product overrides from cefapp.json beside the target's
        // sources. (`directoryURL` needs tools version 6.1.)
        let targetDirectory = context.package.targets
            .first { $0 is SourceModuleTarget && $0.name == productName }
            .map { URL(fileURLWithPath: $0.directory.string) }
        let appConfig = CefAppConfig.load(near: targetDirectory)
        let minimumSystemVersion = appConfig?.minimumSystemVersion
            ?? MachOVersion.minimumSystemVersion(of: mainExecutable) ?? "14.0"

        // 4. Compile the helper against the framework.
        let helper: HelperBuilder.Products
        if let testHelperExe {
            helper = .init(
                executable: URL(fileURLWithPath: testHelperExe),
                startupLibrary: URL(fileURLWithPath: testHelperExe).deletingLastPathComponent()
                    .appendingPathComponent(HelperBuilder.startupLibraryName))
        } else {
            guard let packageDirectory = HelperBuilder.cefSwiftPackageDirectory(in: context.package) else {
                throw CefPluginError(
                    "Could not find the CefSwift package among \(context.package.displayName)'s dependencies. " +
                    "Add CefSwift as a dependency of the package you bundle from.")
            }
            helper = try HelperBuilder(
                packageDirectory: packageDirectory,
                framework: framework,
                platform: platform,
                minimumSystemVersion: minimumSystemVersion,
                workDirectory: context.pluginWorkDirectoryURL.appendingPathComponent("helper")
            ).build()
        }

        let appName = nameOption ?? productName
        let displayName = nameOption ?? appConfig?.displayName ?? productName
        let bundleID = bundleIDOption
            ?? appConfig?.bundleIdentifier
            ?? "com.cefswift.\(productName.lowercased())"
        let outputDirectory = outputPath
            .map { URL(fileURLWithPath: $0, relativeTo: context.package.directoryURL).absoluteURL }
            ?? context.package.directoryURL.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 5. Assemble and sign.
        let signingIdentity = resolveSigningIdentity(
            flag: signOption, configValue: appConfig?.signingIdentity
        )
        let bundler = AppBundler(
            appName: appName,
            displayName: displayName,
            bundleIdentifier: bundleID,
            minimumSystemVersion: minimumSystemVersion,
            version: versionOption ?? appConfig?.version ?? "1.0",
            build: buildOption ?? appConfig?.build ?? "1",
            mainExecutable: mainExecutable,
            helperExecutable: helper.executable,
            helperStartupLibrary: helper.startupLibrary,
            frameworkSource: framework,
            outputDirectory: outputDirectory,
            signingIdentity: signingIdentity
        )
        let app = try bundler.assemble()

        print("")
        print("[cef] Created \(app.path)")
        print("[cef] Run it with: open \"\(app.path)\"")
    }

    /// Resolves the codesigning identity for `cef bundle`.
    /// Precedence: `--sign <identity|->` > cefapp.json `signingIdentity` >
    /// auto-detect via `security find-identity -v -p codesigning` (first
    /// "Apple Development", else first "Developer ID Application", else
    /// ad-hoc "-").
    private func resolveSigningIdentity(flag: String?, configValue: String?) -> String {
        if let flag {
            print(flag == "-"
                ? "[cef] Signing: ad-hoc (--sign -)"
                : "[cef] Signing with identity from --sign: \(flag)")
            return flag
        }
        if let configValue {
            print(configValue == "-"
                ? "[cef] Signing: ad-hoc (cefapp.json signingIdentity)"
                : "[cef] Signing with identity from cefapp.json: \(configValue)")
            return configValue
        }

        // If `security` fails or lists nothing, sign ad hoc. Its lines look
        // like:  1) <SHA-1> "Apple Development: Jane Doe (TEAMID)"
        var identities: [String] = []
        if let result = try? Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]),
           result.exitCode == 0 {
            identities = result.stdout
                .split(separator: "\n")
                .compactMap { line in
                    guard let start = line.firstIndex(of: "\""),
                          let end = line.lastIndex(of: "\""), start < end
                    else { return nil }
                    return String(line[line.index(after: start)..<end])
                }
        }

        let chosen = identities.first { $0.hasPrefix("Apple Development") }
            ?? identities.first { $0.hasPrefix("Developer ID Application") }
        if let chosen {
            print("[cef] Signing with auto-detected identity: \(chosen)")
            return chosen
        }
        print("[cef] Signing: ad-hoc (no codesigning identity found)")
        print("[cef] note: an ad-hoc signed app loses its keychain \"Always Allow\" grant on every " +
              "rebuild — see CefSafeStoragePolicy.")
        return "-"
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

    /// Builds a product through SwiftPM. A product SwiftPM cannot build that
    /// way, such as one from a dependency, falls back to `swift build` in
    /// the package holding the manifest.
    private func buildProduct(
        named productName: String,
        configuration: PackageManager.BuildConfiguration,
        context: PluginContext,
        manifest: CefManifest,
        linkerFlags: [String],
        forceCLIBuild: Bool
    ) throws -> URL {
        print("[cef] Building product '\(productName)' (\(configuration))…")

        let proxyFailure: String
        if forceCLIBuild {
            proxyFailure = "skipped (--_force-cli-build)"
        } else {
            do {
                var parameters = PackageManager.BuildParameters(
                    configuration: configuration, logging: .concise, echoLogs: true)
                parameters.otherLinkerFlags = linkerFlags
                let result = try packageManager.build(.product(productName), parameters: parameters)
                let executables = result.builtArtifacts.filter { $0.kind == .executable }
                if result.succeeded,
                   let artifact = executables.first(where: { $0.url.lastPathComponent == productName })
                       ?? executables.first {
                    return artifact.url
                }
                proxyFailure = result.succeeded ? "the build produced no executable" : result.logText
            } catch {
                proxyFailure = "\(error)"
            }
        }

        // The running `swift package` holds the lock on the invoking package's
        // .build directory, so the fallback builds into its own scratch path.
        let providerRoot = manifest.sourceURL.deletingLastPathComponent()
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
            .appendingPathComponent(productName)
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
