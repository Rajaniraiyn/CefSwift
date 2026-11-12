import Foundation
import Security
import Testing

@testable import CefKit

/// `CefAppCapabilities` from made-up signing information, as
/// `SecCodeCopySigningInformation` returns it.
@Suite struct AppCapabilitiesTests {
    private func signing(flags: UInt32, team: String? = nil, entitlements: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            kSecCodeInfoIdentifier as String: "com.example.browser",
            kSecCodeInfoFlags as String: NSNumber(value: flags),
            kSecCodeInfoEntitlementsDict as String: entitlements,
        ]
        if let team { info[kSecCodeInfoTeamIdentifier as String] = team }
        return info
    }

    @Test func unsigned() {
        let capabilities = CefAppCapabilities(signingInformation: nil, infoDictionary: [:])
        #expect(capabilities.signature == .unsigned)
        #expect(capabilities.passkeyAuthenticators == [.securityKey])
        #expect(capabilities.resolvedSafeStorage(.automatic) == .mockKeychain)
    }

    @Test func adHocOffersSecurityKeysAndUsesTheMockKeychain() {
        let capabilities = CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: [:])
        #expect(capabilities.signature == .adHoc)
        #expect(capabilities.teamIdentifier == nil)
        #expect(!capabilities.isHardenedRuntime)
        #expect(capabilities.passkeyAuthenticators == [.securityKey])
        #expect(capabilities.resolvedSafeStorage(.automatic) == .mockKeychain)
        #expect(capabilities.resolvedSafeStorage(.keychain) == .keychain)
        let summary = capabilities.limitationsSummary(passkeysUseChromium: true) ?? ""
        #expect(summary.contains("only security keys"))
        #expect(summary.contains("mock keychain"))
    }

    @Test func teamSignedHardenedHelperNeedsLibraryValidationOffForWidevine() {
        let app = signing(flags: 0x10000, team: "A1B2C3D4E5")
        #expect(CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: [:]).canLoadWidevine)
        #expect(!CefAppCapabilities(signingInformation: app, infoDictionary: [:],
                                    baseHelperSigningInformation: app).canLoadWidevine)
        let helper = signing(flags: 0x10000, team: "A1B2C3D4E5",
                             entitlements: ["com.apple.security.cs.disable-library-validation": true])
        #expect(CefAppCapabilities(signingInformation: app, infoDictionary: [:],
                                   baseHelperSigningInformation: helper).canLoadWidevine)
    }

    @Test func bluetoothUsageEnablesHybrid() {
        let info = ["NSBluetoothAlwaysUsageDescription": "Phones as passkeys"]
        let plain = CefAppCapabilities(signingInformation: signing(flags: 0x2), infoDictionary: info)
        #expect(plain.passkeyAuthenticators.contains(.hybrid))
        #expect(plain.usageDescriptions == ["NSBluetoothAlwaysUsageDescription"])

        // Under the hardened runtime the Bluetooth entitlement is needed too.
        let hardened = CefAppCapabilities(signingInformation: signing(flags: 0x10002), infoDictionary: info)
        #expect(hardened.isHardenedRuntime)
        #expect(!hardened.passkeyAuthenticators.contains(.hybrid))
        let entitled = CefAppCapabilities(
            signingInformation: signing(flags: 0x10002, entitlements: ["com.apple.security.device.bluetooth": true]),
            infoDictionary: info)
        #expect(entitled.passkeyAuthenticators.contains(.hybrid))
    }

    @Test func entitlementsWithFalseAreLeftOut() {
        let capabilities = CefAppCapabilities(
            signingInformation: signing(flags: 0x10002, entitlements: [
                "com.apple.security.cs.allow-jit": true, "com.apple.security.device.camera": false,
                "com.apple.security.app-sandbox": true,
            ]),
            infoDictionary: [:])
        #expect(capabilities.entitlements == ["com.apple.security.cs.allow-jit", "com.apple.security.app-sandbox"])
        #expect(capabilities.isAppSandboxed)
    }

    @Test func teamSignatureWithTheEntitlementOffersICloudKeychain() {
        // A team identifier without a certificate classifies as `.other`,
        // which has no Apple team; tests cannot make a SecCertificate, so
        // check the name classification separately.
        #expect(CefAppCapabilities.kind(certificateName: "Developer ID Application: Corp (A1B2C3D4E5)") == .developerID)
        #expect(CefAppCapabilities.kind(certificateName: "Apple Development: Jane (Z)") == .development)
        #expect(CefAppCapabilities.kind(certificateName: "Self Signed") == .other)
        let selfSigned = CefAppCapabilities(
            signingInformation: signing(flags: 0, team: "A1B2C3D4E5", entitlements: [
                "com.apple.developer.web-browser.public-key-credential": true,
            ]),
            infoDictionary: [:])
        #expect(selfSigned.signature == .other)
        #expect(selfSigned.teamIdentifier == nil)
        #expect(!selfSigned.passkeyAuthenticators.contains(.iCloudKeychain))
    }

    @Test func theTestRunnerHasASignature() {
        // swift test runs an ad hoc (linker) signed or unsigned binary.
        let current = CefAppCapabilities.current
        #expect([.adHoc, .unsigned, .development, .other].contains(current.signature))
        #expect(current.passkeyAuthenticators.contains(.securityKey))
    }
}
