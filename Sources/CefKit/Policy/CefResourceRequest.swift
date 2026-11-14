import os
import AppKit
import CCef
import Foundation
import CefBase

// MARK: - Resource request filtering

/// A network request about to be sent, as a ``CefRequestFilter`` sees it.
public struct CefResourceRequest: Sendable, Equatable {
    /// What the request loads, as Chromium classifies it.
    public enum ResourceType: Sendable, Hashable, CaseIterable {
        /// A top-level document.
        case mainFrame
        /// A document in an `iframe`.
        case subframe
        case stylesheet
        case script
        case image
        case font
        /// Audio or video.
        case media
        /// `fetch()` and `XMLHttpRequest`.
        case fetch
        /// A `<a ping>`, `navigator.sendBeacon()` or similar.
        case ping
        case favicon
        /// A `<link rel=prefetch>`.
        case prefetch
        /// A dedicated worker's script.
        case worker
        /// A shared worker's script.
        case sharedWorker
        /// A service worker's script.
        case serviceWorker
        /// A Content Security Policy violation report.
        case cspReport
        /// `<object>` and `<embed>` content.
        case object
        /// Anything else.
        case other

        init(_ type: cef_resource_type_t) {
            switch type {
            case RT_MAIN_FRAME, RT_NAVIGATION_PRELOAD_MAIN_FRAME: self = .mainFrame
            case RT_SUB_FRAME, RT_NAVIGATION_PRELOAD_SUB_FRAME: self = .subframe
            case RT_STYLESHEET: self = .stylesheet
            case RT_SCRIPT: self = .script
            case RT_IMAGE: self = .image
            case RT_FONT_RESOURCE: self = .font
            case RT_MEDIA: self = .media
            case RT_XHR: self = .fetch
            case RT_PING: self = .ping
            case RT_FAVICON: self = .favicon
            case RT_PREFETCH: self = .prefetch
            case RT_WORKER: self = .worker
            case RT_SHARED_WORKER: self = .sharedWorker
            case RT_SERVICE_WORKER: self = .serviceWorker
            case RT_CSP_REPORT: self = .cspReport
            case RT_OBJECT, RT_PLUGIN_RESOURCE: self = .object
            default: self = .other
            }
        }

        /// The `cef_resource_type_t` values of this type, as a mask of
        /// `1 << value`, for the C matcher.
        var cefMask: UInt64 {
            let types: [cef_resource_type_t] =
                switch self {
                case .mainFrame: [RT_MAIN_FRAME, RT_NAVIGATION_PRELOAD_MAIN_FRAME]
                case .subframe: [RT_SUB_FRAME, RT_NAVIGATION_PRELOAD_SUB_FRAME]
                case .stylesheet: [RT_STYLESHEET]
                case .script: [RT_SCRIPT]
                case .image: [RT_IMAGE]
                case .font: [RT_FONT_RESOURCE]
                case .media: [RT_MEDIA]
                case .fetch: [RT_XHR]
                case .ping: [RT_PING]
                case .favicon: [RT_FAVICON]
                case .prefetch: [RT_PREFETCH]
                case .worker: [RT_WORKER]
                case .sharedWorker: [RT_SHARED_WORKER]
                case .serviceWorker: [RT_SERVICE_WORKER]
                case .cspReport: [RT_CSP_REPORT]
                case .object: [RT_OBJECT, RT_PLUGIN_RESOURCE]
                case .other: [RT_SUB_RESOURCE]
                }
            return types.reduce(0) { $0 | (1 << UInt64($1.rawValue)) }
        }
    }

    /// Which cookies a request may send and which of its response's it may
    /// save; see ``CefResourceRequestAction/restrictCookies(to:)``.
    public struct CookieAccess: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The request carries the profile's cookies for its address.
        public static let send = CookieAccess(rawValue: 1 << 0)
        /// Cookies the response sets are saved.
        public static let save = CookieAccess(rawValue: 1 << 1)
    }

    public var url: URL?
    public var method: String
    /// What the request loads.
    public var resourceType: ResourceType
    /// Whether this is a main-frame or subframe navigation.
    public var isNavigation: Bool
    /// The frame that made the request; `nil` for a request with no
    /// frame: a service worker's or a shared worker's.
    public var frame: CefFrame?
    /// The ``CefBrowser/identifier`` of the page that made the request;
    /// `nil` when no page did.
    public var pageIdentifier: Int32?
    /// The page URL that initiated the request, when known. Parsed when
    /// read: most filters never look at it.
    public var referrer: URL? {
        get { referrerString.flatMap(URL.init(string:)) }
        set { referrerString = newValue?.absoluteString }
    }
    /// The origin of the document that initiated the request
    /// (`https://example.com`); `nil` for a request no document initiated,
    /// such as a navigation typed into the address bar.
    public var initiator: URL? {
        get { initiatorString.flatMap(URL.init(string:)) }
        set { initiatorString = newValue?.absoluteString }
    }
    /// The site the request is made for, its first party for cookies:
    /// the top-level document's scheme and host, such as
    /// `https://www.example.com/` (Chromium reports a site, not the
    /// document's full address); `nil` when Chromium does not say.
    public var firstPartyURL: URL? {
        get { firstPartyString.flatMap(URL.init(string:)) }
        set { firstPartyString = newValue?.absoluteString }
    }

    /// Whether the request goes to another site than its first party's
    /// (``firstPartyURL``): a third-party request, as content blockers use
    /// the term. Two hosts are the same site when they share their
    /// registrable domain, here their last two labels, or three when the
    /// second-to-last is a short label under a two-letter country code
    /// (`example.co.uk`); IP addresses compare whole. `false` when either
    /// address has no host.
    public var isThirdParty: Bool {
        guard let host = url?.host(), let firstParty = firstPartyURL?.host() else { return false }
        return Self.site(of: host) != Self.site(of: firstParty)
    }

    private var referrerString: String?
    private var initiatorString: String?
    private var firstPartyString: String?

    init(
        url: URL?, method: String, resourceType: ResourceType, isNavigation: Bool, frame: CefFrame?,
        pageIdentifier: Int32?, referrerString: String?, initiatorString: String?, firstPartyString: String?
    ) {
        self.url = url
        self.method = method
        self.resourceType = resourceType
        self.isNavigation = isNavigation
        self.frame = frame
        self.pageIdentifier = pageIdentifier
        self.referrerString = referrerString
        self.initiatorString = initiatorString
        self.firstPartyString = firstPartyString
    }

    /// Creates a value of your own, for previews and tests.
    public init(
        url: URL?, method: String = "GET", resourceType: ResourceType = .other, isNavigation: Bool = false,
        frame: CefFrame? = nil, pageIdentifier: Int32? = nil, referrer: URL? = nil, initiator: URL? = nil,
        firstPartyURL: URL? = nil
    ) {
        self.init(
            url: url, method: method, resourceType: resourceType, isNavigation: isNavigation, frame: frame,
            pageIdentifier: pageIdentifier, referrerString: referrer?.absoluteString,
            initiatorString: initiator?.absoluteString, firstPartyString: firstPartyURL?.absoluteString)
    }

    /// The site of `host` for ``isThirdParty``: its registrable domain by
    /// the rule given there, lowercased.
    static func site(of host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host.contains(":") || host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return host
        }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = last.count == 2 && second.count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// What a ``CefRequestFilter`` does with a request.
///
/// A filter cannot edit a response: CEF lets an embedder change a request
/// before it is sent, but not a response's headers in place.
public enum CefResourceRequestAction: Sendable, Equatable {
    /// Send it unchanged.
    case allow
    /// Fail it with `ERR_BLOCKED_BY_CLIENT`.
    case block
    /// Send it to a different URL.
    case redirect(URL)
    /// Send it with these headers added or replaced.
    case setHeaders([String: String])
    /// Send it unchanged, with only the cookie traffic `access` lets
    /// through: `[]` sends none of the profile's cookies and saves none the
    /// response sets, `.save` only saves them.
    case restrictCookies(to: CefResourceRequest.CookieAccess)
}

/// Inspects the network requests of a profile, or of one page — the hook
/// for content blocking, header injection and redirects.
///
/// Set one on a profile, for every request its pages, service workers and
/// shared workers make (``CefProfile/requestFilter``), or on one page,
/// replacing the profile's for that page's requests
/// (``CefBrowser/Configuration/requestFilter``):
///
/// ```swift
/// profile.requestFilter = CefRequestFilter(hosts: ["ads.example", "tracker.example"]) { _ in .block }
/// ```
///
/// **Matching.** ``hosts``, ``urlPatterns`` and ``resourceTypes`` say which
/// requests the filter wants. They are tested in C on Chromium's IO
/// thread as each request starts, on the address as Chromium hands it
/// over, so a request outside them costs no Swift value and never reaches
/// ``decide``. A filter without hosts or patterns wants every address; one
/// without resource types, every type. A redirect of a request the filter
/// wanted is decided again; a request that started outside it is not
/// looked at when it redirects.
///
/// **Deciding.** Chromium asks on its IO thread and waits for the answer,
/// so ``decide`` runs there synchronously, isolated to ``CefIOActor``:
/// state it keeps on that actor needs no lock, and no decision waits for
/// the main thread. It must be fast and must not block. A filter that
/// needs the app's model reads a copy kept on ``CefIOActor`` and updated
/// from the main actor:
///
/// ```swift
/// @CefIOActor var blockedHosts: Set<String> = []
///
/// configuration.requestFilter = CefRequestFilter { @CefIOActor request in
///     blockedHosts.contains(request.url?.host() ?? "") ? .block : .allow
/// }
///
/// // On the main actor, when the list changes:
/// Task { @CefIOActor in blockedHosts = newList }
/// ```
public struct CefRequestFilter: Sendable {
    /// Host names whose requests the filter wants, each with its
    /// subdomains, compared without case: `"example.com"` covers
    /// `www.example.com`. Write international names as Chromium sends
    /// them, in Punycode.
    public var hosts: Set<String>
    /// Addresses the filter wants, where `*` stands for any run of
    /// characters: `"https://*.example.com/ads/*"`. A request matches when
    /// its host is in ``hosts`` or its address matches a pattern.
    public var urlPatterns: [String]
    /// The kinds of request the filter wants; empty for every kind.
    public var resourceTypes: Set<CefResourceRequest.ResourceType>
    /// Decides each request the filter wants.
    public var decide: @CefIOActor @Sendable (CefResourceRequest) -> CefResourceRequestAction

    public init(
        hosts: Set<String> = [], urlPatterns: [String] = [],
        resourceTypes: Set<CefResourceRequest.ResourceType> = [],
        _ decide: @escaping @CefIOActor @Sendable (CefResourceRequest) -> CefResourceRequestAction
    ) {
        self.hosts = hosts
        self.urlPatterns = urlPatterns
        self.resourceTypes = resourceTypes
        self.decide = decide
    }
}

// MARK: - Compiled filters

/// A ``CefRequestFilter`` with its matching compiled for C. Immutable, so
/// the IO thread reads it without a lock once it holds a reference.
final class CefCompiledRequestFilter: Sendable {
    /// The filter as the app gave it.
    let source: CefRequestFilter
    let decide: @CefIOActor @Sendable (CefResourceRequest) -> CefResourceRequestAction
    /// `nil` when the filter wants every request.
    private nonisolated(unsafe) let match: OpaquePointer?

    init(_ filter: CefRequestFilter) {
        source = filter
        decide = filter.decide
        let types = filter.resourceTypes.reduce(UInt64(0)) { $0 | $1.cefMask }
        guard types != 0 || !filter.hosts.isEmpty || !filter.urlPatterns.isEmpty else {
            match = nil
            return
        }
        let hosts = filter.hosts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        let patterns = filter.urlPatterns
        func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> R) -> R {
            let copies = strings.map { strdup($0) }
            defer { copies.forEach { free($0) } }
            return body(copies.map { UnsafePointer($0) })
        }
        match = withCStrings(hosts) { hostPointers in
            withCStrings(patterns) { patternPointers in
                ccef_request_match_create(
                    types, hostPointers, hostPointers.count, patternPointers, patternPointers.count)
            }
        }
    }

    deinit {
        ccef_request_match_destroy(match)
    }

    /// Whether the filter wants a request of `type` for `url`; in C.
    func wants(_ url: UnsafePointer<cef_string_utf16_t>?, type: cef_resource_type_t) -> Bool {
        guard let match else { return true }
        return ccef_request_match_test(match, url, Int32(type.rawValue)) != 0
    }

    /// Whether `type` alone rules a request out, before its address is read.
    func excludes(_ type: cef_resource_type_t) -> Bool {
        guard let match else { return false }
        return ccef_request_match_excludes_type(match, Int32(type.rawValue)) != 0
    }
}

/// Whose filter decides a page's requests.
enum CefRequestFiltering: Sendable {
    /// The profile's (``CefProfile/requestFilter``), through the profile's
    /// request context handler: the page's client returns no handler.
    case profile
    /// The page's own, which replaces the profile's.
    case page(CefCompiledRequestFilter)
    /// None at all: CefKit's own hidden pages (service hosts).
    case unfiltered
}

// MARK: - Handlers

/// Builds the `cef_resource_request_handler_t`s for requests: from a
/// page's client (`cef_request_handler_t.get_resource_request_handler`)
/// or from a profile's request context handler. Each applies one filter,
/// and hands URLs of schemes Chromium does not load to the page's
/// delegate.
enum CefResourceRequestHandlers {
    /// The handler for one request, with a reference for CEF; `nil` when
    /// nothing needs to see the request: neither the filter, which does
    /// not want it, nor the external-protocol check, which only
    /// navigations need. IO thread.
    static func handler(
        filter: CefCompiledRequestFilter?, browser: UnsafeMutablePointer<cef_browser_t>?,
        request: UnsafeMutablePointer<cef_request_t>?, isNavigation: Bool,
        initiator: UnsafePointer<cef_string_t>?
    ) -> UnsafeMutablePointer<cef_resource_request_handler_t>? {
        let started = CefDiagnostics.start()
        defer { if started != 0 { CefDiagnostics.record(.requestFilterMatch, since: started) } }
        guard let filter, let request else {
            return isNavigation ? navigationHandler.retained() : nil
        }
        let type = request.pointee.get_resource_type(request)
        var wanted = false
        if !filter.excludes(type) {
            let url = request.pointee.get_url(request)
            defer { if let url { cef_string_userfree_utf16_free(url) } }
            wanted = filter.wants(url.map { UnsafePointer($0) }, type: type)
        }
        guard wanted else { return isNavigation ? navigationHandler.retained() : nil }
        let owner = FilteredRequest(
            filter: filter, isNavigation: isNavigation,
            pageIdentifier: browser.map { $0.pointee.get_identifier($0) },
            initiator: initiator.flatMap { CefStringUtil.string(from: $0).nilIfEmpty })
        return owner.makeHandler()
    }

    /// The handler for a page no filter decides: it keeps the profile's
    /// request context handler from deciding instead, and checks external
    /// protocols. With a reference for CEF.
    static func unfilteredHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t> {
        navigationHandler.retained()
    }

    /// The handler for navigations no filter wants: only the
    /// external-protocol check.
    private static let navigationHandler = SharedHandler()

    private final class SharedHandler: Sendable {
        private nonisolated(unsafe) let handler: UnsafeMutablePointer<cef_resource_request_handler_t>

        init() {
            handler = cefAllocate(cef_resource_request_handler_t.self, owner: NavigationHandlerOwner())
            CefResourceRequestHandlers.installProtocolExecution(on: handler)
        }

        func retained() -> UnsafeMutablePointer<cef_resource_request_handler_t> {
            cefAddRef(handler)
            return handler
        }
    }

    private final class NavigationHandlerOwner {}

    /// IO thread. Chromium never opens another app itself: the page's
    /// delegate decides on the main actor, and CefKit opens the URL.
    static func installProtocolExecution(on h: UnsafeMutablePointer<cef_resource_request_handler_t>) {
        h.pointee.on_protocol_execution = { _, browser, frame, request, allowOSExecution in
            allowOSExecution?.pointee = 0
            let identifier = browser.map { $0.pointee.get_identifier($0) }
            let frameURL = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }.flatMap(URL.init(string:))
            let isMainFrame = frame.map { $0.pointee.is_main($0) != 0 } ?? true
            let url = request.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }.flatMap(URL.init(string:))
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(request)
            guard let identifier, let url else { return }
            let externalRequest = CefExternalProtocolRequest(url: url, frameURL: frameURL, isMainFrame: isMainFrame)
            Task { @MainActor in
                CefRuntime.shared.browser(withIdentifier: identifier)?.handleExternalProtocol(externalRequest)
            }
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One request a filter wants: decides it in `on_before_resource_load`
/// (again after each redirect) and applies the decision's cookie access.
/// Only CEF's IO thread touches it.
private final class FilteredRequest: @unchecked Sendable {
    let filter: CefCompiledRequestFilter
    let isNavigation: Bool
    let pageIdentifier: Int32?
    let initiator: String?
    /// The cookie traffic the last decision lets through.
    var cookieAccess: CefResourceRequest.CookieAccess = [.send, .save]

    init(filter: CefCompiledRequestFilter, isNavigation: Bool, pageIdentifier: Int32?, initiator: String?) {
        self.filter = filter
        self.isNavigation = isNavigation
        self.pageIdentifier = pageIdentifier
        self.initiator = initiator
    }

    func makeHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t> {
        let h = cefAllocate(cef_resource_request_handler_t.self, owner: self)
        if isNavigation { CefResourceRequestHandlers.installProtocolExecution(on: h) }
        h.pointee.on_before_resource_load = { s, browser, frame, request, callback in
            let started = CefDiagnostics.start()
            var filterTime: UInt64 = 0
            defer {
                if started != 0 { CefDiagnostics.record(.requestFilterOverhead, since: started &+ filterTime) }
            }
            cefRelease(browser)
            cefRelease(callback)
            let frameValue = frame.map(CefFrame.init(reading:))
            cefRelease(frame)
            // Released on every return below.
            guard let owned = CefOwned(request) else { return RV_CONTINUE }
            let request = owned.pointer
            guard let owner = cefOwner(FilteredRequest.self, s) else { return RV_CONTINUE }
            let type = request.pointee.get_resource_type(request)
            let rawURL = request.pointee.get_url(request)
            // A redirect may lead outside what the filter wants.
            guard owner.filter.wants(rawURL.map { UnsafePointer($0) }, type: type) else {
                if let rawURL { cef_string_userfree_utf16_free(rawURL) }
                return RV_CONTINUE
            }
            let snapshot = CefResourceRequest(
                url: CefStringUtil.takingUserFree(rawURL).flatMap(URL.init(string:)),
                method: CefStringUtil.takingUserFree(request.pointee.get_method(request)) ?? "GET",
                resourceType: CefResourceRequest.ResourceType(type),
                isNavigation: owner.isNavigation,
                frame: frameValue,
                pageIdentifier: owner.pageIdentifier,
                referrerString: CefStringUtil.takingUserFree(request.pointee.get_referrer_url(request)),
                initiatorString: owner.initiator,
                firstPartyString: CefStringUtil.takingUserFree(request.pointee.get_first_party_for_cookies(request))
            )
            // CEF calls this on the IO thread, which the filter is isolated to.
            let filterStarted = CefDiagnostics.start()
            let decide = owner.filter.decide
            let action = CefIOActor.assumeIsolated({ decide(snapshot) })
            if filterStarted != 0 {
                filterTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- filterStarted
                CefDiagnostics.record(.requestFilter, since: filterStarted)
            }
            owner.cookieAccess = [.send, .save]
            switch action {
            case .allow:
                break
            case .block:
                return RV_CANCEL
            case .redirect(let url):
                CefStringUtil.withCefString(url.absoluteString) { request.pointee.set_url(request, $0) }
            case .setHeaders(let headers):
                for (name, value) in headers {
                    CefStringUtil.withCefString(name) { cefName in
                        CefStringUtil.withCefString(value) { cefValue in
                            request.pointee.set_header_by_name(request, cefName, cefValue, 1)
                        }
                    }
                }
            case .restrictCookies(let access):
                owner.cookieAccess = access
            }
            return RV_CONTINUE
        }
        h.pointee.get_cookie_access_filter = { s, browser, frame, request in
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(request)
            guard let owner = cefOwner(FilteredRequest.self, s) else { return nil }
            let filter = cefAllocate(cef_cookie_access_filter_t.self, owner: owner)
            filter.pointee.can_send_cookie = { s, browser, frame, request, _ in
                cefRelease(browser)
                cefRelease(frame)
                cefRelease(request)
                return cefOwner(FilteredRequest.self, s)?.cookieAccess.contains(.send) == false ? 0 : 1
            }
            filter.pointee.can_save_cookie = { s, browser, frame, request, response, _ in
                cefRelease(browser)
                cefRelease(frame)
                cefRelease(request)
                cefRelease(response)
                return cefOwner(FilteredRequest.self, s)?.cookieAccess.contains(.save) == false ? 0 : 1
            }
            return filter
        }
        return h
    }
}
