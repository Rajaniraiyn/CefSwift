import Foundation

/// A decoded provisioning profile: the property list inside the CMS
/// envelope of a `.provisionprofile` file (`security cms -D -i <file>`).
struct ProvisioningProfile: Sendable {
    enum Kind: String, Codable, Sendable {
        /// Lists the devices it runs on; pairs with Apple Development.
        case development
        /// Runs on any Mac; pairs with Developer ID Application.
        case developerID
        /// Neither: an App Store profile, which pairs with Apple
        /// Distribution.
        case appStore

        var matchingSignature: SignatureKind {
            switch self {
            case .development: return .development
            case .developerID: return .developerID
            case .appStore: return .appStore
            }
        }
    }

    var name: String
    var uuid: String
    var teamIdentifiers: [String]
    var platforms: [String]
    var expirationDate: Date?
    var entitlements: PlistDictionary
    var provisionedDevices: [String]
    var provisionsAllDevices: Bool
    /// DER-encoded certificates the profile may be used with.
    var developerCertificates: [Data]

    var kind: Kind {
        if provisionsAllDevices { return .developerID }
        if !provisionedDevices.isEmpty { return .development }
        return .appStore
    }

    /// The profile's application identifier, such as
    /// `A1B2C3D4E5.com.example.browser` or `A1B2C3D4E5.*`.
    var applicationIdentifier: String? {
        entitlements["com.apple.application-identifier"]?.stringValue
            ?? entitlements["application-identifier"]?.stringValue
    }

    init(plist: PlistDictionary) throws {
        guard let entitlements = plist["Entitlements"]?.dictionaryValue else {
            throw CefPluginError("The provisioning profile has no Entitlements dictionary; it may be damaged.")
        }
        name = plist["Name"]?.stringValue ?? "(unnamed)"
        uuid = plist["UUID"]?.stringValue ?? ""
        teamIdentifiers = plist["TeamIdentifier"]?.strings ?? []
        platforms = plist["Platform"]?.strings ?? []
        if case .date(let date)? = plist["ExpirationDate"] { expirationDate = date }
        self.entitlements = entitlements
        provisionedDevices = plist["ProvisionedDevices"]?.strings ?? []
        provisionsAllDevices = plist["ProvisionsAllDevices"]?.boolValue ?? false
        developerCertificates = (plist["DeveloperCertificates"]?.arrayValue ?? []).compactMap {
            if case .data(let data) = $0 { return data }
            return nil
        }
    }

    init(decodedData: Data, source: String) throws {
        try self.init(plist: Plist.decode(decodedData, source: source))
    }

    /// Whether the profile allows the entitlement `key` with `value`. A
    /// profile string ending in `*` allows any string with that prefix;
    /// an array value is allowed when each element is.
    func authorizes(_ key: String, _ value: PlistValue) -> Bool {
        guard let allowed = entitlements[key] else { return !value.isGranting }
        switch value {
        case .bool(let requested):
            return !requested || allowed.boolValue == true || !allowed.strings.isEmpty
        case .string(let requested):
            return Self.matches(requested, anyOf: allowed.strings)
        case .array(let requested):
            let patterns = allowed.strings
            return requested.allSatisfy { element in
                element.stringValue.map { Self.matches($0, anyOf: patterns) } ?? false
            }
        default:
            return allowed == value
        }
    }

    static func matches(_ value: String, anyOf patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*") ? value.hasPrefix(pattern.dropLast()) : value == pattern
        }
    }

    /// One problem with using this profile for a bundle.
    struct Problem: Equatable, Sendable {
        /// Errors make AMFI refuse to launch the app; warnings make a
        /// feature fail.
        var isError: Bool
        var message: String
    }

    /// Checks the profile against the bundle it is embedded in.
    func problems(
        bundleIdentifier: String,
        identity: SigningIdentity,
        certificateSHA1: String?,
        entitlements requested: PlistDictionary,
        now: Date = Date()
    ) -> [Problem] {
        var problems: [Problem] = []
        func error(_ message: String) { problems.append(Problem(isError: true, message: message)) }
        func warning(_ message: String) { problems.append(Problem(isError: false, message: message)) }

        if !platforms.isEmpty, !platforms.contains("OSX") {
            error("Profile '\(name)' is for \(platforms.joined(separator: ", ")), not macOS.")
        }
        if let expirationDate, expirationDate < now {
            error("Profile '\(name)' expired on \(Self.dateFormatter.string(from: expirationDate)). " +
                  "Download a current one from the Apple Developer website.")
        }
        if let team = identity.teamIdentifier, !teamIdentifiers.isEmpty, !teamIdentifiers.contains(team) {
            error("Profile '\(name)' belongs to team \(teamIdentifiers.joined(separator: ", ")), but the " +
                  "signing identity '\(identity.name)' belongs to team \(team).")
        }
        if let appID = applicationIdentifier {
            let team = identity.teamIdentifier ?? teamIdentifiers.first ?? ""
            let wanted = "\(team).\(bundleIdentifier)"
            if !Self.matches(wanted, anyOf: [appID]) {
                error("Profile '\(name)' is for the App ID \(appID), not \(wanted). Set bundleIdentifier " +
                      "to match it, or create a profile for \(bundleIdentifier).")
            }
        }
        if identity.kind.hasAppleTeam, identity.kind != kind.matchingSignature {
            error("Profile '\(name)' is a \(kind.rawValue) profile, which pairs with a " +
                  "\(kind.matchingSignature.displayName) certificate, but the bundle is signed with " +
                  "\(identity.kind.displayName) ('\(identity.name)').")
        }
        if let certificateSHA1, !developerCertificates.isEmpty,
           !developerCertificates.contains(where: { SHA1.hex($0).caseInsensitiveCompare(certificateSHA1) == .orderedSame }) {
            error("Profile '\(name)' does not include the certificate of '\(identity.name)' (SHA-1 " +
                  "\(certificateSHA1)). Regenerate the profile with that certificate selected.")
        }
        for (key, value) in requested.sorted(by: { $0.key < $1.key })
        where Entitlements.isRestricted(key) && !authorizes(key, value) {
            error("Profile '\(name)' does not authorize the entitlement \(key) = \(Entitlements.describe(value)). " +
                  "Enable the matching capability for the App ID and download the profile again.")
        }
        return problems
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
