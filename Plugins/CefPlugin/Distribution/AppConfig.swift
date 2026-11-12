import Foundation

/// Per-product settings, read from `cefapp.json` next to the product
/// target's sources. Comments and trailing commas are allowed (JSON5).
/// Paths are relative to the file's directory.
struct CefAppConfig: Decodable, Sendable {
    var bundleIdentifier: String?
    var displayName: String?
    var minimumSystemVersion: String?
    /// `CFBundleShortVersionString`, the version users see.
    var version: String?
    /// `CFBundleVersion`, the build number.
    var build: String?
    /// The codesigning identity, or "-" for ad hoc.
    var signingIdentity: String?
    /// The team identifier, when it cannot be read from the certificate.
    var teamIdentifier: String?
    /// A keychain file to find the identity in, instead of the search list.
    var signingKeychain: String?
    /// Defaults to on for Apple team identities and off otherwise.
    var hardenedRuntime: Bool?
    /// A secure timestamp from Apple's server. Defaults to on for
    /// Developer ID and App Store signing.
    var timestamp: Bool?
    var capabilities: [String]?
    /// Usage descriptions by capability name.
    var usageDescriptions: [String: String]?
    /// Keys merged into the app's Info.plist.
    var infoPlist: PlistDictionary?
    /// The app's entitlements file.
    var entitlements: String?
    /// Entitlements files merged over a helper's built-in ones, by helper:
    /// `helper`, `alerts`, `gpu`, `plugin`, `renderer`.
    var helperEntitlements: [String: String]?
    /// Embedded as `Contents/embedded.provisionprofile`.
    var provisioningProfile: String?
    var notarization: Notarization?
    /// What the app keeps of the CEF framework: locale packs and the
    /// software GPU fallback.
    var cef: CefFrameworkOptions?

    struct Notarization: Decodable, Sendable {
        /// A `notarytool store-credentials` profile name.
        var keychainProfile: String?
        /// `zip` (default) or `dmg`.
        var format: String?
    }

    /// The directory holding the file, which relative paths start from.
    var directory: URL = URL(fileURLWithPath: "/")
    var source: URL = URL(fileURLWithPath: "/cefapp.json")

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleIdentifier, displayName, minimumSystemVersion, version, build, signingIdentity,
             teamIdentifier, signingKeychain, hardenedRuntime, timestamp, capabilities, usageDescriptions,
             infoPlist, entitlements, helperEntitlements, provisioningProfile, notarization, cef
    }

    static let fileName = "cefapp.json"

    /// Loads `cefapp.json` from the target directory, or `explicit`.
    /// Returns nil when there is none.
    static func load(near targetDirectory: URL?, explicit: URL? = nil) throws -> CefAppConfig? {
        let url: URL
        if let explicit {
            url = explicit
        } else if let targetDirectory {
            url = targetDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        } else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CefPluginError("Could not read \(url.path): \(error.localizedDescription)")
        }
        return try decode(data, source: url)
    }

    static func decode(_ data: Data, source: URL) throws -> CefAppConfig {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        var config: CefAppConfig
        do {
            config = try decoder.decode(CefAppConfig.self, from: data)
        } catch let error as DecodingError {
            throw CefPluginError("\(source.path) is not valid: \(describe(error))")
        } catch {
            throw CefPluginError("\(source.path) is not valid: \(error)")
        }
        config.source = source
        config.directory = source.deletingLastPathComponent()

        if let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] {
            let known = Set(CodingKeys.allCases.map(\.rawValue))
            for key in object.keys.sorted() where !known.contains(key) {
                throw CefPluginError(
                    "\(source.path): unknown key \"\(key)\". Known keys: \(known.sorted().joined(separator: ", ")).")
            }
        }
        if let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any],
           let cef = object["cef"] as? [String: Any] {
            let known = Set(CefFrameworkOptions.CodingKeys.allCases.map(\.rawValue))
            for key in cef.keys.sorted() where !known.contains(key) {
                throw CefPluginError(
                    "\(source.path): unknown key \"cef.\(key)\". Known keys: \(known.sorted().joined(separator: ", ")).")
            }
        }
        if let value = config.cef?.softwareGPUFallback {
            _ = try FrameworkTrimPolicy.includesSoftwareGPU(from: value, source: source.path)
        }
        for name in config.helperEntitlements?.keys.sorted() ?? [] where HelperKind(rawValue: name) == nil {
            throw CefPluginError(
                "\(source.path): unknown helper \"\(name)\" in helperEntitlements. Use one of: " +
                "\(HelperKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return config
    }

    /// The trim policy: `cef` with the command line's options over it.
    func trimPolicy(localizationsOption: String?, softwareGPUOption: String?) throws -> FrameworkTrimPolicy {
        var policy = FrameworkTrimPolicy()
        if let localizations = cef?.localizations { policy.localizations = localizations }
        if let value = cef?.softwareGPUFallback {
            policy.includesSoftwareGPU = try FrameworkTrimPolicy.includesSoftwareGPU(from: value, source: source.path)
        }
        if let localizationsOption { policy.localizations = try FrameworkTrimPolicy.localizations(fromOption: localizationsOption) }
        if let softwareGPUOption {
            policy.includesSoftwareGPU = try FrameworkTrimPolicy.includesSoftwareGPU(
                from: softwareGPUOption, source: "--software-gpu-fallback")
        }
        return policy
    }

    func resolve(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : " at \(keys.joined(separator: "."))"
        }
        switch error {
        case .typeMismatch(let type, let context):
            return "expected \(type)\(path(context)). \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing \(type)\(path(context))."
        case .keyNotFound(let key, let context):
            return "missing \(key.stringValue)\(path(context))."
        case .dataCorrupted(let context):
            return "\(context.debugDescription)\(path(context))"
        @unknown default:
            return "\(error)"
        }
    }
}
