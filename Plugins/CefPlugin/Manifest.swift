import Foundation
import PackagePlugin

/// Decoded form of `CEF_VERSION.json` (schema pinned in DESIGN.md).
struct CefManifest: Decodable {
    struct Artifact: Decodable {
        let name: String
        let sha1: String
        let size: Int
    }

    let cef: String
    let chromium: String
    let channel: String
    /// platform ("macosarm64" | "macosx64") → flavor ("minimal" | "standard") → artifact
    let platforms: [String: [String: Artifact]]

    /// The URL of the manifest file this was decoded from.
    var sourceURL: URL = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey { case cef, chromium, channel, platforms }

    /// Looks up the artifact for a platform/flavor pair with actionable errors.
    func artifact(platform: String, flavor: String) throws -> Artifact {
        guard let flavors = platforms[platform] else {
            throw CefPluginError(
                "CEF_VERSION.json has no platform '\(platform)'. " +
                "Available: \(platforms.keys.sorted().joined(separator: ", ")). " +
                "Pass --platform with one of those values."
            )
        }
        guard let artifact = flavors[flavor] else {
            throw CefPluginError(
                "CEF_VERSION.json has no flavor '\(flavor)' for platform '\(platform)'. " +
                "Available: \(flavors.keys.sorted().joined(separator: ", ")). " +
                "Pass --flavor with one of those values."
            )
        }
        return artifact
    }

    static func load(from url: URL) throws -> CefManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CefPluginError(
                "No CEF manifest at \(url.path). " +
                "Pass --manifest <path-to-CEF_VERSION.json> or run the command from a package that contains one."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CefPluginError("Could not read \(url.path): \(error.localizedDescription)")
        }
        do {
            var manifest = try JSONDecoder().decode(CefManifest.self, from: data)
            manifest.sourceURL = url
            return manifest
        } catch {
            throw CefPluginError(
                "Could not decode \(url.path) as a CEF manifest: \(error). " +
                "Expected the schema documented in DESIGN.md (§CEF_VERSION.json)."
            )
        }
    }

    /// Resolves the manifest for a plugin invocation:
    /// 1. explicit `--manifest <path>` argument,
    /// 2. `CEF_VERSION.json` in the invoking package's root,
    /// 3. `CEF_VERSION.json` in any (transitive) package dependency — covers
    ///    running from `Examples/`, where CefSwift (the plugin provider) is a
    ///    path dependency and carries the manifest.
    static func resolve(context: PluginContext, explicitPath: String?) throws -> CefManifest {
        if let explicitPath {
            let url = URL(
                fileURLWithPath: explicitPath,
                relativeTo: context.package.directoryURL
            ).absoluteURL
            return try load(from: url)
        }

        let candidate = context.package.directoryURL.appendingPathComponent("CEF_VERSION.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try load(from: candidate)
        }

        // Breadth-first walk of package dependencies.
        var queue = context.package.dependencies.map(\.package)
        var seen = Set<String>()
        while !queue.isEmpty {
            let package = queue.removeFirst()
            guard seen.insert(package.id).inserted else { continue }
            let url = package.directoryURL.appendingPathComponent("CEF_VERSION.json")
            if FileManager.default.fileExists(atPath: url.path) {
                return try load(from: url)
            }
            queue.append(contentsOf: package.dependencies.map(\.package))
        }

        throw CefPluginError(
            "Could not find CEF_VERSION.json in \(context.package.directoryURL.path) " +
            "or in any package dependency. Pass --manifest <path> explicitly."
        )
    }
}

/// Host platform detection (download default).
enum HostPlatform {
    static var cefPlatform: String {
        #if arch(arm64)
        return "macosarm64"
        #else
        return "macosx64"
        #endif
    }
}
