import CCef
import CefBase
import Foundation

extension CefProfile {
    /// A cookie as Chromium stores it, with everything CEF reports about
    /// it.
    ///
    /// CEF 156 does not report a cookie's partition key: a partitioned
    /// (CHIPS) cookie is listed like any other, without the top-level site
    /// it is keyed to, and cannot be set with one.
    public struct Cookie: Sendable, Hashable {
        /// Which cross-site requests carry the cookie (`SameSite`).
        public enum SameSite: Sendable, Hashable {
            /// The server gave none; Chromium treats it as ``lax``.
            case unspecified
            /// `SameSite=None`: sent with cross-site requests too. Needs
            /// ``Cookie/isSecure``.
            case none
            case lax
            case strict
        }

        /// Which cookies Chromium evicts first when a domain has too many
        /// (`Priority`).
        public enum Priority: Sendable, Hashable {
            case low, medium, high
        }

        public var name: String
        public var value: String
        /// A domain cookie's domain, with a leading dot (sent to
        /// subdomains too), or a host cookie's host, without one. Empty
        /// when setting makes it a host cookie of the URL it is set for.
        public var domain: String
        /// Requests at or below this path carry the cookie; empty for all.
        public var path: String
        /// Whether only HTTPS requests carry it.
        public var isSecure: Bool
        /// Whether pages' scripts cannot read it.
        public var isHTTPOnly: Bool
        /// When it expires; nil for a session cookie.
        public var expirationDate: Date?
        public var sameSite: SameSite
        public var priority: Priority
        /// When Chromium stored it; nil for one the app made, which
        /// Chromium dates when it stores it.
        public var creationDate: Date?
        /// When a request last carried it; nil for one the app made.
        public var lastAccessDate: Date?

        /// Creates a cookie to set with ``CefProfile/setCookie(_:for:)``,
        /// or a value for previews and tests.
        public init(
            name: String, value: String, domain: String = "", path: String = "/",
            isSecure: Bool = false, isHTTPOnly: Bool = false, expirationDate: Date? = nil,
            sameSite: SameSite = .unspecified, priority: Priority = .medium,
            creationDate: Date? = nil, lastAccessDate: Date? = nil
        ) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.isSecure = isSecure
            self.isHTTPOnly = isHTTPOnly
            self.expirationDate = expirationDate
            self.sameSite = sameSite
            self.priority = priority
            self.creationDate = creationDate
            self.lastAccessDate = lastAccessDate
        }

        /// A URL the cookie belongs to, which CEF needs to set it: its
        /// domain, without the leading dot, by HTTPS when it is secure.
        var defaultURL: URL? {
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !host.isEmpty else { return nil }
            return URL(string: "\(isSecure ? "https" : "http")://\(host)\(path.hasPrefix("/") ? path : "/" + path)")
        }
    }

    // MARK: Reading

    /// The cookies a request to `url` would carry, HTTP-only ones
    /// included, or every cookie in the profile when `url` is nil;
    /// longest path first, then oldest first, as Chromium orders them.
    ///
    /// A cancelled task stops waiting and throws `CancellationError`.
    /// Throws ``CefError/operationFailed(_:)`` when Chromium cannot read
    /// the profile's cookies, ``CefError/notInitialized`` before Chromium
    /// runs.
    public func cookies(for url: URL? = nil) async throws -> [Cookie] {
        let collected = CookieList()
        try await visitCookies(for: url) { cookie in
            collected.cookies.append(cookie)
            return .next
        }
        return collected.cookies
    }

    /// Hands `body` each cookie ``cookies(for:)`` would return, one at a
    /// time on the main actor, until `body` sets `stop`; returns once
    /// Chromium has finished. For a large cookie store, this finds one
    /// without making an array of all.
    ///
    /// ```swift
    /// var session: CefProfile.Cookie?
    /// try await profile.enumerateCookies(for: url) { cookie, stop in
    ///     if cookie.name == "session" { session = cookie; stop = true }
    /// }
    /// ```
    public func enumerateCookies(
        for url: URL? = nil, using body: @escaping @MainActor (Cookie, _ stop: inout Bool) -> Void
    ) async throws {
        try await visitCookies(for: url) { cookie in
            var stop = false
            body(cookie, &stop)
            return stop ? .stop : .next
        }
    }

    // MARK: Changing

    /// Stores `cookie` for `url`, or for the URL its domain and path make
    /// when `url` is nil. Returns once Chromium has stored it.
    ///
    /// Throws ``CefError/operationFailed(_:)`` when Chromium refuses it:
    /// an invalid URL, a domain that does not match it, characters a
    /// cookie cannot hold, `SameSite=None` without `isSecure`, or a secure
    /// cookie for an `http` URL.
    public func setCookie(_ cookie: Cookie, for url: URL? = nil) async throws {
        guard let url = url ?? cookie.defaultURL else {
            throw CefError.operationFailed("A cookie without a domain needs the URL to set it for")
        }
        guard let manager = cookieManager() else { throw CefError.notInitialized }
        let stored = try await CefResumeOnce<Bool>.cancellable(fallback: false) { once in
            var raw = cookie.makeRaw()
            defer { raw.clear() }
            let callback = SetCookieCallback(once).makeCallback()
            // The callback is consumed whether or not the cookie can be set.
            _ = CefStringUtil.withCefString(url.absoluteString) {
                manager.pointer.pointee.set_cookie(manager.pointer, $0, &raw, callback)
            }
        }
        guard stored else {
            throw CefError.operationFailed("Chromium did not store the cookie \(cookie.name) for \(url.absoluteString)")
        }
    }

    /// Deletes cookies: the one called `name` for `url`, every host cookie
    /// of `url` (domain cookies stay), or, with both nil, every cookie in
    /// the profile. Returns how many Chromium deleted.
    @discardableResult
    public func deleteCookies(for url: URL? = nil, named name: String? = nil) async throws -> Int {
        guard let manager = cookieManager() else { throw CefError.notInitialized }
        let deleted = try await CefResumeOnce<Int>.cancellable(fallback: -1) { once in
            let callback = DeleteCookiesCallback(once).makeCallback()
            CefStringUtil.withCefString(url?.absoluteString ?? "") { cefURL in
                CefStringUtil.withCefString(name ?? "") { cefName in
                    _ = manager.pointer.pointee.delete_cookies(
                        manager.pointer, url == nil ? nil : cefURL, name == nil ? nil : cefName, callback)
                }
            }
        }
        guard deleted >= 0 else { throw CefError.operationFailed("Chromium could not delete cookies") }
        return deleted
    }

    /// Deletes each cookie ``cookies(for:)`` would return for which
    /// `shouldDelete` returns true, and returns how many it asked
    /// Chromium to delete.
    @discardableResult
    public func deleteCookies(
        for url: URL? = nil, where shouldDelete: @escaping @MainActor (Cookie) -> Bool
    ) async throws -> Int {
        try await visitCookies(for: url) { shouldDelete($0) ? .delete : .next }
    }

    /// Writes the profile's cookies to disk now rather than when Chromium
    /// next would; nothing for an incognito profile.
    public func flushCookies() async throws {
        guard let manager = cookieManager() else { throw CefError.notInitialized }
        let flushed = try await CefResumeOnce<Bool>.cancellable(fallback: false) { once in
            let callback = CookieFlushCallback(once).makeCallback()
            _ = manager.pointer.pointee.flush_store(manager.pointer, callback)
        }
        guard flushed else { throw CefError.operationFailed("Chromium could not flush the cookie store") }
    }

    // MARK: Visiting

    /// Visits the cookies for `url` (all, when nil) with `visit`, and
    /// returns how many it deleted.
    @discardableResult
    private func visitCookies(
        for url: URL?, _ visit: @escaping @MainActor (Cookie) -> CookieVisitor.Action
    ) async throws -> Int {
        guard let manager = cookieManager() else { throw CefError.notInitialized }
        let deleted = try await CefResumeOnce<Int>.cancellable(fallback: CookieVisitor.inaccessible) { once in
            let visitor = CookieVisitor(once, visit: visit)
            let pointer = visitor.makeVisitor()
            // The visitor is consumed; CEF releases it when it is done,
            // which reports how many were deleted.
            let started = if let url {
                CefStringUtil.withCefString(url.absoluteString) {
                    manager.pointer.pointee.visit_url_cookies(manager.pointer, $0, 1, pointer)
                }
            } else {
                manager.pointer.pointee.visit_all_cookies(manager.pointer, pointer)
            }
            if started == 0 { visitor.fail() }
        }
        guard deleted != CookieVisitor.inaccessible else {
            throw CefError.operationFailed("Chromium cannot read this profile's cookies")
        }
        return deleted
    }

    /// The profile's cookie manager; `nil` before Chromium runs and for a
    /// profile Chromium could not load. Chromium queues calls to it until
    /// the profile is loaded.
    func cookieManager() -> CefRef<cef_cookie_manager_t>? {
        guard let context = requestContext() else { return nil }
        return CefRef(adopting: context.pointer.pointee.get_cookie_manager(context.pointer, nil))
    }
}

// MARK: - Plumbing

/// The cookies ``CefProfile/cookies(for:)`` collects.
@MainActor
private final class CookieList {
    var cookies: [CefProfile.Cookie] = []
}

/// Hands each visited cookie to a closure on the main actor (CEF visits
/// on the UI thread, the main thread here) and reports, when CEF releases
/// it, how many it deleted. It stops visiting once its caller stopped
/// waiting.
private final class CookieVisitor: @unchecked Sendable {
    enum Action { case next, stop, delete }
    /// The count for "the cookies could not be read".
    static let inaccessible = -1

    private let once: CefResumeOnce<Int>
    // Touched only on the UI thread, during visits and at release.
    private let visit: @MainActor (CefProfile.Cookie) -> Action
    private var deleted = 0
    private var failed = false

    init(_ once: CefResumeOnce<Int>, visit: @escaping @MainActor (CefProfile.Cookie) -> Action) {
        self.once = once
        self.visit = visit
    }

    deinit {
        once.resume(returning: failed ? Self.inaccessible : deleted)
    }

    func fail() { failed = true }

    /// The returned +1 reference is consumed by the `visit_*_cookies` call.
    func makeVisitor() -> UnsafeMutablePointer<cef_cookie_visitor_t> {
        let visitor = cefAllocate(cef_cookie_visitor_t.self, owner: self)
        visitor.pointee.visit = { s, cookie, _, _, deleteCookie in
            guard let cookie, let owner = cefOwner(CookieVisitor.self, s), !owner.once.isFinished else { return 0 }
            let value = CefProfile.Cookie(raw: cookie.pointee)
            switch MainActor.assumeIsolated({ owner.visit(value) }) {
            case .next:
                return 1
            case .stop:
                return 0
            case .delete:
                deleteCookie?.pointee = 1
                owner.deleted += 1
                return 1
            }
        }
        return visitor
    }
}

private final class SetCookieCallback: Sendable {
    private let once: CefResumeOnce<Bool>
    init(_ once: CefResumeOnce<Bool>) { self.once = once }

    func makeCallback() -> UnsafeMutablePointer<cef_set_cookie_callback_t> {
        let callback = cefAllocate(cef_set_cookie_callback_t.self, owner: self)
        callback.pointee.on_complete = { s, success in
            cefOwner(SetCookieCallback.self, s)?.once.resume(returning: success != 0)
        }
        return callback
    }
}

private final class DeleteCookiesCallback: Sendable {
    private let once: CefResumeOnce<Int>
    init(_ once: CefResumeOnce<Int>) { self.once = once }

    func makeCallback() -> UnsafeMutablePointer<cef_delete_cookies_callback_t> {
        let callback = cefAllocate(cef_delete_cookies_callback_t.self, owner: self)
        callback.pointee.on_complete = { s, count in
            cefOwner(DeleteCookiesCallback.self, s)?.once.resume(returning: Int(max(0, count)))
        }
        return callback
    }
}

private final class CookieFlushCallback: Sendable {
    private let once: CefResumeOnce<Bool>
    init(_ once: CefResumeOnce<Bool>) { self.once = once }

    func makeCallback() -> UnsafeMutablePointer<cef_completion_callback_t> {
        let callback = cefAllocate(cef_completion_callback_t.self, owner: self)
        callback.pointee.on_complete = { s in cefOwner(CookieFlushCallback.self, s)?.once.resume(returning: true) }
        return callback
    }
}

extension CefProfile.Cookie {
    /// Reads a borrowed `cef_cookie_t`.
    init(raw cookie: cef_cookie_t) {
        self.init(
            name: CefStringUtil.string(from: cookie.name),
            value: CefStringUtil.string(from: cookie.value),
            domain: CefStringUtil.string(from: cookie.domain),
            path: CefStringUtil.string(from: cookie.path),
            isSecure: cookie.secure != 0,
            isHTTPOnly: cookie.httponly != 0,
            expirationDate: cookie.has_expires != 0 ? cookie.expires.date : nil,
            sameSite: SameSite(cefValue: cookie.same_site),
            priority: Priority(cefValue: cookie.priority),
            creationDate: cookie.creation.val == 0 ? nil : cookie.creation.date,
            lastAccessDate: cookie.last_access.val == 0 ? nil : cookie.last_access.date)
    }

    /// A `cef_cookie_t` whose strings the caller clears.
    func makeRaw() -> cef_cookie_t {
        var raw = cef_cookie_t()
        raw.size = MemoryLayout<cef_cookie_t>.stride
        CefStringUtil.set(name, into: &raw.name)
        CefStringUtil.set(value, into: &raw.value)
        CefStringUtil.set(domain, into: &raw.domain)
        CefStringUtil.set(path, into: &raw.path)
        raw.secure = isSecure ? 1 : 0
        raw.httponly = isHTTPOnly ? 1 : 0
        if let expirationDate {
            raw.has_expires = 1
            raw.expires = cef_basetime_t(date: expirationDate)
        }
        raw.same_site = sameSite.cefValue
        raw.priority = priority.cefValue
        return raw
    }
}

extension cef_cookie_t {
    mutating func clear() {
        ccef_string_clear(&name)
        ccef_string_clear(&value)
        ccef_string_clear(&domain)
        ccef_string_clear(&path)
    }
}

extension CefProfile.Cookie.SameSite {
    init(cefValue: cef_cookie_same_site_t) {
        switch cefValue {
        case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: self = .none
        case CEF_COOKIE_SAME_SITE_LAX_MODE: self = .lax
        case CEF_COOKIE_SAME_SITE_STRICT_MODE: self = .strict
        default: self = .unspecified
        }
    }

    var cefValue: cef_cookie_same_site_t {
        switch self {
        case .unspecified: CEF_COOKIE_SAME_SITE_UNSPECIFIED
        case .none: CEF_COOKIE_SAME_SITE_NO_RESTRICTION
        case .lax: CEF_COOKIE_SAME_SITE_LAX_MODE
        case .strict: CEF_COOKIE_SAME_SITE_STRICT_MODE
        }
    }
}

extension CefProfile.Cookie.Priority {
    init(cefValue: cef_cookie_priority_t) {
        switch cefValue {
        case CEF_COOKIE_PRIORITY_LOW: self = .low
        case CEF_COOKIE_PRIORITY_HIGH: self = .high
        default: self = .medium
        }
    }

    var cefValue: cef_cookie_priority_t {
        switch self {
        case .low: CEF_COOKIE_PRIORITY_LOW
        case .medium: CEF_COOKIE_PRIORITY_MEDIUM
        case .high: CEF_COOKIE_PRIORITY_HIGH
        }
    }
}
