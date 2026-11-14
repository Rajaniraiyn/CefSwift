import Foundation

extension CefProfile {
    /// Chromium settings a profile applies to itself: what pages can learn
    /// across sites, how strictly it insists on HTTPS, its password manager
    /// and autofill, translation, preloading and its proxy.
    ///
    /// Every profile starts from ``CefRuntime/Configuration/profiles``, and
    /// a profile can override any of it in its own ``CefProfile/configuration``
    /// — an incognito profile that blocks third-party cookies and saves no
    /// passwords, for instance:
    ///
    /// ```swift
    /// let incognito = CefProfile.incognito()
    /// incognito.configuration.privacy.thirdPartyCookies = .block
    /// incognito.configuration.credentials.passwordSaving = .disabled
    /// ```
    ///
    /// Each option sets Chromium preferences of the profile, which the
    /// profile applies as Chromium loads it, and again when its
    /// configuration changes. ``CefRuntime/Configuration/preferences``, set by
    /// name, win over them. What stays process-wide — DNS over HTTPS,
    /// hyperlink auditing, component updates, command-line switches — is in
    /// ``CefRuntime/Configuration``.
    public struct Configuration: Sendable, Equatable {
        /// What pages can learn about the user across sites.
        public struct Privacy: Sendable, Equatable {
            /// Cookies and site data of sites other than the one in the
            /// address bar (third-party cookies): the
            /// `profile.cookie_controls_mode` preference.
            public enum ThirdPartyCookies: Sendable, Equatable {
                /// Chromium's default: allowed, and blocked in incognito
                /// profiles. Users can change it in
                /// `chrome://settings/cookies`.
                case automatic
                /// Blocked, set whenever the profile loads. Sites that
                /// embed sign-in, payment or comment widgets from another
                /// site can break.
                case block
            }

            public var thirdPartyCookies: ThirdPartyCookies = .automatic

            public init() {}
        }

        /// How strictly Chromium insists on HTTPS.
        public struct Security: Sendable, Equatable {
            /// What Chromium does with `http://` addresses: the
            /// `https_first_balanced_mode_enabled` and
            /// `https_only_mode_enabled` preferences.
            public enum HTTPSFirst: Sendable, Equatable {
                /// Chromium's default: navigations are upgraded to HTTPS
                /// where the site supports it and fall back to HTTP
                /// silently. Users can change it in
                /// `chrome://settings/security`.
                case automatic
                /// Upgrades, and a warning before an HTTP page on a site
                /// that usually has HTTPS.
                case balanced
                /// Upgrades, and a warning before every HTTP page. Intranet
                /// and device pages that offer only HTTP show the warning
                /// first.
                case strict
            }

            public var httpsFirst: HTTPSFirst = .automatic

            public init() {}
        }

        /// Chromium's password manager and form autofill.
        public struct Credentials: Sendable, Equatable {
            /// Offering to save passwords, and signing in automatically
            /// with saved ones: the `credentials_enable_service` and
            /// `credentials_enable_autosignin` preferences.
            /// ``CefRuntime/Setting/disabled`` stops new passwords from
            /// being saved; it does not stop Chromium from filling
            /// passwords the profile has already saved.
            public var passwordSaving: CefRuntime.Setting = .automatic

            /// Saving and filling addresses and payment cards: the
            /// `autofill.profile_enabled` and `autofill.credit_card_enabled`
            /// preferences.
            public var autofill: CefRuntime.Setting = .automatic

            public init() {}
        }

        /// How the profile's pages reach the network.
        public struct Network: Sendable, Equatable {
            /// Whether Chromium resolves, connects to and loads pages
            /// before the user opens them: DNS prefetch, preconnect,
            /// prefetch and prerender, from links and the address bar. The
            /// `net.network_prediction_options` preference.
            public enum Preloading: Sendable, Equatable {
                /// Chromium's default (standard preloading), which users
                /// can change in `chrome://settings/performance`.
                case automatic
                /// Standard preloading.
                case standard
                /// Extended preloading: more pages, and some requests
                /// through Google's servers.
                case extended
                /// No preloading. Saves speculative requests; navigations
                /// can take longer.
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

            /// The proxy the profile's requests go through: the profile's
            /// `proxy` preference, which Chromium applies to the profile's
            /// request context as it changes. A proxy for the whole app
            /// can also be given on the command line
            /// (`--proxy-server`, ``CefRuntime/Configuration/extraCommandLineSwitches``),
            /// which then wins over this.
            public enum Proxy: Sendable, Equatable {
                /// Chromium's choice: the system's proxy settings, unless a
                /// command-line switch or the user says otherwise.
                case automatic
                /// The proxy settings of macOS, set whenever the profile
                /// loads.
                case system
                /// No proxy.
                case direct
                /// These proxy servers, in Chromium's proxy rules:
                /// `"proxy.example:8080"`, `"socks5://proxy.example:1080"`,
                /// or per scheme, `"http=a.example:80;https=b.example:443"`.
                /// Hosts in `bypassing` (`"*.internal"`, `"<local>"`) are
                /// reached directly.
                case servers(String, bypassing: [String] = [])
                /// The proxy auto-configuration (PAC) script at this
                /// address.
                case autoConfiguration(URL)

                var preferenceValue: CefJSON? {
                    switch self {
                    case .automatic: return nil
                    case .system: return ["mode": "system"]
                    case .direct: return ["mode": "direct"]
                    case .servers(let rules, let bypass):
                        var value: [String: CefJSON] = ["mode": "fixed_servers", "server": .string(rules)]
                        if !bypass.isEmpty { value["bypass_list"] = .string(bypass.joined(separator: ",")) }
                        return .object(value)
                    case .autoConfiguration(let url):
                        return ["mode": "pac_script", "pac_url": .string(url.absoluteString)]
                    }
                }
            }

            public var preloading: Preloading = .automatic
            public var proxy: Proxy = .automatic

            public init() {}
        }

        /// Third-party cookies.
        public var privacy = Privacy()
        /// HTTPS-First.
        public var security = Security()
        /// Password saving and form autofill.
        public var credentials = Credentials()
        /// Preloading and the proxy.
        public var network = Network()
        /// Chromium's offer to translate pages through Google Translate,
        /// the `translate.enabled` preference. Chrome-style browsers show
        /// the offer.
        public var translation: CefRuntime.Setting = .automatic

        public init() {}

        /// The preferences these options set, by name. Every name an option
        /// controls is present, `nil` for one it leaves to Chromium, so a
        /// change can reset what an earlier configuration set.
        var preferences: [String: CefJSON?] {
            // `CefJSON` is a nil literal itself, so values go in typed.
            var preferences: [String: CefJSON?] = [:]
            func put(_ name: String, _ value: CefJSON?) { preferences.updateValue(value, forKey: name) }
            put("translate.enabled", translation == .disabled ? .bool(false) : nil)
            put("net.network_prediction_options", network.preloading.preferenceValue.map { .number(Double($0)) })
            put("proxy", network.proxy.preferenceValue)
            put("profile.cookie_controls_mode", privacy.thirdPartyCookies == .block ? .number(1) : nil)
            switch security.httpsFirst {
            case .automatic:
                put("https_first_balanced_mode_enabled", nil)
                put("https_only_mode_enabled", nil)
            case .balanced:
                put("https_first_balanced_mode_enabled", .bool(true))
                put("https_only_mode_enabled", .bool(false))
            case .strict:
                put("https_first_balanced_mode_enabled", nil)
                put("https_only_mode_enabled", .bool(true))
            }
            let savesPasswords: CefJSON? = credentials.passwordSaving == .disabled ? .bool(false) : nil
            put("credentials_enable_service", savesPasswords)
            put("credentials_enable_autosignin", savesPasswords)
            let fills: CefJSON? = credentials.autofill == .disabled ? .bool(false) : nil
            put("autofill.profile_enabled", fills)
            put("autofill.credit_card_enabled", fills)
            return preferences
        }

        /// The preferences to set as a profile loads: those the options
        /// set, without the ones they leave to Chromium.
        var setPreferences: [String: CefJSON] {
            preferences.compactMapValues { $0 }
        }
    }

    /// The profile's Chromium settings: ``CefRuntime/Configuration/profiles``
    /// until the app changes any of it here, which overrides it for this
    /// profile alone. A change applies to the profile at once, or as
    /// Chromium loads it.
    ///
    /// ```swift
    /// profile.configuration.network.proxy = .servers("proxy.example:8080")
    /// ```
    public var configuration: Configuration {
        get { ownConfiguration ?? CefRuntime.shared.configuration?.profiles ?? Configuration() }
        set {
            let old = configuration
            ownConfiguration = newValue
            guard readiness == .ready, newValue != old else { return }
            applyConfiguration(newValue.preferences, replacing: old.preferences)
        }
    }

    /// Sets what `new` sets, and resets what `old` set that `new` leaves to
    /// Chromium. ``CefRuntime/Configuration/preferences`` keep winning.
    func applyConfiguration(_ new: [String: CefJSON?], replacing old: [String: CefJSON?]) {
        let named = CefRuntime.shared.configuration?.preferences ?? [:]
        for (name, value) in new where named[name] == nil {
            let previous: CefJSON? = old[name].flatMap { $0 }
            guard value != previous else { continue }
            do {
                try preferences.setValue(value, named: name)
            } catch {
                CefLog.error("Profile '\(id)': could not set \(name): \(error)")
            }
        }
    }
}
