import Foundation
import Security
import Testing

@testable import CefKit
@testable import CefPasskeys

/// The authenticators Chromium offers, from made-up signing information.
@Suite struct PasskeyCapabilitiesTests {
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
        #expect(CefAppCapabilities(signingInformation: nil, infoDictionary: [:]).passkeyAuthenticators == [.securityKey])
        #expect(CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: [:]).passkeyAuthenticators
            == [.securityKey])
    }

    @Test func bluetoothUsageEnablesHybrid() {
        let info = ["NSBluetoothAlwaysUsageDescription": "Phones as passkeys"]
        let plain = CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: info)
        #expect(plain.passkeyAuthenticators.contains(.hybrid))

        // Under the hardened runtime the Bluetooth entitlement is needed too.
        let hardened = CefAppCapabilities(signingInformation: signing(flags: 0x10002), infoDictionary: info)
        #expect(hardened.isHardenedRuntime)
        #expect(!hardened.passkeyAuthenticators.contains(.hybrid))
        let entitled = CefAppCapabilities(
            signingInformation: signing(flags: 0x10002, entitlements: ["com.apple.security.device.bluetooth": true]),
            infoDictionary: info)
        #expect(entitled.passkeyAuthenticators.contains(.hybrid))
    }

    @Test func iCloudKeychainNeedsAnAppleTeam() {
        let selfSigned = CefAppCapabilities(
            signingInformation: signing(flags: 0, team: "A1B2C3D4E5", entitlements: [
                "com.apple.developer.web-browser.public-key-credential": true,
            ]),
            infoDictionary: [:])
        #expect(selfSigned.teamIdentifier == nil)
        #expect(!selfSigned.passkeyAuthenticators.contains(.iCloudKeychain))
    }

    @Test func theTestRunnerOffersSecurityKeys() {
        #expect(CefAppCapabilities.current.passkeyAuthenticators.contains(.securityKey))
    }
}
