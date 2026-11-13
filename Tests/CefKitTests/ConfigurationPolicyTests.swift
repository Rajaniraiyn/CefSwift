import Foundation
import Testing

@testable import CefKit
import CefBase

/// The typed options map onto Chromium preferences and switches, and the
/// presets choose them.
@Suite struct ConfigurationPolicyTests {
    @Test func defaultsWriteNothing() {
        let configuration = CefRuntime.Configuration()
        #expect(configuration.policyPreferences.isEmpty)
        #expect(configuration.policySwitches == ["disable-chrome-login-prompt"])
        #expect(configuration.runsComponentUpdater)
        #expect(CefRuntime.Configuration.browser.policyPreferences.isEmpty)
    }

    @Test func eachOptionSetsItsPreferences() {
        var configuration = CefRuntime.Configuration()
        configuration.services.translation = .disabled
        configuration.network.preloading = .disabled
        configuration.network.secureDNS = .secure(templates: ["https://a.example/dns-query{?dns}", "https://b.example/q"])
        configuration.privacy.thirdPartyCookies = .block
        configuration.security.httpsFirst = .strict
        configuration.credentials.passwordSaving = .disabled
        configuration.credentials.autofill = .disabled
        #expect(configuration.policyPreferences == [
            "translate.enabled": false,
            "net.network_prediction_options": 2,
            "dns_over_https.mode": "secure",
            "dns_over_https.templates": "https://a.example/dns-query{?dns} https://b.example/q",
            "profile.cookie_controls_mode": 1,
            "https_only_mode_enabled": true,
            "credentials_enable_service": false,
            "credentials_enable_autosignin": false,
            "autofill.profile_enabled": false,
            "autofill.credit_card_enabled": false,
        ])
        configuration.network.preloading = .extended
        configuration.network.secureDNS = .disabled
        configuration.security.httpsFirst = .balanced
        #expect(configuration.policyPreferences["net.network_prediction_options"] == 3)
        #expect(configuration.policyPreferences["dns_over_https.mode"] == "off")
        #expect(configuration.policyPreferences["https_first_balanced_mode_enabled"] == true)
        #expect(configuration.policyPreferences["https_only_mode_enabled"] == false)
    }

    @Test func explicitPreferencesWinOverTypedOptions() {
        var configuration = CefRuntime.Configuration()
        configuration.credentials.passwordSaving = .disabled
        configuration.preferences["credentials_enable_service"] = true
        #expect(configuration.effectivePreferences["credentials_enable_service"] == true)
        #expect(configuration.effectivePreferences["credentials_enable_autosignin"] == false)
    }

    @Test func componentUpdatesAreSeparateFromProtectedMedia() {
        var configuration = CefRuntime.Configuration()
        configuration.services.protectedMedia = .disabled
        #expect(configuration.runsComponentUpdater)
        #expect(!configuration.policySwitches.contains("disable-component-update"))
        configuration.services.componentUpdates = .disabled
        #expect(configuration.policySwitches.contains("disable-component-update"))
        // Protected media needs the updater, so it keeps it on.
        configuration.services.protectedMedia = .automatic
        #expect(configuration.runsComponentUpdater)
        #expect(!configuration.policySwitches.contains("disable-component-update"))
    }

    @Test func switchesFollowTheirOptions() {
        var configuration = CefRuntime.Configuration()
        configuration.privacy.hyperlinkAuditing = .disabled
        configuration.authenticationPrompt = .chromium
        #expect(configuration.policySwitches == ["no-pings"])
    }

    @Test func embeddedPresetChoosesLeanServices() {
        let configuration = CefRuntime.Configuration.embedded
        #expect(configuration.services.componentUpdates == .disabled)
        #expect(configuration.services.protectedMedia == .disabled)
        #expect(!configuration.runsComponentUpdater)
        #expect(Set(configuration.policySwitches) == ["disable-component-update", "no-pings", "disable-chrome-login-prompt"])
        #expect(configuration.policyPreferences["translate.enabled"] == false)
        #expect(configuration.policyPreferences["net.network_prediction_options"] == 2)
        #expect(configuration.policyPreferences["credentials_enable_service"] == false)
        #expect(configuration.policyPreferences["profile.cookie_controls_mode"] == nil)
        #expect(Set(configuration.extraCommandLineSwitches.keys) == [
            "disable-background-networking", "disable-sync", "disable-default-apps", "disable-domain-reliability",
            "no-first-run", "no-default-browser-check",
        ])
        #expect(configuration.disabledFeatures == ["MediaRouter", "OptimizationHints", "AutofillServerCommunication"])
    }

    @Test func keychainItemNames() {
        #expect(CefRuntime.KeychainItem.application.names(bundleIdentifier: "com.example.app")! == ("com.example.app Safe Storage", "com.example.app"))
        #expect(CefRuntime.KeychainItem.application.names(bundleIdentifier: nil) == nil)
        #expect(CefRuntime.KeychainItem.chromium.names(bundleIdentifier: "com.example.app") == nil)
        #expect(CefRuntime.KeychainItem.named(service: "S", account: "A").names(bundleIdentifier: nil)! == ("S", "A"))
        #expect(CefRuntime.Configuration().keychainItem == .application)
    }

    @Test func keychainNamesReachChromiumOnlyWithTheKeychain() {
        var configuration = CefRuntime.Configuration()
        configuration.keychainItem = .named(service: "Example Safe Storage", account: "Example")
        configuration.safeStorage = .keychain
        let keychain = MappedCefSettings(configuration: configuration, frameworkDirectory: nil)
        #expect(CefStringUtil.string(from: &keychain.raw.keychain_service_name) == "Example Safe Storage")
        #expect(CefStringUtil.string(from: &keychain.raw.keychain_account_name) == "Example")
        configuration.safeStorage = .mockKeychain
        let mock = MappedCefSettings(configuration: configuration, frameworkDirectory: nil)
        #expect(CefStringUtil.string(from: &mock.raw.keychain_service_name).isEmpty)
    }

    @Test func enterprisePolicyDomain() {
        #expect(CefRuntime.EnterprisePolicy.disabled.domain(bundleIdentifier: "com.example.app") == nil)
        #expect(CefRuntime.EnterprisePolicy.applicationBundleIdentifier.domain(bundleIdentifier: "com.example.app") == "com.example.app")
        #expect(CefRuntime.EnterprisePolicy.domain("com.google.Chrome").domain(bundleIdentifier: "x") == "com.google.Chrome")
        var configuration = CefRuntime.Configuration()
        #expect(configuration.enterprisePolicy == .disabled)
        configuration.enterprisePolicy = .domain("com.example.policy")
        let mapped = MappedCefSettings(configuration: configuration, frameworkDirectory: nil)
        #expect(CefStringUtil.string(from: &mapped.raw.chrome_policy_id) == "com.example.policy")
    }

    /// Switches and features CEF 156 for macOS does not have, which earlier
    /// presets set.
    @Test func noPresetSetsWhatChromium156Lacks() {
        let absent: Set<String> = [
            "CalculateNativeWinOcclusion", "InterestFeedContentSuggestions", "disable-client-side-phishing-detection",
            "DisableLoadExtensionCommandLineSwitch", "disable-breakpad", "Translate",
        ]
        for configuration in [CefRuntime.Configuration(), .embedded, .browser] {
            #expect(absent.isDisjoint(with: configuration.extraCommandLineSwitches.keys))
            #expect(absent.isDisjoint(with: configuration.disabledFeatures))
            #expect(absent.isDisjoint(with: configuration.chromiumFeatures.disabled))
        }
    }
}
