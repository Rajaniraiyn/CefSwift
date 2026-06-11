import CCef
import Foundation

/// Owns a fully-populated `cef_settings_t` whose string members are released
/// on deinit. Kept alive for the duration of `cef_initialize` (CEF copies
/// what it needs).
final class MappedCefSettings {
    var raw = cef_settings_t()

    /// - Parameters:
    ///   - configuration: the user configuration.
    ///   - frameworkDirectory: resolved `.framework` directory (maps to
    ///     `framework_dir_path`), or nil to let CEF use defaults.
    init(configuration: CefConfiguration, frameworkDirectory: URL?) {
        raw.size = MemoryLayout<cef_settings_t>.stride
        raw.no_sandbox = configuration.noSandbox ? 1 : 0
        raw.external_message_pump = configuration.externalMessagePump ? 1 : 0
        raw.multi_threaded_message_loop = 0  // unsupported on macOS
        raw.log_severity = configuration.logSeverity.cefValue
        raw.persist_session_cookies = configuration.persistSessionCookies ? 1 : 0
        raw.remote_debugging_port = Int32(configuration.remoteDebuggingPort ?? 0)
        raw.windowless_rendering_enabled = configuration.windowlessRenderingEnabled ? 1 : 0

        // CEF requires cache_path to equal or live under root_cache_path. When only
        // cachePath is given, derive the root from it so the pair is always valid.
        let rootCache: URL
        if let explicitRoot = configuration.rootCachePath {
            rootCache = explicitRoot
        } else if let cache = configuration.cachePath {
            rootCache = cache.deletingLastPathComponent()
        } else {
            rootCache = Self.defaultRootCachePath()
        }
        try? FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        CefStringUtil.set(rootCache.path, into: &raw.root_cache_path)
        CefStringUtil.set((configuration.cachePath ?? rootCache).path, into: &raw.cache_path)

        CefStringUtil.set(configuration.locale, into: &raw.locale)
        CefStringUtil.set(configuration.userAgentProduct, into: &raw.user_agent_product)
        CefStringUtil.set(configuration.logFile?.path, into: &raw.log_file)
        CefStringUtil.set(frameworkDirectory?.path, into: &raw.framework_dir_path)
        CefStringUtil.set(configuration.browserSubprocessPath?.path, into: &raw.browser_subprocess_path)
    }

    /// Default per-app CEF data directory:
    /// `~/Library/Application Support/<bundle id | "CefSwift">/CefSwift`.
    static func defaultRootCachePath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier
            ?? ProcessInfo.processInfo.processName
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CefSwift", isDirectory: true)
    }

    deinit {
        ccef_string_clear(&raw.root_cache_path)
        ccef_string_clear(&raw.cache_path)
        ccef_string_clear(&raw.locale)
        ccef_string_clear(&raw.user_agent_product)
        ccef_string_clear(&raw.log_file)
        ccef_string_clear(&raw.framework_dir_path)
        ccef_string_clear(&raw.browser_subprocess_path)
    }
}
