import Foundation

extension CefAppCapabilities {
    /// One of Chromium's native WebAuthn authenticators: what Chromium can
    /// offer a page that asks for a passkey or security key when Chromium
    /// answers the request itself. Which ones the app has depends on how it
    /// is signed and what it is entitled to.
    public enum WebAuthnAuthenticator: String, Sendable, Hashable, CaseIterable {
        /// USB and NFC security keys. Always available.
        case securityKey
        /// A phone or tablet, through a QR code and Bluetooth. Needs
        /// `NSBluetoothAlwaysUsageDescription` (and, under the hardened
        /// runtime, `com.apple.security.device.bluetooth`).
        case hybrid
        /// Chromium's own profile passkeys, verified with Touch ID. Needs
        /// the keychain group CEF compiles in, which a provisioning profile
        /// cannot authorize (see docs/bundling.md), so stock CEF builds do
        /// not offer it.
        case touchID
        /// iCloud Keychain passkeys, through AuthenticationServices. Needs
        /// `com.apple.developer.web-browser.public-key-credential`.
        case iCloudKeychain
    }

    /// The keychain access group Chromium's Touch ID authenticator checks
    /// for in CEF 156, without a team prefix.
    static let chromiumWebAuthnKeychainGroup = ".org.chromium.Chromium.webauthn"

    /// The native WebAuthn authenticators Chromium can offer this app's
    /// pages when it answers a request itself.
    public var webAuthnAuthenticators: Set<WebAuthnAuthenticator> {
        var authenticators: Set<WebAuthnAuthenticator> = [.securityKey]
        if usageDescriptions.contains("NSBluetoothAlwaysUsageDescription"),
           !isHardenedRuntime || entitlements.contains("com.apple.security.device.bluetooth") {
            authenticators.insert(.hybrid)
        }
        // macOS refuses to launch an app whose restricted entitlements no
        // profile authorizes, so a running app's entitlements are real.
        if teamIdentifier != nil, keychainAccessGroups.contains(Self.chromiumWebAuthnKeychainGroup) {
            authenticators.insert(.touchID)
        }
        if teamIdentifier != nil, entitlements.contains("com.apple.developer.web-browser.public-key-credential") {
            authenticators.insert(.iCloudKeychain)
        }
        return authenticators
    }
}

extension CefAppCapabilities.WebAuthnAuthenticator: CustomStringConvertible {
    public var description: String {
        switch self {
        case .securityKey: return "security keys"
        case .hybrid: return "phones"
        case .touchID: return "Touch ID"
        case .iCloudKeychain: return "iCloud Keychain"
        }
    }
}
