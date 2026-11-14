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
    /// The profile's media router, made on first use; see `CefMediaRouter.swift`.
    var mediaRouterStorage: CefMediaRouter?

    /// The object that decides, for every page of the profile, what its
    /// pages' delegates leave to it: permissions and where downloads go.
    /// See ``CefProfileDelegate``.
    ///
    /// The profile holds its delegate weakly; keep a strong reference to
    /// it elsewhere.
    public weak var delegate: CefProfileDelegate?

    /// The request filter, read on the IO thread; see `CefProfile+Policy.swift`.
    let requestPolicy = CefProfileRequestPolicy()
    /// The scheme handlers registered with this profile alone.
    var schemeHandlers: [CefRuntime.RegisteredSchemeHandler] = []
    /// Page defaults; see `CefProfile+Policy.swift`.
    var pageUserScripts: [CefUserScript] = []
    var pageBridges: [CefBridge] = []
    var pageAttachments: [any CefBrowserAttachment] = []
    /// The profile's own ``configuration``, once the app changed it.
    var ownConfiguration: Configuration?

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

    /// The directory Chromium keeps this profile's files in — cookies,
    /// storage, cache, preferences, extensions: `Default` in
    /// ``CefRuntime/Configuration/rootCacheDirectory`` for the default
    /// profile, `Profile-<id>` there for a persistent one; `nil` for an
    /// incognito profile, which keeps everything in memory, and for one
    /// Chromium could not load. Once Chromium has loaded the profile this
    /// is the directory its request context reports (`get_cache_path`). A
    /// new profile's files appear as Chromium first saves them, some
    /// seconds after it loads.
    ///
    /// Read it to back the profile up or to show where it lives; do not
    /// write into it while the app runs.
    public var storageDirectory: URL? {
        if readiness == .ready, kind != .incognito, let context,
           let path = CefStringUtil.takingUserFree(context.pointer.pointee.get_cache_path(context.pointer)),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
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
            // Chromium loads the default profile as it starts. Its global
            // context has no handler, so the profile's pages use a context
            // sharing its storage, with the handler that applies the
            // profile's request filter, for workers too.
            guard let global = cef_request_context_get_global_context() else { return nil }
            context = CefRef(adopting: cef_request_context_cef_create_context_shared(
                global, CefProfileContextHandler(policy: requestPolicy).makeHandler()))
            readiness = .ready
            applyConfigured()
            for handler in schemeHandlers { register(handler) }
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
            let handler = CefProfileContextHandler(policy: requestPolicy) { [weak self] path in
                self?.contextDidInitialize(cachePath: path)
            }.makeHandler()
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
            for handler in CefRuntime.shared.schemeHandlers where !hasOwnSchemeHandler(handler) { register(handler) }
            for handler in schemeHandlers { register(handler) }
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
    /// before ``CefRuntime/initialize(configuration:)``,
    /// ``CefError/shutDown`` once Chromium shuts down (a caller still
    /// waiting then throws it too), and `CancellationError` if the calling
    /// task is cancelled.
    public func ready() async throws {
        _ = requestContext()
        switch readiness {
        case .ready: return
        case .failed(let reason): throw CefError.profileUnavailable(reason)
        case .pending:
            let state = CefRuntime.shared.state
            throw state == .stopping || state == .stopped ? CefError.shutDown : CefError.notInitialized
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
    /// profile that has a request context of its own and no handler of its
    /// own for that scheme and domain.
    static func registerSchemeHandler(_ handler: CefRuntime.RegisteredSchemeHandler) {
        profilesWithOwnContext.removeAll { $0.profile == nil }
        for entry in profilesWithOwnContext {
            guard let profile = entry.profile, !profile.hasOwnSchemeHandler(handler) else { continue }
            profile.register(handler)
        }
    }

    /// Removes a scheme handler ``CefRuntime`` no longer registers from
    /// every profile with a request context of its own and no handler of
    /// its own for it.
    static func unregisterSchemeHandler(scheme: String, domain: String?) {
        profilesWithOwnContext.removeAll { $0.profile == nil }
        for entry in profilesWithOwnContext {
            guard let profile = entry.profile,
                  !profile.schemeHandlers.contains(where: { $0.scheme == scheme && $0.domain == domain })
            else { continue }
            profile.registerFactory(nil, scheme: scheme, domain: domain)
        }
    }

    func hasOwnSchemeHandler(_ handler: CefRuntime.RegisteredSchemeHandler) -> Bool {
        schemeHandlers.contains { $0.scheme == handler.scheme && $0.domain == handler.domain }
    }

    func register(_ handler: CefRuntime.RegisteredSchemeHandler) {
        // Registration consumes the factory reference.
        registerFactory(handler.factory.makeFactory(), scheme: handler.scheme, domain: handler.domain)
    }

    /// Registers `factory` on the profile's context, or removes what is
    /// registered for `scheme` and `domain` when it is `nil`. Nothing
    /// happens before the profile has a context; it registers its own and
    /// the runtime's as it makes one.
    func registerFactory(
        _ factory: UnsafeMutablePointer<cef_scheme_handler_factory_t>?, scheme: String, domain: String?
    ) {
        guard let context = context?.pointer, let register = context.pointee.register_scheme_handler_factory else {
            cefRelease(factory)
            return
        }
        let registered = CefStringUtil.withCefString(scheme) { cefScheme in
            if let domain {
                return CefStringUtil.withCefString(domain) { register(context, cefScheme, $0, factory) }
            }
            return register(context, cefScheme, nil, factory)
        }
        if registered == 0 {
            CefLog.error("register_scheme_handler_factory failed for scheme '\(scheme)'")
        }
    }

    /// Applies the profile's ``configuration`` and the runtime
    /// configuration's preferences by name, once the profile is ready.
    /// Application-wide ones are CefRuntime's to apply.
    private func applyConfigured() {
        let named = CefRuntime.shared.configuration?.preferences ?? [:]
        let configured = configuration.setPreferences.merging(named) { $1 }
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

extension cef_basetime_t {
    /// Seconds between the Windows epoch (1601) Chromium counts from and the
    /// Unix epoch.
    private static let unixEpochOffset: TimeInterval = 11_644_473_600

    /// A date past what Chromium's microseconds hold, such as a cookie's
    /// expiry from a server's huge `Max-Age`, is the latest it holds.
    init(date: Date) {
        let microseconds = (date.timeIntervalSince1970 + Self.unixEpochOffset) * 1_000_000
        guard !microseconds.isNaN else {
            self.init(val: 0)
            return
        }
        // Int64.max is not a Double; the largest Double below it is.
        let limit = Double(Int64.max).nextDown
        self.init(val: Int64(min(max(microseconds, -limit), limit)))
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
        return owning(context.pointer)
    }

    /// The profile `context` belongs to, among the profiles made so far.
    /// Does not consume `context`.
    static func owning(_ context: UnsafeMutablePointer<cef_request_context_t>) -> CefProfile? {
        if context.pointee.is_global(context) != 0 { return .default }
        if let own = CefProfile.default.context {
            cefAddRef(own.pointer)
            if context.pointee.is_sharing_with(context, own.pointer) != 0 { return .default }
        }
        profilesWithOwnContext.removeAll { $0.profile == nil }
        return profilesWithOwnContext.lazy.compactMap(\.profile).first { profile in
            guard let own = profile.context else { return false }
            // Arguments passed into CEF are consumed.
            cefAddRef(own.pointer)
            return context.pointee.is_sharing_with(context, own.pointer) != 0
        }
    }
}
