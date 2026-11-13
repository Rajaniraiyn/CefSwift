import Foundation
import Security
import Testing

@testable import CefKit

/// The authenticators Chromium offers, from made-up signing information.
@Suite struct WebAuthnCapabilitiesTests {
    private func signing(flags: UInt32, team: String? = nil, entitlements: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            kSecCodeInfoIdentifier as String: "com.example.browser",
            kSecCodeInfoFlags as String: NSNumber(value: flags),
            kSecCodeInfoEntitlementsDict as String: entitlements,
        ]
        if let team { info[kSecCodeInfoTeamIdentifier as String] = team }
        return info
    }

    @Test func unsignedAndAdHocOfferSecurityKeys() {
        #expect(CefAppCapabilities(signingInformation: nil, infoDictionary: [:]).webAuthnAuthenticators == [.securityKey])
        #expect(CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: [:]).webAuthnAuthenticators
            == [.securityKey])
    }

    @Test func bluetoothUsageEnablesHybrid() {
        let info = ["NSBluetoothAlwaysUsageDescription": "Phones as passkeys"]
        let plain = CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: info)
        #expect(plain.webAuthnAuthenticators.contains(.hybrid))

        // Under the hardened runtime the Bluetooth entitlement is needed too.
        let hardened = CefAppCapabilities(signingInformation: signing(flags: 0x10002), infoDictionary: info)
        #expect(hardened.isHardenedRuntime)
        #expect(!hardened.webAuthnAuthenticators.contains(.hybrid))
        let entitled = CefAppCapabilities(
            signingInformation: signing(flags: 0x10002, entitlements: ["com.apple.security.device.bluetooth": true]),
            infoDictionary: info)
        #expect(entitled.webAuthnAuthenticators.contains(.hybrid))
    }

    @Test func iCloudKeychainNeedsAnAppleTeam() {
        let selfSigned = CefAppCapabilities(
            signingInformation: signing(flags: 0, team: "A1B2C3D4E5", entitlements: [
                "com.apple.developer.web-browser.public-key-credential": true,
            ]),
            infoDictionary: [:])
        #expect(selfSigned.teamIdentifier == nil)
        #expect(!selfSigned.webAuthnAuthenticators.contains(.iCloudKeychain))
    }

    @Test func theTestRunnerOffersSecurityKeys() {
        #expect(CefAppCapabilities.current.webAuthnAuthenticators.contains(.securityKey))
    }
}
