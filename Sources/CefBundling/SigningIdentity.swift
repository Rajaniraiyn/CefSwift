import Foundation

/// What kind of certificate signs a bundle, which decides what macOS lets
/// the app do.
enum SignatureKind: String, Codable, Sendable {
    /// No signature at all.
    case unsigned
    /// `codesign --sign -`: no certificate and no team. Runs on the Mac
    /// that built it; restricted entitlements are refused.
    case adHoc
    /// "Apple Development" (or the older "Mac Developer"): runs on the
    /// devices of a development provisioning profile.
    case development
    /// "Developer ID Application": for distribution outside the App Store,
    /// with notarization.
    case developerID
    /// "Apple Distribution" or "3rd Party Mac Developer Application": for
    /// the Mac App Store.
    case appStore
    /// Any other certificate, such as a self-signed one. It has no team
    /// identifier that Apple vouches for.
    case other

    /// Classifies a certificate by its common name, as `codesign` and
    /// `security find-identity` print it.
    init(certificateName name: String) {
        if name == "-" {
            self = .adHoc
        } else if name.hasPrefix("Apple Development:") || name.hasPrefix("Mac Developer:") {
            self = .development
        } else if name.hasPrefix("Developer ID Application:") {
            self = .developerID
        } else if name.hasPrefix("Apple Distribution:") || name.hasPrefix("3rd Party Mac Developer Application:")
                    || name.hasPrefix("Mac App Distribution:") {
            self = .appStore
        } else {
            self = .other
        }
    }

    /// Whether Apple issued the certificate to a team, so the signature
    /// carries a team identifier that keychain access groups, library
    /// validation and provisioning profiles rely on.
    var hasAppleTeam: Bool {
        switch self {
        case .development, .developerID, .appStore: return true
        case .unsigned, .adHoc, .other: return false
        }
    }

    var displayName: String {
        switch self {
        case .unsigned: return "unsigned"
        case .adHoc: return "ad hoc"
        case .development: return "Apple Development"
        case .developerID: return "Developer ID"
        case .appStore: return "App Store distribution"
        case .other: return "a certificate without an Apple team"
        }
    }
}

/// The identity `cef bundle` signs with.
struct SigningIdentity: Equatable, Sendable {
    /// What `codesign --sign` takes: a certificate name, a SHA-1 hash, or
    /// "-" for ad hoc.
    var name: String
    var kind: SignatureKind
    /// The team identifier: the certificate's organizational unit.
    var teamIdentifier: String?

    static let adHoc = SigningIdentity(name: "-", kind: .adHoc, teamIdentifier: nil)

    var isAdHoc: Bool { kind == .adHoc }

    /// Parses `security find-identity -v -p codesigning`, whose lines look
    /// like `  1) <SHA-1> "Apple Development: Jane Doe (A1B2C3D4E5)"`.
    static func parseFindIdentity(_ output: String) -> [(hash: String, name: String)] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let close = trimmed.firstIndex(of: ")"),
                  let start = trimmed.firstIndex(of: "\""),
                  let end = trimmed.lastIndex(of: "\""), start < end
            else { return nil }
            let hash = trimmed[trimmed.index(after: close)..<start].trimmingCharacters(in: .whitespaces)
            return (hash, String(trimmed[trimmed.index(after: start)..<end]))
        }
    }

    /// The organizational unit in a subject that
    /// `openssl x509 -noout -subject -nameopt RFC2253` prints, such as
    /// `subject=UID=…,CN=Apple Development: Jane Doe (X),OU=A1B2C3D4E5,O=Jane Doe,C=US`.
    /// Apple certificates keep the team identifier there; the parenthesized
    /// identifier in an Apple Development certificate's name is the
    /// person's, not the team's.
    static func organizationalUnit(inSubject subject: String) -> String? {
        var text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("subject=") { text.removeFirst("subject=".count) }
        // RFC 2253 escapes commas inside values with a backslash.
        var components: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "," {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        components.append(current)
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == "OU", isTeamIdentifier(parts[1]) {
                return parts[1]
            }
        }
        return nil
    }

    /// Apple team identifiers are ten upper-case letters and digits.
    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}
