import Foundation

/// Whether Chromium keeps the key that encrypts cookies and other secrets in
/// the user's keychain, as the "Chromium Safe Storage" item.
///
/// The first time an app uses that item, macOS asks the user to allow it.
/// Choosing Always Allow records the app's code signature, so a signed app
/// asks once. Ad-hoc signed builds get a new signature on every build and
/// are asked again each time. The prompt belongs to macOS and cannot be
/// customized.
public enum CefSafeStoragePolicy: Sendable {
    /// ``mockKeychain`` in debug builds and ``keychain`` in release builds.
    /// The default.
    case automatic

    /// Keep the key in the keychain, as Chrome does.
    case keychain

    /// Use a fixed key and never touch the keychain
    /// (`--use-mock-keychain`). Nothing is protected at rest, so use this
    /// only for development, demos and tests.
    case mockKeychain
}

extension CefSafeStoragePolicy {
    /// The policy with ``automatic`` replaced by the policy for this build.
    func resolved() -> CefSafeStoragePolicy {
        switch self {
        case .keychain, .mockKeychain:
            return self
        case .automatic:
            #if DEBUG
            return .mockKeychain
            #else
            return .keychain
            #endif
        }
    }
}
