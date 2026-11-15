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
        #expect(CefRuntime.Configuration.chrome.policyPreferences.isEmpty)
    }

    @Test func eachOptionSetsItsPreferences() {
        var configuration = CefRuntime.Configuration()
        configuration.network.secureDNS = .secure(templates: ["https://a.example/dns-query{?dns}", "https://b.example/q"])
        #expect(configuration.policyPreferences == [
            "dns_over_https.mode": "secure",
            "dns_over_https.templates": "https://a.example/dns-query{?dns} https://b.example/q",
        ])
        configuration.network.secureDNS = .disabled
        #expect(configuration.policyPreferences["dns_over_https.mode"] == "off")
    }

    @Test func profileOptionsSetTheirPreferences() {
        var profile = CefProfile.Configuration()
        #expect(profile.setPreferences.isEmpty)
        // Every name an option controls is listed, so a change can reset it.
        #expect(Set(profile.preferences.keys) == [
            "translate.enabled", "net.network_prediction_options", "proxy", "profile.cookie_controls_mode",
            "https_first_balanced_mode_enabled", "https_only_mode_enabled", "credentials_enable_service",
            "credentials_enable_autosignin", "autofill.profile_enabled", "autofill.credit_card_enabled",
        ])
        profile.translation = .disabled
        profile.network.preloading = .disabled
        profile.privacy.thirdPartyCookies = .block
        profile.security.httpsFirst = .strict
        profile.credentials.passwordSaving = .disabled
        profile.credentials.autofill = .disabled
        profile.network.proxy = .servers("proxy.example:8080", bypassing: ["*.internal", "<local>"])
        #expect(profile.setPreferences == [
            "translate.enabled": false,
            "net.network_prediction_options": 2,
            "profile.cookie_controls_mode": 1,
            "https_only_mode_enabled": true,
            "credentials_enable_service": false,
            "credentials_enable_autosignin": false,
            "autofill.profile_enabled": false,
            "autofill.credit_card_enabled": false,
            "proxy": ["mode": "fixed_servers", "server": "proxy.example:8080", "bypass_list": "*.internal,<local>"],
        ])
        profile.network.preloading = .extended
        profile.security.httpsFirst = .balanced
        #expect(profile.setPreferences["net.network_prediction_options"] == 3)
        #expect(profile.setPreferences["https_first_balanced_mode_enabled"] == true)
        #expect(profile.setPreferences["https_only_mode_enabled"] == false)
        profile.network.proxy = .direct
        #expect(profile.setPreferences["proxy"] == ["mode": "direct"])
        profile.network.proxy = .system
        #expect(profile.setPreferences["proxy"] == ["mode": "system"])
        profile.network.proxy = .autoConfiguration(URL(string: "https://wpad.example/proxy.pac")!)
        #expect(profile.setPreferences["proxy"] == ["mode": "pac_script", "pac_url": "https://wpad.example/proxy.pac"])
    }

    /// A profile starts from the runtime's profile defaults, and changing
    /// any of its own configuration overrides only that profile.
    @MainActor @Test func profilesOverrideTheRuntimeDefaults() {
        let first = CefProfile.incognito(), second = CefProfile.incognito()
        #expect(first.configuration == CefProfile.Configuration())
        first.configuration.privacy.thirdPartyCookies = .block
        #expect(first.configuration.privacy.thirdPartyCookies == .block)
        #expect(second.configuration.privacy.thirdPartyCookies == .automatic)
    }

    @Test func explicitPreferencesWinOverTypedOptions() {
        var configuration = CefRuntime.Configuration()
        configuration.network.secureDNS = .disabled
        configuration.preferences["dns_over_https.mode"] = "automatic"
        #expect(configuration.effectivePreferences["dns_over_https.mode"] == "automatic")
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
        #expect(configuration.policyPreferences.isEmpty)
        #expect(configuration.profiles.setPreferences["translate.enabled"] == false)
        #expect(configuration.profiles.setPreferences["net.network_prediction_options"] == 2)
        #expect(configuration.profiles.setPreferences["credentials_enable_service"] == false)
        #expect(configuration.profiles.setPreferences["profile.cookie_controls_mode"] == nil)
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
        for configuration in [CefRuntime.Configuration(), .embedded, .chrome] {
            #expect(absent.isDisjoint(with: configuration.extraCommandLineSwitches.keys))
            #expect(absent.isDisjoint(with: configuration.disabledFeatures))
            #expect(absent.isDisjoint(with: configuration.chromiumFeatures.disabled))
        }
    }
}
