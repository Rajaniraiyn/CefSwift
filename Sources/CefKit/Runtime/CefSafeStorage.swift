import Foundation
import Security

/// Whether Chromium keeps the key that encrypts cookies and other secrets in
/// the user's keychain, as the "Chromium Safe Storage" item.
///
/// The first time an app uses that item, macOS asks the user to allow it.
/// Choosing Always Allow records the app's code signature, so a signed app
/// asks once. Ad-hoc signed builds get a new signature on every build and
/// are asked again each time. The prompt belongs to macOS and cannot be
/// customized.
public enum CefSafeStoragePolicy: Sendable {
    /// ``keychain`` when the app is signed with a developer identity, where
    /// the user's Always Allow sticks; ``mockKeychain`` when it is unsigned
    /// or ad-hoc signed, as local builds are, where it would not. The
    /// default.
    case automatic

    /// Keep the key in the keychain, as Chrome does.
    case keychain

    /// Use a fixed key and never touch the keychain
    /// (`--use-mock-keychain`). Nothing is protected at rest, so use this
    /// only for development, demos and tests.
    case mockKeychain
}

extension CefSafeStoragePolicy {
    /// The policy with ``automatic`` replaced by the policy for this app.
    func resolved() -> CefSafeStoragePolicy {
        switch self {
        case .keychain, .mockKeychain:
            return self
        case .automatic:
            return Self.hasDeveloperSignature ? .keychain : .mockKeychain
        }
    }

    /// Whether the running app is signed with a team identity, as opposed to
    /// unsigned or ad-hoc signed.
    private static let hasDeveloperSignature: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any]
        else { return false }
        return details[kSecCodeInfoTeamIdentifier as String] is String
    }()
}
