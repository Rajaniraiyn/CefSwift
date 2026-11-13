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

    /// The download policy and the downloads; see `CefProfile+Downloads.swift`.
    let downloadStore = CefDownloadStore()

    /// Whether the profile is in memory only, made by ``incognito()``.
    public var isIncognito: Bool { kind == .incognito }

    private init(kind: Kind, id: String, displayName: String) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }

    /// The default profile, Chromium's own, stored in the `Default`
    /// directory of ``CefRuntime/Configuration/rootCacheDirectory`` and
    /// loaded as Chromium starts.
    public static let `default` = CefProfile(kind: .global, id: "default", displayName: "Default")

    /// A fresh in-memory profile; nothing is written to disk and everything
    /// is discarded with the profile.
    public static func incognito() -> CefProfile {
        CefProfile(kind: .incognito, id: "incognito-\(UUID().uuidString)", displayName: "Incognito")
    }

    /// The on-disk profile identified by `id`, stored in a directory of its
    /// own, `<rootCacheDirectory>/Profile-<id>`. The same identifier always
    /// yields the same profile, and different identifiers different
    /// storage: characters other than lowercase letters, digits, `-` and
    /// `_` are percent-encoded in the directory name, so `"a/b"`, `"a_b"`,
    /// `"Work"` and `"work"` are four profiles, even on a case-insensitive
    /// volume. `"default"` is ``default``.
    ///
    /// Chromium loads a profile in the background the first time it is
    /// used in a launch. Browsers created meanwhile are created once it is
    /// loaded; await ``ready()`` before reading or changing its
    /// ``preferences`` or site settings. If Chromium cannot load it,
    /// browsers on it close at once and ``ready()`` throws
    /// ``CefError/profileUnavailable(_:)``: nothing falls back to an
    /// in-memory profile.
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

    /// The directory Chromium keeps this profile's files in: `Default` in
    /// the root cache directory for the default profile, the profile's own
    /// for a persistent one; `nil` for an incognito profile and one
    /// Chromium could not load. A new profile's files appear as Chromium
    /// first saves them, some seconds after it loads.
    package var directory: URL? {
        switch kind {
        case .incognito:
            return nil
        case .persistent:
            if case .failed = readiness { return nil }
            return storage.chromiumDirectory
        case .global:
            let root = (CefRuntime.shared.configuration ?? CefRuntime.Configuration()).resolvedRootCacheDirectory
            return root.appendingPathComponent("Default", isDirectory: true)
        }
    }

    // MARK: Appearance

    /// The color scheme Chrome's UI and `prefers-color-scheme` follow.
    public enum ColorScheme: Sendable {
        case system, light, dark
    }

    /// Themes Chrome-style UI for this profile: light/dark and an optional
    /// accent color from which Chrome derives its whole palette. On a
    /// profile Chromium is still loading, it applies once loaded.
    public func setColorScheme(_ scheme: ColorScheme, accentColor: NSColor? = nil) {
        guard let context = loadedRequestContext(orWhenLoaded: { $0.setColorScheme(scheme, accentColor: accentColor) })
        else { return }
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

    /// The profile's `cef_request_context_t`, created on first use; `nil`
    /// before Chromium runs and for a profile Chromium could not load. A
    /// persistent profile's context may still be loading when this
    /// returns (``readiness``).
    func requestContext() -> CefRef<cef_request_context_t>? {
        if case .failed = readiness { return nil }
        if let context { return context }
        guard CefRuntime.shared.isRunning else { return nil }
        switch kind {
        case .global:
            // Chromium loads the default profile as it starts.
            context = CefRef(adopting: cef_request_context_get_global_context())
            readiness = .ready
            applyConfigured()
        case .incognito, .persistent:
            var settings = cef_request_context_settings_t()
            settings.size = MemoryLayout<cef_request_context_settings_t>.stride
            let configuration = CefRuntime.shared.configuration
            // An empty cache_path means in-memory, which is what incognito wants.
            if let path = storage.chromiumDirectory {
                // Chromium makes the directory itself, and makes none where
                // something else is in the way.
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    fail("\(path.path) exists and is not a directory")
                    return nil
                }
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
            // Chromium creates or loads a disk profile asynchronously. An
            // in-memory one it makes within create_context, usable at once,
            // though it reports it later.
            readiness = .loading
            let handler = ContextHandler { [weak self] path in self?.contextDidInitialize(cachePath: path) }.makeHandler()
            let created = CefRef(adopting: cef_request_context_create_context(&settings, handler))
            if case .failed = readiness { return nil }
            context = created
            if kind == .incognito, readiness == .loading {
                readiness = .ready
                applyConfigured()
            }
            // Scheme handlers registered with CefRuntime reach only the
            // global context by themselves.
            Self.profilesWithOwnContext.append(WeakProfile(profile: self))
            for handler in CefRuntime.shared.schemeHandlers { register(handler) }
        }
        return context
    }

    // MARK: Readiness

    /// Where Chromium is with the profile.
    enum Readiness: Equatable {
        /// Not asked for yet: nothing has used the profile, or Chromium is
        /// not running.
        case pending
        /// Chromium is creating or loading it.
        case loading
        /// Loaded, with the storage asked for.
        case ready
        /// Chromium could not give the profile its storage; why.
        case failed(String)
    }

    private(set) var readiness = Readiness.pending
    private let readinessWaiters = CefPendingOperations<Void>()

    /// Suspends until Chromium has loaded the profile, starting to load it
    /// if nothing has used it yet. The default and incognito profiles are
    /// ready at once; Chromium loads a persistent one in the background
    /// the first time it is used in a launch, and creates its directory the
    /// first time ever.
    ///
    /// Browsers wait for their profile by themselves. Await this before
    /// reading or changing a persistent profile's ``preferences`` or site
    /// settings, which Chromium has only once the profile is loaded.
    ///
    /// Throws ``CefError/profileUnavailable(_:)`` when Chromium cannot
    /// load the profile from its directory, ``CefError/notInitialized``
    /// before ``CefRuntime/initialize(configuration:)``, and
    /// `CancellationError` if the calling task is cancelled.
    public func ready() async throws {
        _ = requestContext()
        switch readiness {
        case .ready: return
        case .failed(let reason): throw CefError.profileUnavailable(reason)
        case .pending: throw CefRuntime.shared.state == .stopped ? CefError.shutDown : CefError.notInitialized
        case .loading: try await readinessWaiters.wait()
        }
    }

    /// Whether Chromium has loaded the profile.
    @_spi(Testing) public var isReady: Bool { readiness == .ready }

    /// Chromium reports a context initialized whether or not it could give
    /// it the directory asked for: when it cannot, it logs “Cannot create
    /// profile at path” and gives the context a new in-memory profile
    /// instead. That is caught here, by the directory the context ended up
    /// with, and becomes a failure.
    private func contextDidInitialize(cachePath actual: String) {
        guard readiness == .loading else { return }
        if let expected = storage.chromiumDirectory {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            guard !actual.isEmpty, Self.samePath(actual, expected.path), exists else {
                fail("Chromium did not load it from \(expected.path)"
                     + (actual.isEmpty ? "" : " (its context's directory is \(actual))")
                     + " and would have kept it in memory instead")
                return
            }
        }
        readiness = .ready
        applyConfigured()
        readinessWaiters.completeAll(.success(()))
    }

    /// Marks the profile unusable: no browser is created on it, and its
    /// request context, if Chromium made one, goes.
    private func fail(_ reason: String) {
        CefLog.error("Profile '\(id)' is unavailable: \(reason)")
        readiness = .failed(reason)
        context = nil
        Self.profilesWithOwnContext.removeAll { $0.profile == nil || $0.profile === self }
        readinessWaiters.completeAll(.failure(CefError.profileUnavailable(reason)))
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        func normalized(_ path: String) -> String {
            resolvingLinks(URL(fileURLWithPath: path)).standardizedFileURL.path
        }
        return normalized(a) == normalized(b)
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
        for profile in all {
            profile.context = nil
            if profile.readiness == .loading { profile.readiness = .pending }
            profile.readinessWaiters.completeAll(.failure(CefError.shutDown))
        }
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

    /// Applies the configuration's per-profile preferences, once the
    /// profile is ready. Application-wide ones are CefRuntime's to apply.
    private func applyConfigured() {
        let configured = CefRuntime.shared.configuration?.effectivePreferences ?? [:]
        if !configured.isEmpty { preferences.apply(configured) }
    }

    /// The request context once the profile is loaded. While Chromium is
    /// still loading it, `later` runs once it has, and this is `nil`; it is
    /// `nil` for a profile Chromium could not load, too. For calls Chromium
    /// ignores on a profile it has not loaded.
    func loadedRequestContext(
        orWhenLoaded later: (@MainActor (CefProfile) -> Void)? = nil
    ) -> CefRef<cef_request_context_t>? {
        guard let context = requestContext() else { return nil }
        if readiness == .ready { return context }
        if let later {
            Task { [weak self] in
                guard let self, (try? await self.ready()) != nil else { return }
                later(self)
            }
        }
        return nil
    }

    /// A +1 request context for browser creation, which consumes it.
    func makeRequestContext() -> UnsafeMutablePointer<cef_request_context_t>? {
        cefRetained(requestContext()?.pointer)
    }

    /// The cookie manager, which Chromium has queue calls until the profile
    /// is loaded.
    private func cookieManager() -> CefRef<cef_cookie_manager_t>? {
        guard let context = requestContext() else { return nil }
        return CefRef(adopting: context.pointer.pointee.get_cookie_manager(context.pointer, nil))
    }

    /// `cef_request_context_t` extends `cef_preference_manager_t`, so the
    /// context pointer is also the profile's preference manager. `nil`
    /// until the profile is ready: Chromium has no preferences for a
    /// profile it is still loading.
    func withPreferences<R>(_ body: (UnsafeMutablePointer<cef_preference_manager_t>) -> R) -> R? {
        guard let context = loadedRequestContext() else { return nil }
        return context.pointer.withMemoryRebound(to: cef_preference_manager_t.self, capacity: 1, body)
    }

    // MARK: Storage layout

    /// Where a profile keeps its data.
    struct Storage: Equatable {
        /// Chromium's directory for the profile: `nil` for the default
        /// profile, which lives at the configuration's cache directory, and
        /// for an in-memory one.
        var chromiumDirectory: URL?
    }

    /// The one storage layout for a profile kind under `rootCacheDirectory`
    /// (``CefRuntime/Configuration/resolvedRootCacheDirectory``).
    ///
    /// A persistent profile's directory is a direct child of the root
    /// (`root_cache_path`, Chromium's user data directory): Chromium's
    /// profile manager creates profiles nowhere else, and CEF gives a
    /// request context with a `cache_path` anywhere else an in-memory
    /// profile instead.
    static func storage(for kind: Kind, rootCacheDirectory: URL) -> Storage {
        switch kind {
        case .global, .incognito:
            return Storage(chromiumDirectory: nil)
        case .persistent(let id):
            return Storage(
                chromiumDirectory: rootCacheDirectory.appendingPathComponent(directoryName(for: id), isDirectory: true))
        }
    }

    /// The directory name for a persistent profile's identifier:
    /// `Profile-`, then the identifier with lowercase letters, digits, `-`
    /// and `_` as they are and every other UTF-8 byte as `%XX`. The mapping
    /// is injective, also on a case-insensitive volume (no uppercase letter
    /// is kept after the prefix), never yields a separator, and never a
    /// name Chromium uses in the same directory (`Default`, `Local State`,
    /// `Guest Profile`, `System Profile`, `Profile 1`…, none of which
    /// starts with the prefix). A name that would pass 200 characters is
    /// cut and ends in `~` and the identifier's SHA-256, which no other
    /// name contains.
    static func directoryName(for id: String) -> String {
        "Profile-" + encodedName(for: id)
    }

    private static func encodedName(for id: String) -> String {
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
    ///
    /// The root is taken with its symbolic links resolved, as Chromium
    /// takes its user data directory: a profile path through a link
    /// (`/var` for `/private/var`, a linked home folder) is not a child of
    /// it in Chromium's eyes, and would get an in-memory profile.
    var storage: Storage {
        if case .persistent(let id) = kind, let directory = Self.testDirectories[id] {
            return Storage(chromiumDirectory: directory)
        }
        let root = (CefRuntime.shared.configuration ?? CefRuntime.Configuration()).resolvedRootCacheDirectory
        return Self.storage(for: kind, rootCacheDirectory: Self.resolvingLinks(root))
    }

    /// `url` with every symbolic link resolved (`realpath`), unlike
    /// `resolvingSymlinksInPath()`, which keeps `/var` rather than
    /// `/private/var`; `url` itself when it does not exist.
    static func resolvingLinks(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Directories to give persistent profiles instead of their own, by
    /// identifier, to see what Chromium does with one it does not accept.
    @_spi(Testing) public static var testDirectories: [String: URL] = [:]
}

// MARK: - Context readiness

/// Owner of a `cef_request_context_handler_t` that reports when a new
/// context is ready. The callback arrives on the UI thread.
/// It passes on the context's cache path, empty for an in-memory one.
private final class ContextHandler: Sendable {
    private let onInitialized: @MainActor @Sendable (_ cachePath: String) -> Void

    init(onInitialized: @escaping @MainActor @Sendable (_ cachePath: String) -> Void) {
        self.onInitialized = onInitialized
    }

    func makeHandler() -> UnsafeMutablePointer<cef_request_context_handler_t> {
        let handler = cefAllocate(cef_request_context_handler_t.self, owner: self)
        handler.pointee.on_request_context_initialized = { s, context in
            defer { cefRelease(context) }
            guard let context, let owner = cefOwner(ContextHandler.self, s) else { return }
            let path = CefStringUtil.takingUserFree(context.pointee.get_cache_path(context)) ?? ""
            MainActor.assumeIsolated { owner.onInitialized(path) }
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
