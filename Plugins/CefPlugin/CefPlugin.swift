import Foundation
import PackagePlugin

/// `swift package cef <download|bundle|doctor|package|notarize|info|clean>`.
///
/// The SwiftPM front end of the `cefswift` tool, which does the work: this
/// plugin finds the product and CEF_VERSION.json in the package graph and
/// builds with SwiftPM; the tool decides and assembles the bundle, the same
/// way it does for the Xcode build phase (docs/bundling.md).
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
                throw PluginError("Missing subcommand. See usage above.")
            }
            return
        }
        let tool = try Tool(context: context)
        var extractor = ArgumentExtractor(Array(arguments.dropFirst()))

        switch subcommand {
        case "download":
            let manifest = try manifestPath(context: context, explicit: extractor.extractOption(named: "manifest").last)
            try tool.run(["download", "--cache", cacheRoot(context).path, "--manifest", manifest.path]
                         + extractor.remainingArguments)
        case "bundle":
            try bundle(context: context, tool: tool, extractor: &extractor)
        case "info":
            let manifest = try manifestPath(context: context, explicit: extractor.extractOption(named: "manifest").last)
            try rejectLeftovers(extractor)
            try tool.run(["info", "--cache", cacheRoot(context).path, "--manifest", manifest.path])
            print("")
            print("  Download with: swift package --allow-writing-to-package-directory " +
                  "--allow-network-connections all cef download")
        case "clean":
            try rejectLeftovers(extractor)
            try tool.run(["clean", "--cache", cacheRoot(context).path])
        case "doctor", "package", "notarize":
            try tool.run([subcommand] + appArguments(context: context, extractor: &extractor, command: subcommand))
        default:
            print(Self.usage)
            throw PluginError(
                "Unknown subcommand '\(subcommand)'. Expected one of: download, bundle, doctor, package, " +
                "notarize, info, clean.")
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
          --capability adds to cefapp.json "capabilities" (see docs/bundling.md#features).
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

    An Xcode app target runs the same tool from a build phase instead:
    see docs/bundling.md#xcode.
    """

    // MARK: - bundle

    private func bundle(context: PluginContext, tool: Tool, extractor: inout ArgumentExtractor) throws {
        let manifestOption = extractor.extractOption(named: "manifest").last
        let productName = extractor.extractOption(named: "product").last
        let configurationName = extractor.extractOption(named: "configuration").last ?? "release"
        let platform = extractor.extractOption(named: "platform").last ?? Self.hostPlatform
        let flavor = extractor.extractOption(named: "flavor").last ?? "minimal"
        let outputPath = extractor.extractOption(named: "output").last
        // The rest are the tool's: settings, signing, packaging.
        let settingsArguments = extractor.remainingArguments

        guard let productName else {
            throw PluginError(
                "Missing --product. Example: swift package --allow-writing-to-package-directory " +
                "--allow-network-connections all cef bundle --product Browser")
        }
        let configuration: PackageManager.BuildConfiguration
        switch configurationName {
        case "debug": configuration = .debug
        case "release": configuration = .release
        default:
            throw PluginError("Invalid --configuration '\(configurationName)'. Use 'debug' or 'release'.")
        }
        // SwiftPM builds for the architecture it runs on; the CEF
        // distribution must match it.
        guard platform == Self.hostPlatform else {
            throw PluginError(
                "--platform \(platform) does not match this build's architecture: SwiftPM builds " +
                "\(productName) for \(Self.hostPlatform == "macosarm64" ? "arm64" : "x86_64") here, and a bundle " +
                "cannot mix architectures. To bundle for Intel on Apple silicon, run the command under Rosetta: " +
                "arch -x86_64 swift package … cef bundle.")
        }

        // 1. Settings, checked before anything slow runs. cefapp.json sits
        // beside the sources of the product's executable target.
        let located = try LocatedProduct.locate(productName, in: context.package)
        let outputDirectory = outputPath.map { packageRelative($0, context: context) }
            ?? context.package.directoryURL.appendingPathComponent("dist")
        var bundleArguments = [
            "bundle", "--product-name", productName,
            "--package-directory", context.package.directoryURL.path,
            "--work-directory", context.pluginWorkDirectoryURL.path,
            "--output", outputDirectory.path,
        ]
        if let source = located.sourceDirectory { bundleArguments += ["--source-directory", source.path] }
        bundleArguments += settingsArguments
        try tool.run(bundleArguments + ["--check"])

        // 2. The CEF distribution, downloaded on first use.
        let manifest = try manifestPath(context: context, explicit: manifestOption)
        let framework = URL(fileURLWithPath: try tool.output([
            "download", "--cache", cacheRoot(context).path, "--manifest", manifest.path,
            "--platform", platform, "--flavor", flavor, "--print-framework-path",
        ]))
        let flags = try tool.buildFlags(framework: framework, startup: nil)

        // 3. The product, linked to the framework; then the helper and its
        // startup library, against it.
        let executable = try buildProduct(named: productName, kind: .executable, configuration: configuration,
                                          context: context, linkerFlags: flags["app"] ?? [])
        let startup = try buildProduct(named: "cefswift_helper_startup", kind: .dynamicLibrary,
                                       configuration: configuration, context: context,
                                       linkerFlags: flags["startup"] ?? [])
        let helper = try buildProduct(named: "cefswift-helper", kind: .executable, configuration: configuration,
                                      context: context,
                                      linkerFlags: try tool.buildFlags(framework: framework, startup: startup)["helper"] ?? [])

        // 4. Assemble and sign.
        try tool.run(bundleArguments + [
            "--executable", executable.path, "--helper", helper.path, "--helper-startup", startup.path,
            "--framework", framework.path,
        ] + located.resourceBundleNames.flatMap { ["--resource-bundle", $0] })
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
        linkerFlags: [String]
    ) throws -> URL {
        print("[cef] Building product '\(productName)' (\(configuration))…")
        let fileName = kind == .dynamicLibrary ? "lib\(productName).dylib" : productName

        let proxyFailure: String
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
        let status = try Tool.runStreaming("/usr/bin/swift", [
            "build",
            // The plugin sandbox already confines the build, and a nested
            // sandbox cannot be applied inside it.
            "--disable-sandbox",
            "--package-path", providerRoot.path,
            "--scratch-path", scratch.path,
            "--configuration", configName,
            "--product", productName,
        ] + linkerFlags.flatMap { ["-Xlinker", $0] })
        let binary = scratch.appendingPathComponent(configName).appendingPathComponent(fileName)
        guard status == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw PluginError(
                "Could not build product '\(productName)'.\n" +
                "  SwiftPM build: \(proxyFailure)\n" +
                "  CLI fallback ('swift build --package-path \(providerRoot.path) --product \(productName)') " +
                "exited \(status) and \(binary.path) does not exist.\n" +
                "  Fix the build errors above, or check that the product name is spelled exactly as in Package.swift.")
        }
        return binary
    }

    // MARK: - Shared

    #if arch(arm64)
    static let hostPlatform = "macosarm64"
    #else
    static let hostPlatform = "macosx64"
    #endif

    /// `.cef/` in the invoking package, the one directory the plugin may
    /// write to.
    private func cacheRoot(_ context: PluginContext) -> URL {
        context.package.directoryURL.appendingPathComponent(".cef")
    }

    private func packageRelative(_ path: String, context: PluginContext) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: context.package.directoryURL)
            .standardizedFileURL
    }

    /// The app a subcommand works on, a path or `--product` in `dist/`,
    /// followed by the subcommand's other options.
    private func appArguments(context: PluginContext, extractor: inout ArgumentExtractor, command: String) throws -> [String] {
        let product = extractor.extractOption(named: "product").last
        let output = extractor.extractOption(named: "output").last
        var rest = extractor.remainingArguments
        let app: URL
        if let index = rest.firstIndex(where: { !$0.hasPrefix("--") && !isOptionValue(at: $0, in: rest) }) {
            app = packageRelative(rest.remove(at: index), context: context)
        } else if let product {
            app = context.package.directoryURL.appendingPathComponent("dist/\(product).app")
        } else {
            throw PluginError("Missing the app: swift package cef \(command) <App.app> (or --product <Name>).")
        }
        if let output { rest += ["--output", packageRelative(output, context: context).path] }
        return [app.path] + rest
    }

    /// Whether `argument` is the value of the option before it.
    private func isOptionValue(at argument: String, in arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: argument), index > 0 else { return false }
        return ["--format", "--sign", "--keychain", "--keychain-profile"].contains(arguments[index - 1])
    }

    /// CEF_VERSION.json: `--manifest`, else the invoking package's, else the
    /// first of its dependencies' (breadth first), which covers an app that
    /// depends on CefSwift.
    private func manifestPath(context: PluginContext, explicit: String?) throws -> URL {
        if let explicit { return packageRelative(explicit, context: context) }
        for package in LocatedProduct.allPackages(from: context.package) {
            let url = package.directoryURL.appendingPathComponent("CEF_VERSION.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw PluginError(
            "Could not find CEF_VERSION.json in \(context.package.directoryURL.path) " +
            "or in any package dependency. Pass --manifest <path> explicitly.")
    }

    private func rejectLeftovers(_ extractor: ArgumentExtractor) throws {
        guard extractor.remainingArguments.isEmpty else {
            throw PluginError("Unrecognized arguments: \(extractor.remainingArguments.joined(separator: " ")).\n\(Self.usage)")
        }
    }
}

/// The `cefswift` tool, built by SwiftPM for this plugin.
struct Tool {
    let url: URL

    init(context: PluginContext) throws {
        url = try context.tool(named: "cefswift").url
    }

    /// Runs the tool with its output going to the terminal.
    func run(_ arguments: [String]) throws {
        let status = try Self.runStreaming(url.path, arguments)
        // The tool has printed what went wrong.
        guard status == 0 else { throw PluginError("cefswift \(arguments.first ?? "") failed.") }
    }

    /// Runs the tool and returns its standard output, trimmed; its standard
    /// error goes to the terminal.
    func output(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PluginError("cefswift \(arguments.first ?? "") failed.") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildFlags(framework: URL, startup: URL?) throws -> [String: [String]] {
        var arguments = ["build-flags", "--framework", framework.path]
        if let startup { arguments += ["--startup", startup.path] }
        let json = try output(arguments)
        guard let flags = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String]] else {
            throw PluginError("cefswift build-flags printed no linker flags.")
        }
        return flags
    }

    static func runStreaming(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw PluginError("Could not run \(tool): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// An error whose message says what went wrong and how to fix it.
struct PluginError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}
