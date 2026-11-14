import Foundation

/// Decoded form of `CEF_VERSION.json`. Schema: `cef`, `chromium`, `channel`,
/// `platforms` keyed by `macosarm64`/`macosx64`, each with `minimal`/`standard`
/// artifacts containing `name`, `sha1`, `size`.
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
            throw BundlingError(
                "CEF_VERSION.json has no platform '\(platform)'. " +
                "Available: \(platforms.keys.sorted().joined(separator: ", ")). " +
                "Pass --platform with one of those values."
            )
        }
        guard let artifact = flavors[flavor] else {
            throw BundlingError(
                "CEF_VERSION.json has no flavor '\(flavor)' for platform '\(platform)'. " +
                "Available: \(flavors.keys.sorted().joined(separator: ", ")). " +
                "Pass --flavor with one of those values."
            )
        }
        return artifact
    }

    static func load(from url: URL) throws -> CefManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BundlingError(
                "No CEF manifest at \(url.path). " +
                "Pass --manifest <path-to-CEF_VERSION.json> or run the command from a package that contains one."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BundlingError("Could not read \(url.path): \(error.localizedDescription)")
        }
        do {
            var manifest = try JSONDecoder().decode(CefManifest.self, from: data)
            manifest.sourceURL = url
            return manifest
        } catch {
            throw BundlingError(
                "Could not decode \(url.path) as a CEF manifest: \(error). " +
                "Expected the schema: {cef, chromium, channel, platforms:{macosarm64|macosx64:{minimal|standard:{name,sha1,size}}}}."
            )
        }
    }
}
