import Foundation

#if arch(arm64)
let hostCefPlatform = "macosarm64"
#else
let hostCefPlatform = "macosx64"
#endif

/// The `cefswift` tool: the one implementation behind `swift package cef`
/// (whose command plugin runs it) and the Xcode build phase
/// (Scripts/xcode-embed.sh runs `cefswift embed`).
public enum CefTool {
    public static let usage = """
    USAGE: cefswift <subcommand>

    SUBCOMMANDS:
      embed
          The Xcode build phase: adds Chromium's framework, the helpers' startup
          library and five helper apps to the app this build made, signed like
          it, then runs cef doctor's checks. Reads Xcode's build settings from
          its environment. Run it through Scripts/xcode-embed.sh.

      doctor <App.app> [--json]
      package <App.app> [--format zip|dmg] [--sign <identity>] [--keychain <file>] [--output <dir>]
      notarize <App.app> --keychain-profile <name> [--format zip|dmg] [--sign <identity>] [--keychain <file>]
          As 'swift package cef doctor|package|notarize', for an app built any way.

      download --cache <dir> --manifest <CEF_VERSION.json> [--platform <p>] [--flavor <f>]
               [--cef-version <V>] [--print-framework-path]
      info --cache <dir> --manifest <CEF_VERSION.json>
      clean --cache <dir>
      bundle …, build-flags …
          Run by the cef command plugin.

    See docs/bundling.md.
    """

    /// Runs one subcommand and returns the exit status.
    public static func main(arguments: [String], environment: [String: String]) -> Int32 {
        guard let subcommand = arguments.first, !["help", "--help", "-h"].contains(subcommand) else {
            print(usage)
            return arguments.isEmpty ? 1 : 0
        }
        if subcommand == "embed" { Log.style = .xcode }
        do {
            let rest = Array(arguments.dropFirst())
            switch subcommand {
            case "embed": try XcodeEmbed(environment: environment).run()
            case "bundle": try BundleCommand(arguments: rest).run()
            case "download": try download(rest)
            case "build-flags": try buildFlags(rest)
            case "doctor": return try doctor(rest)
            case "package": try package(rest)
            case "notarize": try notarize(rest)
            case "info": try info(rest)
            case "clean": try clean(rest)
            default:
                throw BundlingError("Unknown subcommand '\(subcommand)'.\n\(usage)")
            }
            return 0
        } catch {
            Log.error("\(error)")
            return 1
        }
    }

    // MARK: - Subcommands

    private static func cacheAndManifest(_ args: inout Arguments, command: String) throws -> (Downloader, CefManifest) {
        guard let cache = args.option("cache"), let manifest = args.option("manifest") else {
            throw BundlingError("Missing --cache or --manifest. USAGE: cefswift \(command) --cache <dir> --manifest <file>")
        }
        return (Downloader(cacheRoot: URL(fileURLWithPath: cache)),
                try CefManifest.load(from: URL(fileURLWithPath: manifest)))
    }

    private static func download(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        let (downloader, manifest) = try cacheAndManifest(&args, command: "download")
        let platform = args.option("platform") ?? hostCefPlatform
        let flavor = args.option("flavor") ?? "minimal"
        let cefVersion = args.option("cef-version")
        let printPath = args.flag("print-framework-path")
        try args.rejectLeftovers(usage: usage)
        // A manifest only has checksums for the version it pins.
        if let cefVersion, cefVersion != manifest.cef {
            throw BundlingError(
                "--cef-version \(cefVersion) does not match the version \(manifest.cef) pinned by " +
                "\(manifest.sourceURL.path). Pass --manifest with a manifest pinned to \(cefVersion), " +
                "or update CEF_VERSION.json with Scripts/update-cef.py.")
        }
        // With --print-framework-path, standard output holds the path alone;
        // progress goes to standard error.
        let framework: URL
        if printPath {
            let saved = dup(STDOUT_FILENO)
            dup2(STDERR_FILENO, STDOUT_FILENO)
            defer { fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved) }
            framework = downloader.frameworkURL(in: try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor))
        } else {
            framework = downloader.frameworkURL(in: try downloader.ensure(manifest: manifest, platform: platform, flavor: flavor))
            Log.info("Framework: \(framework.path)")
            return
        }
        print(framework.path)
    }

    /// The linker flags the plugin builds the app, the startup library and
    /// the helper with, as JSON: HelperLink is their one definition.
    private static func buildFlags(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        guard let framework = args.option("framework").map({ URL(fileURLWithPath: $0) }) else {
            throw BundlingError("Missing --framework.")
        }
        let startup = args.option("startup").map { URL(fileURLWithPath: $0) }
        try args.rejectLeftovers(usage: usage)
        var flags: [String: [String]] = [
            "app": HelperLink.appLinkerFlags(framework: framework),
            "startup": HelperLink.startupLinkerFlags,
        ]
        if let startup { flags["helper"] = HelperLink.helperLinkerFlags(startupLibrary: startup, framework: framework) }
        let data = try JSONSerialization.data(withJSONObject: flags, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func appArgument(_ args: inout Arguments, command: String) throws -> URL {
        guard let path = args.positional() else {
            throw BundlingError("Missing the app: cefswift \(command) <App.app>.")
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func doctor(_ arguments: [String]) throws -> Int32 {
        var args = Arguments(arguments)
        let json = args.flag("json")
        let app = try appArgument(&args, command: "doctor")
        try args.rejectLeftovers(usage: usage)
        let report = Doctor.evaluate(try DoctorInspector.inspect(app))
        print(json ? try report.json() : report.text())
        if report.errorCount > 0 {
            Log.error("cef doctor found \(report.errorCount) error(s) in \(app.lastPathComponent).")
            return 1
        }
        return 0
    }

    private static func package(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        let format = args.option("format") ?? "zip"
        let sign = args.option("sign")
        let keychain = args.option("keychain")
        let output = args.option("output")
        let app = try appArgument(&args, command: "package")
        try args.rejectLeftovers(usage: usage)
        guard let parsed = Notarizer.Format(rawValue: format) else {
            throw BundlingError("Invalid --format '\(format)'. Use 'zip' or 'dmg'.")
        }
        _ = try Notarizer.package(app, format: parsed, output: output.map { URL(fileURLWithPath: $0) },
                                  identity: sign, keychain: keychain)
    }

    private static func notarize(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        let profile = args.option("keychain-profile")
        let format = args.option("format") ?? "zip"
        let sign = args.option("sign")
        let keychain = args.option("keychain")
        let app = try appArgument(&args, command: "notarize")
        try args.rejectLeftovers(usage: usage)
        guard let profile else {
            throw BundlingError(
                "Missing --keychain-profile <name>. Create the profile once with " +
                "'xcrun notarytool store-credentials <name>' (an app-specific password or an App Store " +
                "Connect API key).")
        }
        guard let parsed = Notarizer.Format(rawValue: format) else {
            throw BundlingError("Invalid --format '\(format)'. Use 'zip' or 'dmg'.")
        }
        if parsed == .dmg, sign == nil {
            throw BundlingError("--format dmg needs --sign <Developer ID Application identity> to sign the disk image.")
        }
        let archive = try Notarizer.package(app, format: parsed, output: nil, identity: sign, keychain: keychain)
        try Notarizer.notarize(archive: archive, app: app, keychainProfile: profile)
    }

    private static func info(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        let (downloader, manifest) = try cacheAndManifest(&args, command: "info")
        try args.rejectLeftovers(usage: usage)
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
    }

    private static func clean(_ arguments: [String]) throws {
        var args = Arguments(arguments)
        guard let cache = args.option("cache").map({ URL(fileURLWithPath: $0) }) else {
            throw BundlingError("Missing --cache <dir>.")
        }
        try args.rejectLeftovers(usage: usage)
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.removeItem(at: cache)
            Log.info("Removed \(cache.path)")
        } else {
            Log.info("Nothing to clean (\(cache.path) does not exist).")
        }
    }
}
