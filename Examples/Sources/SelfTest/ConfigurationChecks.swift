import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// The typed configuration options reach Chromium: `.embedded`'s in this
/// instance, the others in a probe started with them changed.
extension SelfTest {
    static let policyDomainKey = "CEFSWIFT_SELFTEST_POLICY_DOMAIN"

    static func configurationChecks() async {
        // CefRuntime.Configuration.embedded.
        // Chromium registers the on-device model manifest outside its
        // component updater's switch; it registers nothing else.
        let components = CefRuntime.shared.registeredComponents
        check("configuration: .embedded registers none of Chromium's regular components (Widevine, CRLSet, …)",
              components.allSatisfy { $0.hasPrefix("Optimization Guide On DeviceModels Manifest") },
              detail: "\(components)")
        if !components.isEmpty { print("NOTE configuration: with component updates off, Chromium registers \(components)") }
        let profile = CefProfile.default
        for (name, expected) in [
            ("translate.enabled", CefJSON.bool(false)), ("net.network_prediction_options", 2),
            ("credentials_enable_service", false), ("credentials_enable_autosignin", false),
            ("autofill.profile_enabled", false), ("autofill.credit_card_enabled", false),
        ] {
            check("configuration: .embedded sets \(name)", profile.preferences.value(named: name) == expected,
                  detail: "\(String(describing: profile.preferences.value(named: name)))")
        }
        check("configuration: no enterprise policy by default",
              profile.preferences.value(named: "browser.show_home_button") == false,
              detail: "\(String(describing: profile.preferences.value(named: "browser.show_home_button")))")
        await hyperlinkAuditingCheck(expectsPing: false, label: "configuration: .embedded sends no hyperlink auditing ping")

        // The others, with a recommended policy in a preferences domain of
        // the probe's own.
        let domain = "dev.rajaniraiyn.cefswift.selftest.policy"
        UserDefaults(suiteName: domain)?.set(true, forKey: "ShowHomeButton")
        defer {
            // Emptying the domain leaves its file behind.
            UserDefaults.standard.removePersistentDomain(forName: domain)
            CFPreferencesAppSynchronize(domain as CFString)
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist")
            try? FileManager.default.removeItem(at: file)
        }
        await runProbe("policies", label: "configuration (probe)", environment: [policyDomainKey: domain])
    }

    /// Follows an `<a ping>` link and reports whether the ping arrived.
    static func hyperlinkAuditingCheck(expectsPing: Bool, label: String) async {
        guard let server = try? await LocalServer.start() else {
            skip(label, because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let browser = CefBrowser(url: URL(string: "http://127.0.0.1:\(server.port)/ping-page")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil({ browser.title == "ping-page" }) else {
            check(label, false, detail: "the page did not load: '\(browser.title)'")
            return
        }
        _ = try? await browser.evaluateJavaScript("document.getElementById('link').click()", userGesture: true)
        let followed = await waitUntil { browser.title == "page" }
        let pinged = await waitUntil(timeout: .seconds(expectsPing ? 5 : 1)) {
            server.requestLines.contains { $0.hasPrefix("POST /ping") }
        }
        check(label, followed && pinged == expectsPing,
              detail: "followed \(followed), pinged \(pinged): \(server.requestLines)")
    }

    // MARK: The probe

    static func configurePoliciesProbe(_ configuration: inout CefRuntime.Configuration) {
        configuration.services.componentUpdates = .automatic
        configuration.privacy.hyperlinkAuditing = .automatic
        configuration.privacy.thirdPartyCookies = .block
        configuration.security.httpsFirst = .strict
        configuration.network.secureDNS = .secure(templates: ["https://dns.example/dns-query{?dns}"])
        if let domain = ProcessInfo.processInfo.environment[policyDomainKey] {
            configuration.enterprisePolicy = .domain(domain)
        }
    }

    static func policiesProbeChecks() async {
        // Chromium registers its components shortly after start-up.
        check("component updates on: Chromium registers its components, while protected media stays .disabled",
              await waitUntil { !CefRuntime.shared.registeredComponents.isEmpty },
              detail: "\(CefRuntime.shared.registeredComponents)")
        check("protected media .disabled: CefSwift does not ask for Widevine",
              await CefRuntime.shared.installWidevine() == .unavailable)
        let profile = CefProfile.default
        check("third-party cookies .block", profile.preferences.value(named: "profile.cookie_controls_mode") == 1,
              detail: "\(String(describing: profile.preferences.value(named: "profile.cookie_controls_mode")))")
        check("HTTPS-First .strict", profile.preferences.value(named: "https_only_mode_enabled") == true,
              detail: "\(String(describing: profile.preferences.value(named: "https_only_mode_enabled")))")
        check("secure DNS .secure, application-wide",
              CefRuntime.shared.preferences.value(named: "dns_over_https.mode") == "secure"
                && CefRuntime.shared.preferences.value(named: "dns_over_https.templates") == "https://dns.example/dns-query{?dns}",
              detail: "\(String(describing: CefRuntime.shared.preferences.value(named: "dns_over_https.mode"))), " +
                  "\(String(describing: CefRuntime.shared.preferences.value(named: "dns_over_https.templates")))")
        check("enterprise policy: a recommended policy in the domain sets the preference",
              profile.preferences.value(named: "browser.show_home_button") == true,
              detail: "\(String(describing: profile.preferences.value(named: "browser.show_home_button")))")
        await hyperlinkAuditingCheck(expectsPing: true, label: "hyperlink auditing .automatic sends the ping")
    }
}
