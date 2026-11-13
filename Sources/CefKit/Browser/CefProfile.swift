import os
import AppKit
import CCef
import Foundation
import CefBase
import CryptoKit

/// A browsing profile: its own cookies, storage, cache, preferences,
/// extensions and theme. Browsers sharing a profile share all of it.
///
/// ```swift
/// var configuration = CefBrowser.Configuration()
/// configuration.profile = .persistent(id: "work", displayName: "Work")
/// ```
///
/// A profile's ``id`` is its identity: it names the profile's storage and
/// never changes. Its ``displayName`` is what to show, and can.
///
/// Use profiles after ``CefRuntime/initialize(configuration:)``.
@MainActor
public final class CefProfile {
    enum Kind: Equatable {
        case global
        case incognito
        case persistent(id: String)
    }

    let kind: Kind
    /// The profile's stable identifier: `"default"` for the default
    /// profile, the identifier given to ``persistent(id:displayName:)``, and
    /// a new `"incognito-<UUID>"` for each incognito profile. Store it to
    /// find the profile again in a later launch.
    public let id: String
    /// The name to show for the profile. Defaults to “Default”,
    /// “Incognito”, or a persistent profile's identifier. Changing it moves
    /// nothing on disk.
    public var displayName: String
    private var context: CefRef<cef_request_context_t>?

    /// The languages this profile's pages are offered (`Accept-Language`,
    /// `navigator.languages`), most preferred first, instead of
    /// ``CefRuntime/Configuration/acceptLanguages``. `nil`, the default, uses the
    /// configuration's.
    ///
    /// Chromium reads it when it creates the profile, before its first
    /// browser; set it before then. The default profile always uses the
    /// configuration's.
    public var acceptLanguages: [String]?

    /// Whether the profile is in memory only, made by ``incognito()``.
    public var isIncognito: Bool { kind == .incognito }

    private init(kind: Kind, id: String, displayName: String) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }

    /// The default profile, stored at ``CefRuntime/Configuration/cacheDirectory``.
    public static let `default` = CefProfile(kind: .global, id: "default", displayName: "Default")

    /// A fresh in-memory profile; nothing is written to disk and everything
    /// is discarded with the profile.
    public static func incognito() -> CefProfile {
        CefProfile(kind: .incognito, id: "incognito-\(UUID().uuidString)", displayName: "Incognito")
    }

    /// The on-disk profile identified by `id`, stored under
    /// `<rootCacheDirectory>/Profiles/`. The same identifier always yields
    /// the same profile, and different identifiers different storage:
    /// characters other than lowercase letters, digits, `-` and `_` are
    /// percent-encoded in the directory name, so `"a/b"`, `"a_b"`,
    /// `"Work"` and `"work"` are four profiles, even on a case-insensitive
    /// volume. `"default"` is ``default``.
    ///
    /// - Parameter displayName: Sets ``displayName``; `nil` keeps the
    ///   profile's current one, which starts as `id`.
    public static func persistent(id: String, displayName: String? = nil) -> CefProfile {
        precondition(!id.isEmpty, "A profile identifier cannot be empty.")
        let profile: CefProfile
        if id == CefProfile.default.id {
            profile = .default
        } else if let existing = persistentProfiles[id] {
            profile = existing
        } else {
            profile = CefProfile(kind: .persistent(id: id), id: id, displayName: id)
            persistentProfiles[id] = profile
        }
        if let displayName { profile.displayName = displayName }
        return profile
    }

    private static var persistentProfiles: [String: CefProfile] = [:]

    // MARK: Module state

    /// What a module built on CefKit keeps for this profile: one object
    /// per type, made by `make` on first use and kept as long as the
    /// profile. Hold the profile weakly from it, or the two keep each
    /// other alive.
    package func moduleState<State: AnyObject>(_ type: State.Type = State.self, make: () -> State) -> State {
        let key = ObjectIdentifier(type)
        if let state = moduleStates[key] as? State { return state }
        let state = make()
        moduleStates[key] = state
        return state
    }

    private var moduleStates: [ObjectIdentifier: AnyObject] = [:]

    // MARK: Internal services

    /// The hidden service hosts on Chromium's WebUI pages: native tab
    /// discarding's here, and those of modules built on CefKit, such as
    /// CefChromium's bookmarks, history and autocomplete.
    package private(set) lazy var serviceHosts = CefServiceHosts(profile: self)

    /// The profile's last browser has closed. Its service hosts close too —
    /// they hold the profile, so an incognito profile and its data could
    /// not go otherwise — and start again on the next call. The default
    /// profile's close when idle.
    func lastBrowserDidClose() {
        guard self !== CefProfile.default else { return }
        serviceHosts.stopAll()
    }

    // MARK: Service hosts, for tests

    /// The names of the service hosts open or opening.
    @_spi(Testing) public var runningServiceHosts: [String] { serviceHosts.runningHostNames }

    /// Closes every service host, as idling does.
    @_spi(Testing) public func stopServiceHosts() { serviceHosts.stopAll() }

    /// Kills the renderer of the running service host called `name`, as a
    /// crash would.
    @_spi(Testing) public func crashServiceHost(named name: String) async {
        await serviceHosts.crashRenderer(ofHostNamed: name)
    }

    /// How long a service host stays open after its last call.
    @_spi(Testing) public static var serviceIdleTimeout: Duration {
        get { CefServiceHosts.idleTimeout }
        set { CefServiceHosts.idleTimeout = newValue }
    }

    /// The directory Chromium keeps this profile's files in; `nil` for an
    /// incognito profile.
    package var directory: URL? {
        guard let context = requestContext(),
              let path = CefStringUtil.takingUserFree(context.pointer.pointee.get_cache_path(context.pointer)),
              !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // The global context's cache path is Chromium's user data directory
        // when it equals the root cache path; its profile is "Default". The
        // paths are compared, not the files: a new profile has no
        // Preferences until Chromium first saves them, seconds after start.
        let root = (CefRuntime.shared.configuration ?? CefRuntime.Configuration()).resolvedRootCacheDirectory
        guard url.resolvingSymlinksInPath().standardizedFileURL.path
                == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { return url }
        return url.appendingPathComponent("Default", isDirectory: true)
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
    func requestContext() -> CefRef<cef_request_context_t>? {
        if let context { return context }
        guard CefRuntime.shared.isRunning else { return nil }
        let preferences = CefRuntime.shared.configuration?.effectivePreferences ?? [:]
        switch kind {
        case .global:
            context = CefRef(adopting: cef_request_context_get_global_context())
            applyConfigured(preferences)
        case .incognito, .persistent:
            var settings = cef_request_context_settings_t()
            settings.size = MemoryLayout<cef_request_context_settings_t>.stride
            let configuration = CefRuntime.shared.configuration
            // An empty cache_path means in-memory, which is what incognito wants.
            if let path = storage.chromiumDirectory {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                CefStringUtil.set(path.path, into: &settings.cache_path)
                settings.persist_session_cookies = configuration?.persistsSessionCookies == true ? 1 : 0
            }
            if let acceptLanguages {
                CefStringUtil.set(acceptLanguages.joined(separator: ","), into: &settings.accept_language_list)
            }
            defer {
                ccef_string_clear(&settings.cache_path)
                ccef_string_clear(&settings.accept_language_list)
            }
            // A new context finishes initializing asynchronously; its
            // preferences can only be set once it reports ready.
            let handler = preferences.isEmpty
                ? nil
                : ContextHandler { [weak self] in self?.applyConfigured(preferences) }.makeHandler()
            context = CefRef(adopting: cef_request_context_create_context(&settings, handler))
            // Scheme handlers registered with CefRuntime reach only the
            // global context by themselves.
            Self.profilesWithOwnContext.append(WeakProfile(profile: self))
            for handler in CefRuntime.shared.schemeHandlers { register(handler) }
        }
        return context
    }

    private struct WeakProfile {
        weak var profile: CefProfile?
    }

    private static var profilesWithOwnContext: [WeakProfile] = []

    /// Every profile that exists: the default, the persistent ones, and
    /// incognito ones with a request context.
    static var all: [CefProfile] {
        var profiles = [CefProfile.default] + persistentProfiles.values
        for entry in profilesWithOwnContext {
            if let profile = entry.profile, !profiles.contains(where: { $0 === profile }) { profiles.append(profile) }
        }
        return profiles
    }

    /// Releases every profile's request context, before Chromium shuts down.
    /// Quitting has drained the requests in flight already (see
    /// `URLRequestRegistry.drainForShutdown()`); this cancels any left by
    /// a drain that gave up.
    static func releaseRequestContexts() {
        URLRequestRegistry.shared.cancelAllForShutdown()
        CefObserverRegistration.releaseAll()
        CefTaskManager.shared.releaseForShutdown()
        for profile in all { profile.context = nil }
        profilesWithOwnContext = []
    }

    /// Adds a scheme handler registered with ``CefRuntime`` to every
    /// profile that has a request context of its own.
    static func registerSchemeHandler(_ handler: CefRuntime.RegisteredSchemeHandler) {
        profilesWithOwnContext.removeAll { $0.profile == nil }
        for entry in profilesWithOwnContext { entry.profile?.register(handler) }
    }

    private func register(_ handler: CefRuntime.RegisteredSchemeHandler) {
        guard let context = context?.pointer, let register = context.pointee.register_scheme_handler_factory else { return }
        // Registration consumes the factory reference.
        let factory = handler.factory.makeFactory()
        let registered = CefStringUtil.withCefString(handler.scheme) { scheme in
            if let domain = handler.domain {
                return CefStringUtil.withCefString(domain) { register(context, scheme, $0, factory) }
            }
            return register(context, scheme, nil, factory)
        }
        if registered == 0 {
            CefLog.error("register_scheme_handler_factory failed for scheme '\(handler.scheme)'")
        }
    }

    private func applyConfigured(_ preferences: [String: CefJSON]) {
        // Application-wide ones are CefRuntime's to apply.
        self.preferences.apply(preferences)
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
    func withPreferences<R>(_ body: (UnsafeMutablePointer<cef_preference_manager_t>) -> R) -> R? {
        guard let context = requestContext() else { return nil }
        return context.pointer.withMemoryRebound(to: cef_preference_manager_t.self, capacity: 1, body)
    }

    // MARK: Storage layout

    /// Where a profile keeps its data.
    package struct Storage: Equatable {
        /// Chromium's directory for the profile: `nil` for the default
        /// profile, which lives at the configuration's cache directory, and
        /// for an in-memory one.
        package var chromiumDirectory: URL?
    }

    /// The one storage layout for a profile kind under `rootCacheDirectory`
    /// (``CefRuntime/Configuration/resolvedRootCacheDirectory``).
    static func storage(for kind: Kind, rootCacheDirectory: URL) -> Storage {
        switch kind {
        case .global, .incognito:
            return Storage(chromiumDirectory: nil)
        case .persistent(let id):
            return Storage(
                chromiumDirectory: rootCacheDirectory
                    .appendingPathComponent("Profiles", isDirectory: true)
                    .appendingPathComponent(directoryName(for: id), isDirectory: true))
        }
    }

    /// The directory name for a persistent profile's identifier: lowercase
    /// letters, digits, `-` and `_` as they are, every other UTF-8 byte as
    /// `%XX`. The mapping is injective, also on a case-insensitive volume
    /// (no uppercase letter is kept), and never yields `.`, `..` or a
    /// separator. A name that would pass 200 characters is cut and ends in
    /// `~` and the identifier's SHA-256, which no other name contains.
    static func directoryName(for id: String) -> String {
        var name = ""
        for byte in id.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                name.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                name += String(format: "%%%02X", byte)
            }
        }
        guard name.count > 200 else { return name }
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(name.prefix(130)) + "~" + digest
    }

    /// This profile's storage under the running configuration's root.
    package var storage: Storage {
        let root = (CefRuntime.shared.configuration ?? CefRuntime.Configuration()).resolvedRootCacheDirectory
        return Self.storage(for: kind, rootCacheDirectory: root)
    }
}

// MARK: - Context readiness

/// Owner of a `cef_request_context_handler_t` that reports when a new
/// context is ready. The callback arrives on the UI thread.
private final class ContextHandler: Sendable {
    private let onInitialized: @MainActor @Sendable () -> Void

    init(onInitialized: @escaping @MainActor @Sendable () -> Void) {
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
private final class CookieCollector: Sendable {
    private let continuation: CheckedContinuation<[HTTPCookie], Never>
    // CEF visits on the UI thread, one cookie at a time.
    private let cookies = OSAllocatedUnfairLock(uncheckedState: [HTTPCookie]())

    init(continuation: CheckedContinuation<[HTTPCookie], Never>) {
        self.continuation = continuation
    }

    deinit {
        continuation.resume(returning: cookies.withLockUnchecked { $0 })
    }

    /// The returned +1 reference is consumed by the `visit_*_cookies` call.
    func makeVisitor() -> UnsafeMutablePointer<cef_cookie_visitor_t> {
        let visitor = cefAllocate(cef_cookie_visitor_t.self, owner: self)
        visitor.pointee.visit = { s, cookie, _, _, _ in
            guard let cookie, let owner = cefOwner(CookieCollector.self, s) else { return 0 }
            if let converted = HTTPCookie(cefCookie: cookie.pointee) {
                owner.cookies.withLockUnchecked { $0.append(converted) }
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

extension CefProfile {
    /// The profile `browser` belongs to, among the profiles made so far;
    /// `nil` for one Chromium made itself, such as its own incognito
    /// profile. Does not consume `browser`.
    static func owning(contextOf browser: UnsafeMutablePointer<cef_browser_t>) -> CefProfile? {
        guard let host = CefRef(adopting: browser.pointee.get_host(browser)),
              let context = CefRef(adopting: host.pointer.pointee.get_request_context(host.pointer))
        else { return nil }
        if context.pointer.pointee.is_global(context.pointer) != 0 { return .default }
        profilesWithOwnContext.removeAll { $0.profile == nil }
        return profilesWithOwnContext.lazy.compactMap(\.profile).first { profile in
            guard let own = profile.context else { return false }
            // Arguments passed into CEF are consumed.
            cefAddRef(own.pointer)
            return context.pointer.pointee.is_sharing_with(context.pointer, own.pointer) != 0
        }
    }
}
