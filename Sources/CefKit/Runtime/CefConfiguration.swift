import CCef
import Foundation

/// Per-window runtime style. Chrome style provides the full Chrome UI
/// surface (tabs, chrome:// pages, extensions); Alloy style is the classic
/// minimal embedded surface. Note that CEF always uses Alloy style for
/// browsers embedded via a parent NSView.
public enum CefRuntimeStyle: Sendable, Equatable {
    /// Let CEF pick (currently equivalent to ``chrome``).
    case `default`
    /// Chrome runtime style.
    case chrome
    /// Alloy runtime style.
    case alloy

    var cefValue: cef_runtime_style_t {
        switch self {
        case .default: return CEF_RUNTIME_STYLE_DEFAULT
        case .chrome: return CEF_RUNTIME_STYLE_CHROME
        case .alloy: return CEF_RUNTIME_STYLE_ALLOY
        }
    }
}

/// Log severity for CEF's logging subsystem and console messages.
public enum CefLogSeverity: Sendable, Equatable {
    case `default`
    case verbose
    case debug
    case info
    case warning
    case error
    case fatal
    case disable

    var cefValue: cef_log_severity_t {
        switch self {
        case .default: return LOGSEVERITY_DEFAULT
        case .verbose: return LOGSEVERITY_VERBOSE
        case .debug: return LOGSEVERITY_DEBUG
        case .info: return LOGSEVERITY_INFO
        case .warning: return LOGSEVERITY_WARNING
        case .error: return LOGSEVERITY_ERROR
        case .fatal: return LOGSEVERITY_FATAL
        case .disable: return LOGSEVERITY_DISABLE
        }
    }

    init(cefValue: cef_log_severity_t) {
        switch cefValue {
        case LOGSEVERITY_VERBOSE: self = .verbose
        case LOGSEVERITY_INFO: self = .info
        case LOGSEVERITY_WARNING: self = .warning
        case LOGSEVERITY_ERROR: self = .error
        case LOGSEVERITY_FATAL: self = .fatal
        case LOGSEVERITY_DISABLE: self = .disable
        default: self = .default
        }
    }
}

/// Configuration for ``CefRuntime/initialize(configuration:)``. Maps onto
/// `cef_settings_t`; every knob has a sensible default so `.default` works
/// out of the box for a bundled app.
public struct CefConfiguration: Sendable {
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
    /// (``CefLocalization/application``, the default), the user's, or a
    /// fixed one. Resolved at start-up to a locale the bundle has strings
    /// for; ``CefRuntime/locale`` is the result.
    public var localization: CefLocalization = .application

    /// How the browser names itself to sites: the `User-Agent` header and
    /// `navigator.userAgent`. Chromium's own by default. See
    /// ``CefUserAgent`` for what each choice does to client hints.
    public var userAgent: CefUserAgent = .chromium

    /// Log verbosity for CEF's log file.
    public var logSeverity: CefLogSeverity = .default

    /// Log file location. Defaults to `debug.log` in the app's data dir.
    public var logFile: URL?

    /// Enables remote DevTools debugging on the given localhost port.
    public var remoteDebuggingPort: Int?

    /// Whether session cookies persist across runs.
    public var persistsSessionCookies: Bool = false

    /// Default runtime style for browsers created without an explicit style.
    public var defaultRuntimeStyle: CefRuntimeStyle = .default

    /// Whether offscreen rendering is available, which
    /// ``CefRendering/offscreen(frameRate:)`` browsers require. Offscreen
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
    /// default, ``CefSafeStoragePolicy/automatic``, uses the keychain only
    /// when the app is signed with a developer identity.
    public var safeStorage: CefSafeStoragePolicy = .automatic

    /// Which keychain item holds Chromium's key when ``safeStorage`` uses
    /// the keychain: one of the app's own by default. See
    /// ``CefKeychainItem``.
    public var keychainItem: CefKeychainItem = .application

    /// Whether Chromium applies enterprise policies (the settings an
    /// administrator manages for Chrome) from a preferences domain. Off by
    /// default. See ``CefEnterprisePolicy``.
    public var enterprisePolicy: CefEnterprisePolicy = .disabled

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
    /// (``CefBrowserWindow``); more can be installed at runtime from
    /// `chrome://extensions` or the Chrome Web Store.
    public var extensions: [URL] = []

    /// How many helper processes Chromium keeps running, trading memory for
    /// speed and resilience. See ``CefMemoryPolicy``.
    public var memoryPolicy: CefMemoryPolicy = .standard

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
    /// Change them later with ``CefProfile/setPreference(_:to:)`` or
    /// ``CefRuntime/setPreference(_:to:)``.
    public var preferences: [String: CefJSON] = [:]

    /// Whether Chromium fetches Google's Widevine CDM, so pages can play
    /// protected (DRM) media. ``CefProtectedMedia/automatic`` by default;
    /// ``embedded`` turns it off. See ``CefProtectedMedia``.
    public var protectedMedia: CefProtectedMedia = .automatic

    /// Chromium's background services: component updates and translation.
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
    /// ``CefAuthenticationPrompt``.
    public var authenticationPrompt: CefAuthenticationPrompt = .delegate

    /// Trims Chrome's own UI in Chrome-style windows.
    public var chromeUI = CefChromeUIConfiguration()

    /// Replacements for Chromium's built-in UI strings — the way to rebrand
    /// settings, About, dialogs and internal pages. See ``productName`` for
    /// the common case.
    public var stringOverrides: [CefStringID: String] = [:]

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

    /// The default configuration.
    public static let `default` = CefConfiguration()

    /// A lean configuration for showing your own web content — an editor, a
    /// preview pane, an app UI. Turns off the parts of Chromium that only a
    /// general-purpose browser needs, and starts renderer processes only
    /// when a page needs one (``CefMemoryPolicy/reduced``). Fewer
    /// background tasks, fewer network requests, lower idle cost.
    ///
    /// Typed options:
    /// - ``protectedMedia``: ``CefProtectedMedia/disabled``.
    /// - ``Services/componentUpdates``: ``CefSetting/disabled``. Content the
    ///   app chooses needs neither the CDM nor the data files the updater
    ///   keeps current (certificate revocation and Certificate Transparency
    ///   lists, Safe Browsing lists, origin trials), and with the updater
    ///   off none of them, Widevine included, is downloaded. An app that
    ///   shows arbitrary sites should turn it back on.
    /// - ``Services/translation``, ``Network/preloading``,
    ///   ``Privacy/hyperlinkAuditing``, ``Credentials/passwordSaving`` and
    ///   ``Credentials/autofill``: ``CefSetting/disabled``.
    ///
    /// Switches:
    /// - `disable-background-networking`: turns off several subsystems that
    ///   make requests in the background. Chromium made it for network
    ///   measurements; it does not cover every request Chromium makes on
    ///   its own.
    /// - `disable-sync`, `disable-default-apps`: no Chrome Sync, and no
    ///   default apps installed on first run.
    /// - `disable-domain-reliability`: no network error reports to Google.
    /// - `no-first-run`, `no-default-browser-check`: no first-run or
    ///   default-browser prompts.
    ///
    /// Features turned off: `MediaRouter` (Cast discovery on the local
    /// network), `OptimizationHints` (hints fetched from Google for page
    /// loads) and `AutofillServerCommunication` (form field predictions
    /// from Google).
    ///
    /// Set ``protectedMedia`` to ``CefProtectedMedia/automatic`` to play
    /// protected media; it turns the component updater back on.
    public static var embedded: CefConfiguration {
        var configuration = CefConfiguration()
        configuration.memoryPolicy = .reduced
        configuration.protectedMedia = .disabled
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

    /// A configuration for building a full web browser: persistent session
    /// state (``persistsSessionCookies``), and none of Chromium's first-run
    /// or default-browser prompts (`no-first-run`,
    /// `no-default-browser-check`). Everything else stays as Chromium has
    /// it and as users set it in `chrome://settings`: extensions, internal
    /// pages, component updates and Widevine
    /// (``CefProtectedMedia/automatic``), translation, preloading, cookies,
    /// HTTPS-First, the password manager and autofill.
    public static var browser: CefConfiguration {
        var configuration = CefConfiguration()
        configuration.persistsSessionCookies = true
        configuration.extraCommandLineSwitches["no-first-run"] = .some(nil)
        configuration.extraCommandLineSwitches["no-default-browser-check"] = .some(nil)
        return configuration
    }
}
