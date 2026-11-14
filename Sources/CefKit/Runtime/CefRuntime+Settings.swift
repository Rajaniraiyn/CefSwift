import AppKit
import CCef
import Foundation
import Observation
import CefBase

// MARK: - Settings mapping

/// Owns a fully-populated `cef_settings_t` whose string members are released
/// on deinit. Kept alive for the duration of `cef_initialize` (CEF copies
/// what it needs).
final class MappedCefSettings {
    var raw = cef_settings_t()

    /// - Parameters:
    ///   - configuration: the user configuration.
    ///   - frameworkDirectory: resolved `.framework` directory (maps to
    ///     `framework_dir_path`), or nil to let CEF use defaults.
    ///   - locale: the Chromium locale to start with (``CefRuntime/Localization``,
    ///     resolved), or nil for CEF's default, `en-US`.
    init(configuration: CefRuntime.Configuration, frameworkDirectory: URL?, locale: String? = nil) {
        raw.size = MemoryLayout<cef_settings_t>.stride
        raw.no_sandbox = configuration.isSandboxEnabled ? 0 : 1
        // Chromium's message loop is driven from the app's run loop
        // (CefMessagePump), the only mode macOS apps support.
        raw.external_message_pump = 1
        raw.multi_threaded_message_loop = 0  // unsupported on macOS
        raw.log_severity = configuration.logSeverity.cefValue
        raw.persist_session_cookies = configuration.persistsSessionCookies ? 1 : 0
        raw.remote_debugging_port = Int32(configuration.remoteDebuggingPort ?? 0)
        raw.windowless_rendering_enabled = configuration.isOffscreenRenderingEnabled ? 1 : 0

        // cache_path equal to root_cache_path puts the default profile in
        // the root's Default directory. Chromium makes profiles only directly
        // in the root: a cache_path elsewhere is ignored for the global
        // context (Default again), and gives a request context an in-memory
        // profile instead (CefProfile.storage(for:rootCacheDirectory:)).
        let rootCache = configuration.resolvedRootCacheDirectory
        try? FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        configuration.services.protectedMedia.installPreinstalledCDM(rootCache: rootCache)
        CefExternalExtensions.write(configuration.extensions, rootCache: rootCache)
        CefStringUtil.set(rootCache.path, into: &raw.root_cache_path)
        CefStringUtil.set(rootCache.path, into: &raw.cache_path)

        CefStringUtil.set(locale, into: &raw.locale)
        CefStringUtil.set(configuration.userAgent.product, into: &raw.user_agent_product)
        CefStringUtil.set(configuration.userAgent.fullString, into: &raw.user_agent)
        let acceptLanguages = configuration.acceptLanguages.isEmpty
            ? CefRuntime.Localization.defaultAcceptLanguages(locale: locale)
            : configuration.acceptLanguages
        CefStringUtil.set(acceptLanguages.joined(separator: ","), into: &raw.accept_language_list)
        CefStringUtil.set(configuration.logFile?.path, into: &raw.log_file)
        CefStringUtil.set(frameworkDirectory?.path, into: &raw.framework_dir_path)
        CefStringUtil.set(configuration.helperExecutableURL?.path, into: &raw.browser_subprocess_path)
        CefStringUtil.set(configuration.enterprisePolicy.domain(bundleIdentifier: Bundle.main.bundleIdentifier),
                          into: &raw.chrome_policy_id)
        if configuration.safeStorage.resolved() == .keychain,
           let item = configuration.keychainItem.names(bundleIdentifier: Bundle.main.bundleIdentifier) {
            CefStringUtil.set(item.service, into: &raw.keychain_service_name)
            CefStringUtil.set(item.account, into: &raw.keychain_account_name)
        }
    }

    /// Default per-app CEF data directory:
    /// `~/Library/Application Support/<bundle id | "CefSwift">/CefSwift`.
    static func defaultRootCacheDirectory() -> URL {
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
        ccef_string_clear(&raw.user_agent)
        ccef_string_clear(&raw.accept_language_list)
        ccef_string_clear(&raw.log_file)
        ccef_string_clear(&raw.framework_dir_path)
        ccef_string_clear(&raw.browser_subprocess_path)
        ccef_string_clear(&raw.chrome_policy_id)
        ccef_string_clear(&raw.keychain_service_name)
        ccef_string_clear(&raw.keychain_account_name)
    }
}
