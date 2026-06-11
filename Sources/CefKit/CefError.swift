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
    /// `CefRuntime.initialize` was called while already initialized.
    case alreadyInitialized
    /// An operation that requires an initialized runtime was attempted
    /// before `CefRuntime.initialize` succeeded.
    case notInitialized
}

extension CefError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .frameworkNotFound(let detail):
            return """
            Chromium Embedded Framework not found. \(detail)
            Fix: bundle the framework via `swift package cef bundle`, set \
            CefConfiguration.frameworkDirectory, or export CEF_FRAMEWORK_PATH \
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
        case .alreadyInitialized:
            return "CefRuntime.initialize was called twice. Initialize CEF exactly once per process."
        case .notInitialized:
            return "CefRuntime has not been initialized. Call CefRuntime.shared.initialize() first."
        }
    }
}
