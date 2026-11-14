import Foundation

extension CefRuntime {
    /// Whether Chromium applies enterprise policies: the settings an
    /// administrator manages for Chrome, such as `HomepageLocation`,
    /// `PasswordManagerEnabled` or `URLBlocklist` (Chrome's policy list names
    /// them all).
    ///
    /// Set it with ``CefRuntime/Configuration/enterprisePolicy``. Chromium reads
    /// policies from the preferences domain named here (`cef_settings_t`'s
    /// `chrome_policy_id`): values a configuration profile or
    /// `/Library/Managed Preferences` forces are mandatory, and the user cannot
    /// change them; values in the user's own preferences for the domain
    /// (`defaults write <domain> <Policy> <value>`) are recommended, and set the
    /// default the user can change. On a Mac that is not managed, Chromium
    /// ignores the policies it counts as sensitive. `chrome://policy` lists
    /// what applies, in Chrome-style browsers.
    public enum EnterprisePolicy: Sendable, Equatable {
        /// No policies. The default.
        case disabled
        /// Policies from the app's own domain, its bundle identifier, which
        /// an administrator manages as they would Chrome's
        /// (`com.google.Chrome`).
        case applicationBundleIdentifier
        /// Policies from another domain, such as `com.google.Chrome` to follow
        /// what is managed for Chrome.
        case domain(String)

        /// The domain Chromium reads, or `nil` for none.
        func domain(bundleIdentifier: String?) -> String? {
            switch self {
            case .disabled: return nil
            case .applicationBundleIdentifier: return bundleIdentifier
            case .domain(let domain): return domain.isEmpty ? nil : domain
            }
        }
    }
}
