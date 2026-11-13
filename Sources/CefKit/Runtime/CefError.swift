/// Errors thrown by CefSwift runtime operations.
public enum CefError: Error {
    /// The Chromium Embedded Framework binary could not be located.
    /// The associated value describes every location that was searched.
    case frameworkNotFound(String)
    /// The framework was found but could not be loaded, or a required
    /// `cef_*` symbol was missing. The associated value is the loader error.
    case loadFailed(String)
    /// The loaded framework's API hash for the pinned `CEF_API_VERSION`
    /// does not match the hash captured from the vendored headers, meaning
    /// the framework binary is not ABI-compatible with this build.
    case apiHashMismatch(expected: String, actual: String)
    /// `cef_initialize` returned failure. The associated value is the result
    /// of `cef_get_exit_code()`.
    case initializationFailed(exitCode: Int32)
    /// Another instance of the app already owns this profile directory.
    /// Chromium has forwarded this launch to it; the right response is to
    /// exit quietly.
    case anotherInstanceRunning
    /// `CefRuntime.initialize` was called while already initialized.
    case alreadyInitialized
    /// `CefRuntime.initialize` was called after Chromium shut down, or
    /// while it shuts down. Chromium starts once per process.
    case shutDown
    /// An operation that requires an initialized runtime was attempted
    /// before `CefRuntime.initialize` succeeded.
    case notInitialized
    /// The browser closed before the operation could complete.
    case browserClosed
    /// The frame an operation targeted was gone: detached from its
    /// renderer, or navigated away.
    case frameDetached
    /// A Chromium operation reported failure. The associated value says which.
    case operationFailed(String)
    /// A wait given a `timeout:` ran out first. Only the wait ends: a
    /// script goes on running, a navigation goes on loading.
    case timedOut
    /// Another main-frame navigation started before the one awaited
    /// finished, and replaced it. See ``CefNavigation``.
    case navigationSuperseded
    /// The page's render process ended while its document was loading.
    case renderProcessTerminated(CefTerminationReason)
}

extension CefError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .frameworkNotFound(let detail):
            return """
            Chromium Embedded Framework not found. \(detail)
            Fix: bundle the framework via `swift package cef bundle`, set \
            CefRuntime.Configuration.frameworkDirectory, or export CEF_FRAMEWORK_PATH \
            to the framework binary for unbundled dev/CI runs.
            """
        case .loadFailed(let message):
            return "Failed to load the Chromium Embedded Framework: \(message)"
        case .apiHashMismatch(let expected, let actual):
            return """
            CEF API hash mismatch (expected \(expected), got \(actual)). The \
            framework binary on disk is not ABI-compatible with the CEF \
            headers this package was built against. Re-run `swift package \
            cef download` so the bundled framework matches the pinned CEF \
            version.
            """
        case .initializationFailed(let exitCode):
            return """
            cef_initialize failed (exit code \(exitCode)). Common causes: the \
            helper bundles are missing or misnamed, the app is not running \
            from a bundle assembled by `swift package cef bundle`, or another \
            instance is using the same root_cache_path.
            """
        case .anotherInstanceRunning:
            return "Another instance of this app is already running with the same profile directory."
        case .alreadyInitialized:
            return "CefRuntime.initialize was called twice. Initialize CEF exactly once per process."
        case .shutDown:
            return "CefRuntime has shut down. Chromium starts once per process; it cannot be initialized again."
        case .notInitialized:
            return "CefRuntime has not been initialized. Call CefRuntime.shared.initialize() first."
        case .browserClosed:
            return "The browser closed before the operation completed."
        case .frameDetached:
            return "The frame was detached before the operation completed."
        case .operationFailed(let detail):
            return detail
        case .timedOut:
            return "The wait timed out."
        case .navigationSuperseded:
            return "Another navigation replaced the one awaited."
        case .renderProcessTerminated(let reason):
            return "The page's render process ended (\(reason)) while it loaded."
        }
    }
}

extension CefError {
    /// Whether the error came before `cef_initialize` ran, so starting
    /// again can still work.
    var isBeforeChromiumStarted: Bool {
        switch self {
        case .frameworkNotFound, .loadFailed, .apiHashMismatch: true
        default: false
        }
    }
}
