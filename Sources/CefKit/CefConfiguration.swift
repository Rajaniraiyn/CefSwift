import CCef
import Foundation

/// Per-window runtime style. Chrome style provides the full Chrome UI
/// surface (tabs, chrome:// pages, extensions); Alloy style is the classic
/// minimal embedded surface. Note that CEF always uses Alloy style for
/// browsers embedded via a parent NSView.
public enum CefRuntimeStyle: Sendable {
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
    /// CefSwift forwards the list to helper processes automatically via a
    /// `--cefswift-schemes` command-line switch. The reserved `cefswift`
    /// bridge scheme (see ``CefBridge``) is always appended.
    public var customSchemes: [CefCustomScheme] = []

    /// Extra Chromium command-line switches applied to the browser process,
    /// e.g. `["disable-gpu": nil, "proxy-server": "socks5://localhost:1080"]`.
    public var extraCommandLineSwitches: [String: String?] = [:]

    /// Last-chance hook to inspect/modify the command line of every CEF
    /// process before it is processed. Called on the thread CEF invokes it
    /// on (the main thread for the browser process).
    public var onBeforeCommandLineProcessing: (@Sendable (CefCommandLine) -> Void)?

    public init() {}

    /// The default configuration.
    public static let `default` = CefConfiguration()
}
