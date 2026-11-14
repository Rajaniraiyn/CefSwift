import Foundation

extension CefRuntime {
    /// Whether Chromium keeps the key that encrypts cookies and other secrets in
    /// the user's keychain, in the item ``CefRuntime/Configuration/keychainItem`` names.
    ///
    /// The first time an app uses that item, macOS asks the user to allow it.
    /// Choosing Always Allow records the app's code signature, so a signed app
    /// asks once. Ad-hoc signed builds get a new signature on every build and
    /// are asked again each time. The prompt belongs to macOS and cannot be
    /// customized.
    public enum SafeStoragePolicy: Sendable {
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
}

extension CefRuntime {
    /// The keychain item that holds Chromium's encryption key, for
    /// ``CefRuntime/SafeStoragePolicy/keychain``. Set it with
    /// ``CefRuntime/Configuration/keychainItem``.
    ///
    /// The key encrypts each profile's cookies, saved passwords and other
    /// secrets. Another item holds another key, so changing the item makes
    /// what profiles saved under the old one unreadable: Chromium drops those
    /// cookies and passwords. Choose the item before the first release.
    public enum KeychainItem: Sendable, Equatable {
        /// An item of the app's own: service `"<bundle identifier> Safe
        /// Storage"`, account `"<bundle identifier>"`. Other Chromium-based
        /// apps, which share Chromium's item, cannot read it. The default.
        case application
        /// Chromium's own item, "Chromium Safe Storage", which every app built
        /// on stock Chromium or CEF uses unless it names another.
        case chromium
        /// An item by service and account name, for instance one several apps
        /// of yours share (each needs the user's permission to read it).
        case named(service: String, account: String)

        /// The service and account Chromium gets; `nil` for Chromium's own.
        func names(bundleIdentifier: String?) -> (service: String, account: String)? {
            switch self {
            case .chromium:
                return nil
            case .named(let service, let account):
                return (service, account)
            case .application:
                guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
                return ("\(bundleIdentifier) Safe Storage", bundleIdentifier)
            }
        }
    }
}

extension CefRuntime.SafeStoragePolicy {
    /// The policy with ``automatic`` replaced by the policy for this app:
    /// ``keychain`` with a team signature, ``mockKeychain`` otherwise.
    func resolved() -> CefRuntime.SafeStoragePolicy {
        CefAppCapabilities.current.resolvedSafeStorage(self)
    }
}
