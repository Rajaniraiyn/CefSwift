import os
import AppKit
import CCef
import Foundation
import CefBase

// MARK: - Resource request filtering

/// A network request about to be sent, as seen by a ``CefRequestFilter``.
public struct CefResourceRequest: Sendable, Equatable {
    public var url: URL?
    public var method: String
    /// The page URL that initiated the request, when known. Parsed when
    /// read: most filters never look at it.
    public var referrer: URL? {
        get { referrerString.flatMap(URL.init(string:)) }
        set { referrerString = newValue?.absoluteString }
    }
    /// Whether this is a main-frame or subframe navigation.
    public var isNavigation: Bool
    private var referrerString: String?

    init(url: URL?, method: String, referrerString: String?, isNavigation: Bool) {
        self.url = url
        self.method = method
        self.referrerString = referrerString
        self.isNavigation = isNavigation
    }

    /// Creates a value of your own, for previews and tests.
    public init(url: URL?, method: String = "GET", referrer: URL? = nil, isNavigation: Bool = false) {
        self.init(url: url, method: method, referrerString: referrer?.absoluteString, isNavigation: isNavigation)
    }
}

/// What a ``CefRequestFilter`` does with a request.
public enum CefResourceRequestAction: Sendable, Equatable {
    /// Send it unchanged.
    case allow
    /// Fail it with `ERR_BLOCKED_BY_CLIENT`.
    case block
    /// Send it to a different URL.
    case redirect(URL)
    /// Send it with these headers added or replaced.
    case setHeaders([String: String])
}

/// Inspects every network request a browser makes — the hook for content
/// blocking, header injection and redirects.
///
/// Chromium asks on its IO thread and waits for the answer, so a filter
/// runs there synchronously, isolated to ``CefIOActor``: state it keeps on
/// that actor needs no lock, and no decision waits for the main thread.
/// It must be fast and must not block. A filter that needs the app's
/// model reads a copy kept on ``CefIOActor`` and updated from the main
/// actor:
///
/// ```swift
/// @CefIOActor var blockedHosts: Set<String> = []
///
/// configuration.requestFilter = { @CefIOActor request in
///     blockedHosts.contains(request.url?.host() ?? "") ? .block : .allow
/// }
///
/// // On the main actor, when the list changes:
/// Task { @CefIOActor in blockedHosts = newList }
/// ```
public typealias CefRequestFilter = @CefIOActor @Sendable (CefResourceRequest) -> CefResourceRequestAction

/// Owner of the `cef_resource_request_handler_t` every browser's requests
/// go through: it applies the browser's filter, when it has one, and
/// hands URLs of schemes Chromium does not load to the delegate.
final class ResourceRequestHandler: Sendable {
    let filter: CefRequestFilter?

    init(filter: CefRequestFilter?) {
        self.filter = filter
    }

    func makeHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t> {
        let h = cefAllocate(cef_resource_request_handler_t.self, owner: self)
        // IO thread. Chromium never opens another app itself: the delegate
        // decides on the main actor, and CefKit opens the URL.
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
        guard filter != nil else { return h }
        h.pointee.on_before_resource_load = { s, browser, frame, request, callback in
            let started = CefDiagnostics.start()
            var filterTime: UInt64 = 0
            defer {
                if started != 0 { CefDiagnostics.record(.requestFilterOverhead, since: started &+ filterTime) }
            }
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(callback)
            // Released on every return below.
            guard let owned = CefOwned(request) else { return RV_CONTINUE }
            let request = owned.pointer
            guard let owner = cefOwner(ResourceRequestHandler.self, s), let filter = owner.filter else { return RV_CONTINUE }
            let resourceType = request.pointee.get_resource_type(request)
            let snapshot = CefResourceRequest(
                url: CefStringUtil.takingUserFree(request.pointee.get_url(request)).flatMap(URL.init(string:)),
                method: CefStringUtil.takingUserFree(request.pointee.get_method(request)) ?? "GET",
                referrerString: CefStringUtil.takingUserFree(request.pointee.get_referrer_url(request)),
                isNavigation: resourceType == RT_MAIN_FRAME || resourceType == RT_SUB_FRAME
            )
            // CEF calls this on the IO thread, which the filter is isolated to.
            let filterStarted = CefDiagnostics.start()
            let action = CefIOActor.assumeIsolated({ filter(snapshot) })
            if filterStarted != 0 {
                filterTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- filterStarted
                CefDiagnostics.record(.requestFilter, since: filterStarted)
            }
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
            }
            return RV_CONTINUE
        }
        return h
    }
}
