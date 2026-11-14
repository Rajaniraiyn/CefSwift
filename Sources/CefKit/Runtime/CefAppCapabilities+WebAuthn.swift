import Foundation

extension CefAppCapabilities {
    /// One of Chromium's native WebAuthn authenticators: what Chromium can
    /// offer a page that asks for a passkey or security key when Chromium
    /// answers the request itself. Which ones the app has depends on how it
    /// is signed and what it is entitled to.
    ///
    /// Chromium's own profile passkeys, verified with Touch ID, are not
    /// among them: CEF 156 looks for a keychain access group without a
    /// team prefix, which no provisioning profile can authorize, so stock
    /// CEF never offers them (docs/bundling.md). CefPasskeys'
    /// `CefPasskeyController` verifies the user with Touch ID instead.
    public enum WebAuthnAuthenticator: String, Sendable, Hashable, CaseIterable {
        /// USB and NFC security keys. Always available.
        case securityKey
        /// A phone or tablet, through a QR code and Bluetooth. Needs
        /// `NSBluetoothAlwaysUsageDescription` (and, under the hardened
        /// runtime, `com.apple.security.device.bluetooth`).
        case hybrid
        /// iCloud Keychain passkeys, through AuthenticationServices. Needs
        /// `com.apple.developer.web-browser.public-key-credential`.
        case iCloudKeychain
    }

    /// The native WebAuthn authenticators Chromium can offer this app's
    /// pages when it answers a request itself.
    ///
    /// The set says what the app's signature, entitlements and Info.plist
    /// make it eligible for, not that an authenticator is there: no
    /// security key may be plugged in, Bluetooth may be off, the user may
    /// have no iCloud Keychain passkey for the site or may refuse to
    /// authorize the app, and any authentication can still fail.
    public var webAuthnAuthenticators: Set<WebAuthnAuthenticator> {
        var authenticators: Set<WebAuthnAuthenticator> = [.securityKey]
        if usageDescriptions.contains("NSBluetoothAlwaysUsageDescription"),
           !isHardenedRuntime || entitlements.contains("com.apple.security.device.bluetooth") {
            authenticators.insert(.hybrid)
        }
        // macOS refuses to launch an app whose restricted entitlements no
        // profile authorizes, so a running app's entitlements are real.
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
        case .iCloudKeychain: return "iCloud Keychain"
        }
    }
}
