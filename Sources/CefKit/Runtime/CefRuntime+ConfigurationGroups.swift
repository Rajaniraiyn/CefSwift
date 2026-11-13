import Foundation

extension CefRuntime {
    /// A Chromium facility the app leaves to Chromium or turns off.
    public enum Setting: Sendable, Equatable {
        /// Chromium's own default, which users can change in
        /// `chrome://settings` where Chromium offers the setting.
        case automatic
        /// Off, set again at every launch.
        case disabled
    }
}

extension CefRuntime.Configuration {
    /// Chromium's background services. Each applies to the whole app and
    /// is read at start-up.
    public struct Services: Sendable, Equatable {
        /// Chromium's component updater, which keeps data files current:
        /// certificate revocation lists (CRLSet), Certificate Transparency
        /// logs, Safe Browsing file-type and SSL error lists, origin trials,
        /// subresource filter rules and the like, and the Widevine CDM.
        ///
        /// ``CefRuntime/Setting/disabled`` turns it off (`--disable-component-update`):
        /// none of these is registered, fetched or loaded. Chromium 156
        /// still fetches one component of its own outside the switch, the
        /// on-device model manifest. Protected media that
        /// needs the CDM (``CefRuntime/Configuration/Services/ProtectedMedia/automatic`` and
        /// ``CefRuntime/Configuration/Services/ProtectedMedia/preinstalled(widevineDirectory:)``) keeps the
        /// updater on regardless, since the CDM arrives through it.
        public var componentUpdates: CefRuntime.Setting = .automatic

        /// Chromium's offer to translate pages through Google Translate,
        /// the `translate.enabled` preference of every profile. Chrome-style
        /// browsers show the offer.
        public var translation: CefRuntime.Setting = .automatic

        /// Whether Chromium fetches Google's Widevine CDM, so pages can play
        /// protected (DRM) media. ``ProtectedMedia/automatic`` by default;
        /// ``CefRuntime/Configuration/embedded`` turns it off. See
        /// ``ProtectedMedia``.
        public var protectedMedia: ProtectedMedia = .automatic

        public init() {}
    }

    /// How Chromium uses the network beyond what pages ask for.
    public struct Network: Sendable, Equatable {
        /// Whether Chromium resolves, connects to and loads pages before
        /// the user opens them: DNS prefetch, preconnect, prefetch and
        /// prerender, from links and the address bar. The
        /// `net.network_prediction_options` preference of every profile.
        public enum Preloading: Sendable, Equatable {
            /// Chromium's default (standard preloading), which users can
            /// change in `chrome://settings/performance`.
            case automatic
            /// Standard preloading, set at every launch.
            case standard
            /// Extended preloading, set at every launch: more pages, and
            /// some requests through Google's servers.
            case extended
            /// No preloading. Saves speculative requests; navigations can
            /// take longer.
            case disabled

            var preferenceValue: Int? {
                switch self {
                case .automatic: return nil
                case .standard: return 0
                case .disabled: return 2
                case .extended: return 3
                }
            }
        }

        /// How Chromium resolves host names: DNS over HTTPS or the system
        /// resolver. The application-wide `dns_over_https.mode` and
        /// `dns_over_https.templates` preferences.
        public enum SecureDNS: Sendable, Equatable {
            /// Chromium's default: the system resolver, upgraded to DNS over
            /// HTTPS when the configured DNS server offers it.
            case automatic
            /// The system resolver only.
            case disabled
            /// DNS over HTTPS through these servers only, by URI template,
            /// e.g. `"https://dns.example/dns-query{?dns}"`. A forced
            /// resolver can bypass a network's split DNS or VPN.
            case secure(templates: [String])
        }

        public var preloading: Preloading = .automatic
        public var secureDNS: SecureDNS = .automatic

        public init() {}
    }

    /// What pages can learn about the user across sites.
    public struct Privacy: Sendable, Equatable {
        /// Cookies and site data of sites other than the one in the address
        /// bar (third-party cookies): the `profile.cookie_controls_mode`
        /// preference of every profile.
        public enum ThirdPartyCookies: Sendable, Equatable {
            /// Chromium's default: allowed, and blocked in incognito
            /// profiles. Users can change it in
            /// `chrome://settings/cookies`.
            case automatic
            /// Blocked in every profile, set at every launch. Sites that
            /// embed sign-in, payment or comment widgets from another site
            /// can break.
            case block
        }

        public var thirdPartyCookies: ThirdPartyCookies = .automatic

        /// The pings `<a ping>` links send when followed (hyperlink
        /// auditing). ``CefRuntime/Setting/disabled`` passes `--no-pings` for the
        /// whole app. Pages can still send requests of their own.
        public var hyperlinkAuditing: CefRuntime.Setting = .automatic

        public init() {}
    }

    /// How strictly Chromium insists on HTTPS.
    public struct Security: Sendable, Equatable {
        /// What Chromium does with `http://` addresses: the
        /// `https_first_balanced_mode_enabled` and `https_only_mode_enabled`
        /// preferences of every profile.
        public enum HTTPSFirst: Sendable, Equatable {
            /// Chromium's default: navigations are upgraded to HTTPS where
            /// the site supports it and fall back to HTTP silently. Users can
            /// change it in `chrome://settings/security`.
            case automatic
            /// Upgrades, and a warning before an HTTP page on a site that
            /// usually has HTTPS.
            case balanced
            /// Upgrades, and a warning before every HTTP page, set at every
            /// launch. Intranet and device pages that offer only HTTP show
            /// the warning first.
            case strict
        }

        public var httpsFirst: HTTPSFirst = .automatic

        public init() {}
    }

    /// Chromium's password manager and form autofill.
    public struct Credentials: Sendable, Equatable {
        /// Offering to save passwords, and signing in automatically with
        /// saved ones: the `credentials_enable_service` and
        /// `credentials_enable_autosignin` preferences of every profile.
        /// ``CefRuntime/Setting/disabled`` stops new passwords from being saved; it
        /// does not stop Chromium from filling passwords the profile has
        /// already saved.
        public var passwordSaving: CefRuntime.Setting = .automatic

        /// Saving and filling addresses and payment cards: the
        /// `autofill.profile_enabled` and `autofill.credit_card_enabled`
        /// preferences of every profile.
        public var autofill: CefRuntime.Setting = .automatic

        public init() {}
    }

    /// Whether Chromium's component updater runs: when component updates
    /// are on, or protected media needs the Widevine CDM.
    var runsComponentUpdater: Bool {
        services.componentUpdates == .automatic || services.protectedMedia != .disabled
    }

    /// The preferences the typed options set, by name; ``preferences``
    /// wins over them.
    var policyPreferences: [String: CefJSON] {
        var preferences: [String: CefJSON] = [:]
        if services.translation == .disabled {
            preferences["translate.enabled"] = false
        }
        if let value = network.preloading.preferenceValue {
            preferences["net.network_prediction_options"] = .number(Double(value))
        }
        switch network.secureDNS {
        case .automatic: break
        case .disabled:
            preferences["dns_over_https.mode"] = "off"
        case .secure(let templates):
            preferences["dns_over_https.mode"] = "secure"
            preferences["dns_over_https.templates"] = .string(templates.joined(separator: " "))
        }
        if privacy.thirdPartyCookies == .block {
            preferences["profile.cookie_controls_mode"] = 1
        }
        switch security.httpsFirst {
        case .automatic: break
        case .balanced:
            preferences["https_first_balanced_mode_enabled"] = true
            preferences["https_only_mode_enabled"] = false
        case .strict:
            preferences["https_only_mode_enabled"] = true
        }
        if credentials.passwordSaving == .disabled {
            preferences["credentials_enable_service"] = false
            preferences["credentials_enable_autosignin"] = false
        }
        if credentials.autofill == .disabled {
            preferences["autofill.profile_enabled"] = false
            preferences["autofill.credit_card_enabled"] = false
        }
        return preferences
    }

    /// The preferences Chromium gets: the typed options', then
    /// ``preferences``.
    var effectivePreferences: [String: CefJSON] {
        policyPreferences.merging(preferences) { $1 }
    }

    /// The switches the typed options add.
    var policySwitches: [String] {
        var switches: [String] = []
        if !runsComponentUpdater { switches.append("disable-component-update") }
        if privacy.hyperlinkAuditing == .disabled { switches.append("no-pings") }
        if authenticationPrompt == .delegate { switches.append(CefRuntime.AuthenticationPromptPolicy.delegateSwitch) }
        return switches
    }
}
