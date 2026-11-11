import AppKit
import CCef
import Foundation

/// A browsing profile: its own cookies, storage, cache, preferences,
/// extensions and theme. Browsers sharing a profile share all of it.
///
/// ```swift
/// var options = CefBrowserOptions()
/// options.profile = .persistent(name: "Work")
/// ```
///
/// Use profiles after ``CefRuntime/initialize(configuration:)``.
@MainActor
public final class CefProfile {
    enum Kind: Equatable {
        case global
        case incognito
        case persistent(name: String)
    }

    let kind: Kind
    private var context: CefRef<cef_request_context_t>?

    private init(kind: Kind) {
        self.kind = kind
    }

    /// The default profile, stored at ``CefConfiguration/cacheDirectory``.
    public static let `default` = CefProfile(kind: .global)

    /// A fresh in-memory profile; nothing is written to disk and everything
    /// is discarded with the profile.
    public static func incognito() -> CefProfile {
        CefProfile(kind: .incognito)
    }

    /// The on-disk profile called `name`, stored under
    /// `<rootCacheDirectory>/Profiles/<name>`. The same name always yields the
    /// same profile.
    public static func persistent(name: String) -> CefProfile {
        if let existing = persistentProfiles[name] { return existing }
        let profile = CefProfile(kind: .persistent(name: name))
        persistentProfiles[name] = profile
        return profile
    }

    private static var persistentProfiles: [String: CefProfile] = [:]

    // MARK: Bookmarks, history, autocomplete
    // Built on Chromium's internal pages; see CefBookmarks.swift,
    // CefHistory.swift and CefAutocomplete.swift.

    /// The profile's bookmarks.
    public private(set) lazy var bookmarks = CefBookmarks(profile: self)

    /// The profile's browsing history and most-visited sites.
    public private(set) lazy var history = CefHistory(profile: self)

    /// Omnibox-ranked address-bar suggestions. Experimental.
    public private(set) lazy var autocomplete = CefAutocomplete(profile: self)

    // MARK: Preferences

    /// Reads a Chromium preference — the settings behind `chrome://settings`
    /// — by its dotted name, e.g. `"browser.show_home_button"`. `nil` when no
    /// such preference exists.
    public func preference(_ name: String) -> CefJSON? {
        withPreferences { manager in
            CefStringUtil.withCefString(name) { cefName -> CefJSON? in
                guard manager.pointee.has_preference(manager, cefName) != 0 else { return nil }
                let value = manager.pointee.get_preference(manager, cefName)
                defer { cefRelease(value) }
                return CefJSON(cefValue: value)
            }
        } ?? nil
    }

    /// Changes a Chromium preference. Pass `nil` to restore its default.
    ///
    /// ```swift
    /// try profile.setPreference("credentials_enable_service", to: false)   // no password manager
    /// try profile.setPreference("download.default_directory", to: .string(folder.path))
    /// ```
    ///
    /// Throws if the preference is unknown, managed by policy, or `value`
    /// has the wrong type.
    public func setPreference(_ name: String, to value: CefJSON?) throws(CefError) {
        let failure: String? = withPreferences { manager in
            CefStringUtil.withCefString(name) { cefName -> String? in
                var error = cef_string_t()
                defer { cef_string_utf16_clear(&error) }
                guard manager.pointee.set_preference(manager, cefName, value?.makeCefValue(), &error) == 0 else { return nil }
                return CefStringUtil.string(from: error)
            }
        } ?? "the profile is unavailable"
        if let failure {
            throw CefError.operationFailed("Cannot set preference '\(name)': \(failure)")
        }
    }

    /// Every preference in the profile, as one JSON object.
    public func allPreferences(includingDefaults: Bool = true) -> CefJSON {
        withPreferences { manager in
            let dictionary = manager.pointee.get_all_preferences(manager, includingDefaults ? 1 : 0)
            defer { cefRelease(dictionary) }
            return CefJSON.object(CefJSON.members(of: dictionary))
        } ?? .object([:])
    }

    // MARK: Appearance

    /// The color scheme Chrome's UI and `prefers-color-scheme` follow.
    public enum ColorScheme: Sendable {
        case system, light, dark
    }

    /// Themes Chrome-style UI for this profile: light/dark and an optional
    /// accent color from which Chrome derives its whole palette.
    public func setColorScheme(_ scheme: ColorScheme, accentColor: NSColor? = nil) {
        guard let context = requestContext() else { return }
        let variant: cef_color_variant_t =
            switch scheme {
            case .system: CEF_COLOR_VARIANT_SYSTEM
            case .light: CEF_COLOR_VARIANT_LIGHT
            case .dark: CEF_COLOR_VARIANT_DARK
            }
        context.pointer.pointee.set_chrome_color_scheme(
            context.pointer, variant, accentColor.map { cefColor($0.cgColor) } ?? 0)
    }

    // MARK: Cookies

    /// Cookies visible to `url` (including HTTP-only ones), or every cookie
    /// in the profile when `url` is nil.
    public func cookies(for url: URL? = nil) async -> [HTTPCookie] {
        guard let manager = cookieManager() else { return [] }
        return await withCheckedContinuation { continuation in
            let visitor = CookieCollector(continuation: continuation).makeVisitor()
            // The collector reports when CEF drops the visitor, which also
            // covers "no cookies" and "could not start".
            if let url {
                CefStringUtil.withCefString(url.absoluteString) {
                    _ = manager.pointer.pointee.visit_url_cookies(manager.pointer, $0, 1, visitor)
                }
            } else {
                _ = manager.pointer.pointee.visit_all_cookies(manager.pointer, visitor)
            }
        }
    }

    /// Stores `cookie`. Returns whether Chromium accepted it.
    @discardableResult
    public func setCookie(_ cookie: HTTPCookie) -> Bool {
        guard let manager = cookieManager() else { return false }
        var raw = cef_cookie_t()
        raw.size = MemoryLayout<cef_cookie_t>.stride
        CefStringUtil.set(cookie.name, into: &raw.name)
        CefStringUtil.set(cookie.value, into: &raw.value)
        CefStringUtil.set(cookie.domain, into: &raw.domain)
        CefStringUtil.set(cookie.path, into: &raw.path)
        defer {
            ccef_string_clear(&raw.name)
            ccef_string_clear(&raw.value)
            ccef_string_clear(&raw.domain)
            ccef_string_clear(&raw.path)
        }
        raw.secure = cookie.isSecure ? 1 : 0
        raw.httponly = cookie.isHTTPOnly ? 1 : 0
        if let expires = cookie.expiresDate {
            raw.has_expires = 1
            raw.expires = cef_basetime_t(date: expires)
        }
        let scheme = cookie.isSecure ? "https" : "http"
        let host = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return CefStringUtil.withCefString("\(scheme)://\(host)\(cookie.path)") {
            manager.pointer.pointee.set_cookie(manager.pointer, $0, &raw, nil) != 0
        }
    }

    /// Deletes cookies: the one called `name` for `url`, all cookies for
    /// `url`, or — with both nil — every cookie in the profile.
    public func deleteCookies(for url: URL? = nil, named name: String? = nil) {
        guard let manager = cookieManager() else { return }
        CefStringUtil.withCefString(url?.absoluteString ?? "") { cefURL in
            CefStringUtil.withCefString(name ?? "") { cefName in
                _ = manager.pointer.pointee.delete_cookies(
                    manager.pointer, url == nil ? nil : cefURL, name == nil ? nil : cefName, nil)
            }
        }
    }

    // MARK: Request context

    /// The profile's `cef_request_context_t`, created on first use.
    private func requestContext() -> CefRef<cef_request_context_t>? {
        if let context { return context }
        guard CefRuntime.shared.isInitialized else { return nil }
        let preferences = CefRuntime.shared.configuration?.preferences ?? [:]
        switch kind {
        case .global:
            context = CefRef(adopting: cef_request_context_get_global_context())
            applyConfigured(preferences)
        case .incognito, .persistent:
            var settings = cef_request_context_settings_t()
            settings.size = MemoryLayout<cef_request_context_settings_t>.stride
            let configuration = CefRuntime.shared.configuration
            let root = configuration?.rootCacheDirectory ?? MappedCefSettings.defaultRootCacheDirectory()
            // An empty cache_path means in-memory, which is what incognito wants.
            if let path = Self.cacheDirectory(for: kind, rootCacheDirectory: root) {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                CefStringUtil.set(path.path, into: &settings.cache_path)
                settings.persist_session_cookies = configuration?.persistsSessionCookies == true ? 1 : 0
            }
            defer { ccef_string_clear(&settings.cache_path) }
            // A new context finishes initializing asynchronously; its
            // preferences can only be set once it reports ready.
            let handler = preferences.isEmpty
                ? nil
                : ContextHandler { [weak self] in self?.applyConfigured(preferences) }.makeHandler()
            context = CefRef(adopting: cef_request_context_create_context(&settings, handler))
        }
        return context
    }

    private func applyConfigured(_ preferences: [String: CefJSON]) {
        for (name, value) in preferences {
            do {
                try setPreference(name, to: value)
            } catch {
                CefLog.error("\(error)")
            }
        }
    }

    /// A +1 request context for browser creation, which consumes it.
    func makeRequestContext() -> UnsafeMutablePointer<cef_request_context_t>? {
        cefRetained(requestContext()?.pointer)
    }

    private func cookieManager() -> CefRef<cef_cookie_manager_t>? {
        guard let context = requestContext() else { return nil }
        return CefRef(adopting: context.pointer.pointee.get_cookie_manager(context.pointer, nil))
    }

    /// `cef_request_context_t` extends `cef_preference_manager_t`, so the
    /// context pointer is also the profile's preference manager.
    private func withPreferences<R>(_ body: (UnsafeMutablePointer<cef_preference_manager_t>) -> R) -> R? {
        guard let context = requestContext() else { return nil }
        return context.pointer.withMemoryRebound(to: cef_preference_manager_t.self, capacity: 1, body)
    }

    // MARK: Storage layout

    /// Where a profile kind lives on disk; nil for in-memory and the default
    /// profile.
    static func cacheDirectory(for kind: Kind, rootCacheDirectory: URL?) -> URL? {
        guard case .persistent(let name) = kind else { return nil }
        return rootCacheDirectory?
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(sanitize(name), isDirectory: true)
    }

    /// Makes a profile name safe to use as a directory name.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let trimmed = cleaned.drop(while: { $0 == "." })
        return trimmed.isEmpty ? "Profile" : String(trimmed)
    }
}

// MARK: - Context readiness

/// Owner of a `cef_request_context_handler_t` that reports when a new
/// context is ready. The callback arrives on the UI thread.
private final class ContextHandler: @unchecked Sendable {
    private let onInitialized: @MainActor () -> Void

    init(onInitialized: @escaping @MainActor () -> Void) {
        self.onInitialized = onInitialized
    }

    func makeHandler() -> UnsafeMutablePointer<cef_request_context_handler_t> {
        let handler = cefAllocate(cef_request_context_handler_t.self, owner: self)
        handler.pointee.on_request_context_initialized = { s, context in
            cefRelease(context)
            guard let owner = cefOwner(ContextHandler.self, s) else { return }
            MainActor.assumeIsolated { owner.onInitialized() }
        }
        return handler
    }
}

// MARK: - Cookie plumbing

/// Collects visited cookies and delivers them when CEF releases the visitor.
private final class CookieCollector: @unchecked Sendable {
    private let continuation: CheckedContinuation<[HTTPCookie], Never>
    private var cookies: [HTTPCookie] = []

    init(continuation: CheckedContinuation<[HTTPCookie], Never>) {
        self.continuation = continuation
    }

    deinit {
        continuation.resume(returning: cookies)
    }

    /// The returned +1 reference is consumed by the `visit_*_cookies` call.
    func makeVisitor() -> UnsafeMutablePointer<cef_cookie_visitor_t> {
        let visitor = cefAllocate(cef_cookie_visitor_t.self, owner: self)
        visitor.pointee.visit = { s, cookie, _, _, _ in
            guard let cookie, let owner = cefOwner(CookieCollector.self, s) else { return 0 }
            if let converted = HTTPCookie(cefCookie: cookie.pointee) {
                owner.cookies.append(converted)
            }
            return 1
        }
        return visitor
    }
}

extension HTTPCookie {
    fileprivate convenience init?(cefCookie cookie: cef_cookie_t) {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: CefStringUtil.string(from: cookie.name),
            .value: CefStringUtil.string(from: cookie.value),
            .domain: CefStringUtil.string(from: cookie.domain),
            .path: CefStringUtil.string(from: cookie.path),
        ]
        if cookie.secure != 0 { properties[.secure] = "TRUE" }
        if cookie.httponly != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if cookie.has_expires != 0 { properties[.expires] = cookie.expires.date }
        self.init(properties: properties)
    }
}

extension cef_basetime_t {
    /// Seconds between the Windows epoch (1601) Chromium counts from and the
    /// Unix epoch.
    private static let unixEpochOffset: TimeInterval = 11_644_473_600

    init(date: Date) {
        self.init(val: Int64((date.timeIntervalSince1970 + Self.unixEpochOffset) * 1_000_000))
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(val) / 1_000_000 - Self.unixEpochOffset)
    }
}
