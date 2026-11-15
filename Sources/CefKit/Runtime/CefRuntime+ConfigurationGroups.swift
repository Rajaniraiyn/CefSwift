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

        /// Whether Chromium fetches Google's Widevine CDM, so pages can play
        /// protected (DRM) media. ``ProtectedMedia/automatic`` by default;
        /// ``CefRuntime/Configuration/embedded`` turns it off. See
        /// ``ProtectedMedia``.
        public var protectedMedia: ProtectedMedia = .automatic

        /// Whether Chromium shows pages' notifications through macOS's
        /// notification center, as banners and alerts of the app and of
        /// its `Helper (Alerts)`, rather than in notification popups it
        /// draws in the app itself.
        ///
        /// ``CefRuntime/Setting/disabled`` by default, in every preset:
        /// Chromium sets up system notifications for each profile as it
        /// loads it, before any page shows one, and that asks macOS for
        /// the app's and the Alerts helper's notification authorization,
        /// which macOS shows the user as two permission banners at the
        /// first launch. Off (the `SystemNotifications` feature disabled),
        /// neither process touches the notification center and the Alerts
        /// helper never starts; a page that asks for and is given the
        /// notifications permission still shows its notifications, in
        /// Chromium's own popups.
        ///
        /// ``CefRuntime/Setting/automatic`` is Chromium's choice: system
        /// notifications, with the authorization request at every launch,
        /// whether or not a page notifies. Listing `SystemNotifications`
        /// in ``CefRuntime/Configuration/enabledFeatures`` does the same.
        public var systemNotifications: CefRuntime.Setting = .disabled

        public init() {}
    }

    /// How Chromium resolves host names, for the whole app.
    public struct Network: Sendable, Equatable {
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

        public var secureDNS: SecureDNS = .automatic

        public init() {}
    }

    /// What pages can tell about the user, for the whole app. Third-party
    /// cookies are a profile's: ``CefProfile/Configuration/Privacy``.
    public struct Privacy: Sendable, Equatable {
        /// The pings `<a ping>` links send when followed (hyperlink
        /// auditing). ``CefRuntime/Setting/disabled`` passes `--no-pings` for the
        /// whole app. Pages can still send requests of their own.
        public var hyperlinkAuditing: CefRuntime.Setting = .automatic

        public init() {}
    }

    /// Whether Chromium's component updater runs: when component updates
    /// are on, or protected media needs the Widevine CDM.
    var runsComponentUpdater: Bool {
        services.componentUpdates == .automatic || services.protectedMedia != .disabled
    }

    /// The application-wide preferences the typed options set, by name;
    /// ``preferences`` wins over them. A profile's are its
    /// ``CefProfile/configuration``'s.
    var policyPreferences: [String: CefJSON] {
        var preferences: [String: CefJSON] = [:]
        switch network.secureDNS {
        case .automatic: break
        case .disabled:
            preferences["dns_over_https.mode"] = "off"
        case .secure(let templates):
            preferences["dns_over_https.mode"] = "secure"
            preferences["dns_over_https.templates"] = .string(templates.joined(separator: " "))
        }
        return preferences
    }

    /// The application-wide preferences Chromium gets: the typed options',
    /// then ``preferences``.
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
