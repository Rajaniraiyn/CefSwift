import CCef
import Foundation

/// Log severity for CEF's logging subsystem and console messages.
public enum CefLogSeverity: Sendable, Equatable {
    case `default`
    case verbose
    case debug
    case info
    case warning
    case error
    case fatal
    case disabled

    var cefValue: cef_log_severity_t {
        switch self {
        case .default: return LOGSEVERITY_DEFAULT
        case .verbose: return LOGSEVERITY_VERBOSE
        case .debug: return LOGSEVERITY_DEBUG
        case .info: return LOGSEVERITY_INFO
        case .warning: return LOGSEVERITY_WARNING
        case .error: return LOGSEVERITY_ERROR
        case .fatal: return LOGSEVERITY_FATAL
        case .disabled: return LOGSEVERITY_DISABLE
        }
    }

    init(cefValue: cef_log_severity_t) {
        switch cefValue {
        case LOGSEVERITY_VERBOSE: self = .verbose
        case LOGSEVERITY_INFO: self = .info
        case LOGSEVERITY_WARNING: self = .warning
        case LOGSEVERITY_ERROR: self = .error
        case LOGSEVERITY_FATAL: self = .fatal
        case LOGSEVERITY_DISABLE: self = .disabled
        default: self = .default
        }
    }
}

extension CefRuntime {
    /// Configuration for ``CefRuntime/initialize(configuration:)``. Maps onto
    /// `cef_settings_t`; every knob has a sensible default so `.default` works
    /// out of the box for a bundled app.
    public struct Configuration: Sendable {
        /// Whether Chromium's macOS sandbox confines the helper processes
        /// (renderers, GPU, network and other services). On by default, in
        /// every preset: helpers load `libcef_sandbox.dylib` and seal
        /// themselves before any Chromium code runs, as `cef bundle` sets them
        /// up. Turn it off only to debug a helper, or for a bundle `cef bundle`
        /// did not make; see `docs/sandbox.md`.
        public var isSandboxEnabled: Bool = true

        /// Root directory for all CEF profile data. Defaults to
        /// `~/Library/Application Support/<bundle id>/CefSwift`.
        public var rootCacheDirectory: URL?

        /// Global cache (profile) directory. Must be ``rootCacheDirectory`` itself or
        /// a child of it. Defaults to ``rootCacheDirectory``.
        public var cacheDirectory: URL?

        /// The root every profile's data lives under: ``rootCacheDirectory``;
        /// without one, the parent of ``cacheDirectory``; without either, the
        /// default under Application Support. Persistent profiles live in its
        /// `Profiles` directory.
        public var resolvedRootCacheDirectory: URL {
            if let rootCacheDirectory { return rootCacheDirectory }
            if let cacheDirectory { return cacheDirectory.deletingLastPathComponent() }
            return MappedCefSettings.defaultRootCacheDirectory()
        }

        /// The language of Chromium's own interface: the app's
        /// (``CefRuntime/Localization/application``, the default), the user's, or a
        /// fixed one. Resolved at start-up to a locale the bundle has strings
        /// for; ``CefRuntime/locale`` is the result.
        public var localization: CefRuntime.Localization = .application

        /// How the browser names itself to sites: the `User-Agent` header and
        /// `navigator.userAgent`. Chromium's own by default. See
        /// ``CefRuntime/UserAgent`` for what each choice does to client hints.
        public var userAgent: CefRuntime.UserAgent = .chromium

        /// Log verbosity for CEF's log file.
        public var logSeverity: CefLogSeverity = .default

        /// Log file location. Defaults to `debug.log` in the app's data dir.
        public var logFile: URL?

        /// Enables remote DevTools debugging on the given localhost port.
        public var remoteDebuggingPort: Int?

        /// Whether session cookies persist across runs.
        public var persistsSessionCookies: Bool = false

        /// Whether offscreen rendering is available, which
        /// ``CefBrowser/Rendering/offscreen(frameRate:)`` browsers require. Offscreen
        /// browsers always use Alloy style.
        public var isOffscreenRenderingEnabled: Bool = false

        /// Explicit path to `Chromium Embedded Framework.framework`. When `nil`
        /// the framework is resolved from the app bundle's Frameworks directory,
        /// then from the `CEF_FRAMEWORK_PATH` environment variable.
        public var frameworkDirectory: URL?

        /// The helper executable to launch (rarely needed; CEF derives the
        /// helper apps from the bundle layout by default).
        public var helperExecutableURL: URL?

        /// Whether Chromium keeps its encryption key in the keychain. The
        /// default, ``CefRuntime/SafeStoragePolicy/automatic``, uses the keychain only
        /// when the app is signed with a developer identity.
        public var safeStorage: CefRuntime.SafeStoragePolicy = .automatic

        /// Which keychain item holds Chromium's key when ``safeStorage`` uses
        /// the keychain: one of the app's own by default. See
        /// ``CefRuntime/KeychainItem``.
        public var keychainItem: CefRuntime.KeychainItem = .application

        /// Whether Chromium applies enterprise policies (the settings an
        /// administrator manages for Chrome) from a preferences domain. Off by
        /// default. See ``CefRuntime/EnterprisePolicy``.
        public var enterprisePolicy: CefRuntime.EnterprisePolicy = .disabled

        /// Custom URL schemes registered in every CEF process (browser, renderer,
        /// GPU, …). Declare schemes here, then serve them with
        /// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
        public var customSchemes: [CefCustomScheme] = []

        /// The languages pages are offered, most preferred first, e.g.
        /// `["en-US", "fr"]`: the `Accept-Language` header and
        /// `navigator.languages`, for every profile. Empty, the default, uses
        /// the user's preferred languages (`Locale.preferredLanguages`), read at
        /// start-up. Chromium adds each language's base (`fr` after `fr-CA`) to
        /// the header.
        ///
        /// The list applies at every launch and wins over the languages set
        /// in `chrome://settings/languages`. A profile can have a list of its
        /// own: ``CefProfile/acceptLanguages``. Spelling follows the spelling
        /// language of macOS (Keyboard settings, Text Input), as in Chrome on
        /// macOS.
        public var acceptLanguages: [String] = []

        /// Unpacked extension directories (each containing a `manifest.json`)
        /// to load at startup. Extensions run in Chrome-style browsers
        /// (``CefWindow``); more can be installed at runtime from
        /// `chrome://extensions` or the Chrome Web Store.
        public var extensions: [URL] = []

        /// How many helper processes Chromium keeps running, trading memory for
        /// speed and resilience. See ``CefRuntime/ProcessPolicy``.
        public var processPolicy: CefRuntime.ProcessPolicy = .automatic

        /// Chromium features to switch on (`--enable-features`), by name.
        public var enabledFeatures: Set<String> = []

        /// Chromium features to switch off (`--disable-features`), by name.
        public var disabledFeatures: Set<String> = []

        /// Chromium preferences — the settings behind `chrome://settings` — by
        /// dotted name. Each applies to every profile when it is first used, or
        /// to the whole app at start-up for the few Chromium keeps application-wide.
        ///
        /// ```swift
        /// configuration.preferences["credentials_enable_service"] = false   // per profile
        /// configuration.preferences["browser.confirm_to_quit"] = false      // application-wide
        /// ```
        ///
        /// Change them later through ``CefProfile/preferences`` or
        /// ``CefRuntime/preferences``.
        public var preferences: [String: CefJSON] = [:]

        /// Chromium's background services: component updates, protected
        /// media (the Widevine CDM) and translation.
        public var services = Services()

        /// Preloading and DNS over HTTPS.
        public var network = Network()

        /// Third-party cookies and hyperlink auditing.
        public var privacy = Privacy()

        /// HTTPS-First.
        public var security = Security()

        /// Password saving and form autofill.
        public var credentials = Credentials()

        /// Who asks for the credentials a site or proxy wants: the browser
        /// delegate's ``CefBrowserDelegate/browser(_:credentialFor:)`` (by
        /// default a native sheet), or Chromium's own dialog. See
        /// ``CefRuntime/AuthenticationPromptPolicy``.
        public var authenticationPrompt: CefRuntime.AuthenticationPromptPolicy = .delegate

        /// Trims Chrome's toolbar and app menu in Chrome-style windows.
        public var chromeToolbar = ChromeToolbar()

        /// Replacements for Chromium's built-in UI strings — the way to rebrand
        /// settings, About, dialogs and internal pages. See ``productName`` for
        /// the common case.
        public var stringOverrides: [CefRuntime.StringID: String] = [:]

        /// Your product's name, shown wherever Chromium would say "Chromium"
        /// (settings, `chrome://version`, dialogs, the About page).
        public var productName: String? {
            get { stringOverrides[.productName] }
            set {
                stringOverrides[.productName] = newValue
                stringOverrides[.shortProductName] = newValue
            }
        }

        /// Extra Chromium command-line switches for the browser process, e.g.
        /// `["proxy-server": "socks5://localhost:1080", "disable-gpu": nil]`.
        /// The escape hatch for anything Chromium supports that this type
        /// doesn't model.
        public var extraCommandLineSwitches: [String: String?] = [:]

        /// Last-chance hook to edit the browser process command line. Called on
        /// the main thread during initialization.
        public var onBeforeCommandLineProcessing: (@Sendable (CefCommandLine) -> Void)?

        public init() {}

        /// A lean configuration for showing your own web content — an editor, a
        /// preview pane, an app UI. Turns off the parts of Chromium that only a
        /// general-purpose browser needs. Fewer background tasks, fewer network
        /// requests, lower idle cost. Compared with ``init()``:
        ///
        /// - ``processPolicy``: ``CefRuntime/ProcessPolicy/onDemand``; renderer
        ///   processes start only when a page needs one.
        /// - ``Services/protectedMedia``: ``CefRuntime/Configuration/Services/ProtectedMedia/disabled``.
        /// - ``Services/componentUpdates``: ``CefRuntime/Setting/disabled``. Content the
        ///   app chooses needs neither the CDM nor the data files the updater
        ///   keeps current (certificate revocation and Certificate Transparency
        ///   lists, Safe Browsing lists, origin trials), and with the updater
        ///   off none of them, Widevine included, is downloaded. An app that
        ///   shows arbitrary sites should turn it back on.
        /// - ``Services/translation``, ``Network/preloading``,
        ///   ``Privacy/hyperlinkAuditing``, ``Credentials/passwordSaving`` and
        ///   ``Credentials/autofill``: ``CefRuntime/Setting/disabled``.
        /// - Switches (``extraCommandLineSwitches``):
        ///   `disable-background-networking` turns off several subsystems that
        ///   make requests in the background (Chromium made it for network
        ///   measurements; it does not cover every request Chromium makes on
        ///   its own); `disable-sync` and `disable-default-apps`: no Chrome
        ///   Sync, and no default apps installed on first run;
        ///   `disable-domain-reliability`: no network error reports to Google;
        ///   `no-first-run` and `no-default-browser-check`: no first-run or
        ///   default-browser prompts.
        /// - ``disabledFeatures``: `MediaRouter` (Cast discovery on the local
        ///   network), `OptimizationHints` (hints fetched from Google for page
        ///   loads) and `AutofillServerCommunication` (form field predictions
        ///   from Google).
        ///
        /// Everything else is as in ``init()``: ``persistsSessionCookies`` is
        /// off, offscreen rendering is off, and the sandbox is on.
        ///
        /// Set ``Services/protectedMedia`` to ``CefRuntime/Configuration/Services/ProtectedMedia/automatic`` to play
        /// protected media; it turns the component updater back on.
        public static var embedded: CefRuntime.Configuration {
            var configuration = CefRuntime.Configuration()
            configuration.processPolicy = .onDemand
            configuration.services.protectedMedia = .disabled
            configuration.services.componentUpdates = .disabled
            configuration.services.translation = .disabled
            configuration.network.preloading = .disabled
            configuration.privacy.hyperlinkAuditing = .disabled
            configuration.credentials.passwordSaving = .disabled
            configuration.credentials.autofill = .disabled
            for name in [
                "disable-background-networking", "disable-sync", "disable-default-apps", "disable-domain-reliability",
                "no-first-run", "no-default-browser-check",
            ] {
                configuration.extraCommandLineSwitches[name] = .some(nil)
            }
            configuration.disabledFeatures = ["MediaRouter", "OptimizationHints", "AutofillServerCommunication"]
            return configuration
        }

        /// Chromium's services as Chrome runs them, with Chrome's session
        /// behavior: what an app that shows arbitrary sites, with Chrome's
        /// internal pages and settings, starts from. Compared with ``init()``:
        ///
        /// - ``persistsSessionCookies``: on, so session cookies survive a
        ///   relaunch as they do when Chrome restores a session.
        /// - Switches (``extraCommandLineSwitches``): `no-first-run` and
        ///   `no-default-browser-check`, so Chromium shows neither its
        ///   first-run nor its default-browser prompt.
        ///
        /// Everything else is as in ``init()``, which is as Chromium has it
        /// and as users set it in `chrome://settings`:
        /// ``processPolicy`` ``CefRuntime/ProcessPolicy/automatic`` (a spare
        /// renderer is kept running); component updates, Widevine
        /// (``CefRuntime/Configuration/Services/ProtectedMedia/automatic``) and
        /// translation on; background networking and Chrome's default features
        /// on; preloading, third-party cookies, hyperlink auditing, HTTPS-First,
        /// DNS over HTTPS, the password manager and autofill as Chromium decides;
        /// extensions and internal pages available to Chrome-style browsers;
        /// offscreen rendering off; the sandbox on.
        public static var chrome: CefRuntime.Configuration {
            var configuration = CefRuntime.Configuration()
            configuration.persistsSessionCookies = true
            configuration.extraCommandLineSwitches["no-first-run"] = .some(nil)
            configuration.extraCommandLineSwitches["no-default-browser-check"] = .some(nil)
            return configuration
        }
    }
}
