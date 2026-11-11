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
    /// Disable the Chromium sandbox (the default). Setting `false` enables
    /// the macOS sandbox end-to-end: helper processes load
    /// `libcef_sandbox.dylib` and seal themselves before any Chromium code
    /// runs. Sandboxed operation requires a properly signed bundle — see
    /// `docs/sandbox.md` before flipping this.
    public var noSandbox: Bool = true

    /// Root directory for all CEF profile data. Defaults to
    /// `~/Library/Application Support/<bundle id>/CefSwift`.
    public var rootCachePath: URL?

    /// Global cache (profile) directory. Must be ``rootCachePath`` itself or
    /// a child of it. Defaults to ``rootCachePath``.
    public var cachePath: URL?

    /// UI locale, e.g. `"en-US"`. Defaults to the system locale.
    public var locale: String?

    /// Product portion of the User-Agent string, e.g. `"MyApp/1.0"`.
    public var userAgentProduct: String?

    /// Log verbosity for CEF's log file.
    public var logSeverity: CefLogSeverity = .default

    /// Log file location. Defaults to `debug.log` in the app's data dir.
    public var logFile: URL?

    /// Enables remote DevTools debugging on the given localhost port.
    public var remoteDebuggingPort: Int?

    /// Persist session cookies across runs.
    public var persistSessionCookies: Bool = false

    /// Default runtime style for browsers created without an explicit style.
    public var defaultRuntimeStyle: CefRuntimeStyle = .default

    /// Drive CEF's message loop from the host run loop (required on macOS
    /// when SwiftUI/AppKit owns the run loop). Leave `true`.
    public var externalMessagePump: Bool = true

    /// Enable Chromium offscreen (windowless) rendering process-wide. Required
    /// for the OSR hosting mode, where CEF paints into a shared `IOSurface`
    /// that CefSwift composites in a Metal/`CALayer`-backed SwiftUI view rather
    /// than a CEF-owned window. Has no effect on windowed or chrome-window
    /// browsers. Note: windowless rendering always uses Alloy style — the
    /// Chrome runtime (chrome:// internals, extensions) is unavailable in this
    /// mode (a CEF/Chromium constraint on macOS).
    public var windowlessRenderingEnabled: Bool = false

    /// Explicit path to `Chromium Embedded Framework.framework`. When `nil`
    /// the framework is resolved from the app bundle's Frameworks directory,
    /// then from the `CEF_FRAMEWORK_PATH` environment variable.
    public var frameworkDirectory: URL?

    /// Explicit helper executable path (rarely needed; CEF derives the
    /// helper apps from the bundle layout by default).
    public var browserSubprocessPath: URL?

    /// How Chromium encrypts cookies at rest — i.e. whether it creates the
    /// "Chromium Safe Storage" keychain item (and triggers the one-time
    /// macOS keychain ACL prompt). See ``CefSafeStoragePolicy``.
    ///
    /// The default, ``CefSafeStoragePolicy/automatic``, uses a mock key for
    /// ad-hoc-signed/unsigned dev builds (no prompt) and the real keychain
    /// for properly signed builds (Chrome-like; "Always Allow" sticks).
    public var safeStorage: CefSafeStoragePolicy = .automatic

    /// Custom URL schemes registered in every CEF process (browser, renderer,
    /// GPU, …). Declare schemes here, then serve them with
    /// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
    public var customSchemes: [CefCustomScheme] = []

    /// The complete User-Agent string. `nil` keeps Chromium's, optionally
    /// with ``userAgentProduct`` substituted.
    public var userAgent: String?

    /// Preferred languages for `Accept-Language`, most preferred first,
    /// e.g. `["en-US", "en"]`. Empty uses the system's.
    public var acceptLanguages: [String] = []

    /// Unpacked extension directories (each containing a `manifest.json`)
    /// to load at startup. Extensions run in Chrome-style browsers
    /// (``CefBrowserWindow``); more can be installed at runtime from
    /// `chrome://extensions` or the Chrome Web Store.
    public var extensions: [URL] = []

    /// Chromium features to switch on (`--enable-features`), by name.
    public var enabledFeatures: Set<String> = []

    /// Chromium features to switch off (`--disable-features`), by name.
    public var disabledFeatures: Set<String> = []

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
    /// general-purpose browser needs: background networking, component
    /// updates, sync, translation, default-browser checks and first-run UI.
    /// Fewer background tasks, fewer network requests, lower idle cost.
    public static var embedded: CefConfiguration {
        var configuration = CefConfiguration()
        for name in [
            "disable-background-networking", "disable-component-update", "disable-sync",
            "disable-default-apps", "disable-domain-reliability", "disable-client-side-phishing-detection",
            "no-first-run", "no-default-browser-check", "no-pings", "disable-breakpad",
        ] {
            configuration.extraCommandLineSwitches[name] = .some(nil)
        }
        configuration.disabledFeatures = [
            "Translate", "MediaRouter", "OptimizationHints", "AutofillServerCommunication",
            "InterestFeedContentSuggestions", "CalculateNativeWinOcclusion",
        ]
        return configuration
    }

    /// A configuration for building a full web browser: persistent session
    /// state, and none of Chromium's first-run or default-browser prompts.
    /// Everything else — extensions, internal pages, sync-free profiles —
    /// stays on.
    public static var browser: CefConfiguration {
        var configuration = CefConfiguration()
        configuration.persistSessionCookies = true
        configuration.extraCommandLineSwitches["no-first-run"] = .some(nil)
        configuration.extraCommandLineSwitches["no-default-browser-check"] = .some(nil)
        return configuration
    }
}
