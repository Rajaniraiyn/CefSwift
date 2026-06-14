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

      bundle --product <Name> [--configuration debug|release] [--flavor minimal|standard]
             [--platform macosarm64|macosx64] [--output <dir>] [--bundle-id <id>]
             [--name <DisplayName>] [--manifest <path>] [--sign <identity|->]
          Build <Name> and cef-helper, then assemble a runnable <Name>.app
          (framework + five helper apps + Info.plists + codesign).
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
        if let cefVersionOverride, cefVersionOverride != manifest.cef {
            // The manifest only carries artifacts for its own pin; an arbitrary
            // version has no sha1 to verify against, so be explicit about it.
            throw CefPluginError(
                "--cef-version \(cefVersionOverride) does not match the pinned manifest version \(manifest.cef). " +
                "Update CEF_VERSION.json (Scripts/cef-update.sh) instead of overriding ad hoc, " +
                "or pass --manifest pointing at a manifest pinned to that version."
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
        // Hidden flags for testing the assembler without buildable products,
        // and for forcing the CLI build fallback.
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

        // 1. CEF distribution (downloads on first use).
        let manifest = try CefManifest.resolve(context: context, explicitPath: manifestPath)
        let downloader = Downloader(cacheRoot: cacheRoot(context: context))
        let dist = try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor)
        let framework = downloader.frameworkURL(in: dist)

        // 2. Build the product and the cef-helper.
        let mainExecutable: URL
        let helperExecutable: URL
        if let testExe {
            // Internal dry-run path: bundle a caller-supplied executable.
            mainExecutable = URL(fileURLWithPath: testExe)
            helperExecutable = URL(fileURLWithPath: testHelperExe ?? testExe)
            print("[cef] (test mode) bundling \(mainExecutable.path)")
        } else {
            mainExecutable = try buildProduct(
                named: productName, configuration: configuration, context: context,
                manifest: manifest, forceCLIBuild: forceCLIBuild
            )
            helperExecutable = try buildProduct(
                named: "cef-helper", configuration: configuration, context: context,
                manifest: manifest, forceCLIBuild: forceCLIBuild
            )
        }

        // 3. Per-product overrides (cefapp.json next to the target sources).
        // Target.directory (Path) instead of .directoryURL: the latter requires
        // PackageDescription 6.1 and this package pins tools-version 6.0.
        let targetDirectory = context.package.targets
            .first { $0 is SourceModuleTarget && $0.name == productName }
            .map { URL(fileURLWithPath: $0.directory.string) }
        let appConfig = CefAppConfig.load(near: targetDirectory)

        let appName = nameOption ?? productName
        let displayName = nameOption ?? appConfig?.displayName ?? productName
        let bundleID = bundleIDOption
            ?? appConfig?.bundleIdentifier
            ?? "com.cefswift.\(productName.lowercased())"
        let outputDirectory = outputPath
            .map { URL(fileURLWithPath: $0, relativeTo: context.package.directoryURL).absoluteURL }
            ?? context.package.directoryURL.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 4. Resolve the codesigning identity:
        //    --sign flag > cefapp.json "signingIdentity" > auto-detect.
        let signingIdentity = resolveSigningIdentity(
            flag: signOption, configValue: appConfig?.signingIdentity
        )

        // 5. Assemble + codesign.
        let bundler = AppBundler(
            appName: appName,
            displayName: displayName,
            bundleIdentifier: bundleID,
            minimumSystemVersion: appConfig?.minimumSystemVersion ?? "14.0",
            mainExecutable: mainExecutable,
            helperExecutable: helperExecutable,
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

        // Auto-detect. `security` may be unavailable inside the plugin
        // sandbox or list no identities — both fall back to ad-hoc.
        let identities: [String]
        if let result = try? Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]),
           result.exitCode == 0 {
            // Lines look like:  1) <SHA1-hash> "Apple Development: Jane Doe (TEAMID)"
            identities = result.stdout
                .split(separator: "\n")
                .compactMap { line in
                    guard let start = line.firstIndex(of: "\""),
                          let end = line.lastIndex(of: "\""), start < end
                    else { return nil }
                    return String(line[line.index(after: start)..<end])
                }
        } else {
            identities = []
        }

        let chosen = identities.first { $0.hasPrefix("Apple Development") }
            ?? identities.first { $0.hasPrefix("Developer ID Application") }
        if let chosen {
            print("[cef] Signing with auto-detected identity: \(chosen)")
            return chosen
        }
        print("[cef] Signing: ad-hoc (no codesigning identity found)")
        print("[cef] note: with ad-hoc signing, the keychain \"Always Allow\" grant won't persist " +
              "across rebuilds — see docs/configuration.md (safe storage).")
        return "-"
    }

    /// Builds a product via the PackageManager proxy; when the product belongs
    /// to a dependency package (e.g. building `cef-helper` from Examples/) and
    /// the proxy refuses, falls back to `swift build --package-path <provider>`.
    private func buildProduct(
        named productName: String,
        configuration: PackageManager.BuildConfiguration,
        context: PluginContext,
        manifest: CefManifest,
        forceCLIBuild: Bool = false
    ) throws -> URL {
        print("[cef] Building product '\(productName)' (\(configuration))…")

        var proxyFailure: String? = nil
        if forceCLIBuild {
            proxyFailure = "skipped (--_force-cli-build)"
        } else {
            do {
                let result = try packageManager.build(
                    .product(productName),
                    parameters: .init(configuration: configuration, logging: .concise, echoLogs: true)
                )
                if result.succeeded {
                    if let artifact = result.builtArtifacts.first(where: {
                        $0.kind == .executable && $0.url.lastPathComponent == productName
                    }) ?? result.builtArtifacts.first(where: { $0.kind == .executable }) {
                        return artifact.url
                    }
                    proxyFailure = "build succeeded but produced no executable artifact"
                } else {
                    proxyFailure = result.logText
                }
            } catch {
                proxyFailure = "\(error)"
            }
        }

        // Fallback: build inside the package that provides the plugin/manifest
        // (the CefSwift root) via the swift CLI. Uses a private --scratch-path
        // under the plugin work directory: the parent `swift package` process
        // holds the invoking package's .build lock for the whole plugin run,
        // so reusing the default scratch path would deadlock when the provider
        // package is the invoking package.
        let providerRoot = manifest.sourceURL.deletingLastPathComponent()
        let configName = configuration == .release ? "release" : "debug"
        let scratch = context.pluginWorkDirectoryURL.appendingPathComponent("fallback-build")
        print("[cef] PackageManager build of '\(productName)' did not yield a binary; " +
              "falling back to 'swift build --package-path \(providerRoot.path)'…")
        let status = try Shell.runStreaming("/usr/bin/swift", [
            "build",
            // We are already inside SwiftPM's plugin sandbox; a nested
            // sandbox-exec is not permitted (manifest compilation would fail
            // with "sandbox_apply: Operation not permitted"). The outer plugin
            // sandbox still confines all writes.
            "--disable-sandbox",
            "--package-path", providerRoot.path,
            "--scratch-path", scratch.path,
            "--configuration", configName,
            "--product", productName,
        ])
        let binary = scratch
            .appendingPathComponent(configName)
            .appendingPathComponent(productName)
        guard status == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw CefPluginError(
                "Could not build product '\(productName)'.\n" +
                "  PackageManager proxy: \(proxyFailure ?? "unknown failure")\n" +
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
        for platform in manifest.platforms.keys.sorted() {
            for flavor in (manifest.platforms[platform] ?? [:]).keys.sorted() {
                let artifact = try manifest.artifact(platform: platform, flavor: flavor)
                let dist = downloader.distURL(cefVersion: manifest.cef, platform: platform, flavor: flavor)
                let tarball = downloader.downloadsDirectory.appendingPathComponent(artifact.name)
                let state: String
                if downloader.isPrepared(dist: dist) {
                    state = "prepared"
                } else if fm.fileExists(atPath: dist.path) {
                    state = "extracting (incomplete — re-run download)"
                } else if fm.fileExists(atPath: tarball.path) {
                    state = "downloaded (not extracted)"
                } else {
                    state = "not downloaded"
                }
                let sizeMB = artifact.size / 1_000_000
                print("    \(platform)/\(flavor)  (\(sizeMB) MB)  —  \(state)")
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

    /// `.cef/` lives at the root of the *invoking* package (the only directory
    /// the sandbox lets us write to with --allow-writing-to-package-directory).
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
