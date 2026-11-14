import CCef
import CefBase
import Foundation

// MARK: - Text and source

extension CefBrowser {
    /// The text `frame` shows (`innerText` of its document, as Chromium
    /// renders it); the main frame's when `frame` is nil. Read natively
    /// from the renderer, without running script in the page.
    ///
    /// Throws ``CefError/operationFailed(_:)`` when the frame is gone or
    /// the browser has nothing in Chromium, and `CancellationError` at once
    /// when the task is cancelled.
    public func text(of frame: CefFrame? = nil) async throws -> String {
        try await readFrame(frame, what: "text") { $0.pointee.get_text($0, $1) }
    }

    /// The HTML source of `frame`'s document as it is now, the DOM
    /// serialized (not what the server sent); the main frame's when
    /// `frame` is nil. Read natively from the renderer, without running
    /// script in the page.
    ///
    /// Throws as ``text(of:)`` does.
    public func source(of frame: CefFrame? = nil) async throws -> String {
        try await readFrame(frame, what: "source") { $0.pointee.get_source($0, $1) }
    }

    private func readFrame(
        _ frame: CefFrame?, what: String,
        _ read: (UnsafeMutablePointer<cef_frame_t>, UnsafeMutablePointer<cef_string_visitor_t>) -> Void
    ) async throws -> String {
        try await ready()
        let value = try await CefResumeOnce<String?>.cancellable(fallback: nil) { once in
            let run = { (raw: UnsafeMutablePointer<cef_frame_t>) in read(raw, StringVisitor(once).makeVisitor()) }
            if let frame { withFrame(frame.id, run) } else { withMainFrame(run) }
        }
        guard let value else { throw CefError.operationFailed("Could not read the frame's \(what): it is gone") }
        return value
    }
}

/// Bridges `cef_string_visitor_t` to a continuation, which resumes with
/// nil if CEF drops the visitor without calling it.
private final class StringVisitor: Sendable {
    private let once: CefResumeOnce<String?>
    init(_ once: CefResumeOnce<String?>) { self.once = once }

    /// The returned +1 reference is consumed by `get_text` or `get_source`.
    func makeVisitor() -> UnsafeMutablePointer<cef_string_visitor_t> {
        let visitor = cefAllocate(cef_string_visitor_t.self, owner: self)
        visitor.pointee.visit = { s, string in
            cefOwner(StringVisitor.self, s)?.once.resume(returning: CefStringUtil.string(from: string))
        }
        return visitor
    }
}

// MARK: - Loading a request

extension CefBrowser {
    /// Navigates the main frame with `request`: its method, headers and
    /// body (`httpBody`; a body stream is not supported), as a form
    /// submission would.
    ///
    /// Chromium allows this only from a page of the request's own origin:
    /// CEF's `load_request` ends the renderer (`INVALID_INITIATOR_ORIGIN`)
    /// unless the main frame is already there. So the browser must be live
    /// and showing a page of that origin, for example after
    /// ``load(_:)-(URL)`` of the site's start page; otherwise the
    /// navigation fails at once with ``CefError/operationFailed(_:)`` and
    /// nothing is sent. For a plain address, use ``load(_:)-(URL)``.
    @discardableResult
    public func load(_ request: URLRequest) -> CefNavigation {
        guard let url = request.url else {
            return CefNavigation(url: Self.blankURL, failure: CefError.operationFailed("The request has no URL"))
        }
        guard state != .closed else { return CefNavigation(url: url, failure: CefError.browserClosed) }
        guard raw != nil, !isBootstrapping, let current = self.url, Self.sameOrigin(current, url) else {
            return CefNavigation(url: url, failure: CefError.operationFailed(
                "load(URLRequest) needs the main frame on \(url.scheme ?? "")://\(url.host() ?? "") first"))
        }
        guard request.httpBodyStream == nil else {
            return CefNavigation(url: url, failure: CefError.operationFailed("A request body stream is not supported"))
        }
        let navigation = requestNavigation(to: url, isLoadRequest: true)
        let cefRequest = Self.makeRequest(request, url: url)
        withMainFrame { frame in
            // load_request takes the request reference.
            frame.pointee.load_request(frame, cefRequest)
        }
        return navigation
    }

    private static let blankURL = URL(string: "about:blank") ?? URL(fileURLWithPath: "/")

    /// Whether two addresses share scheme, host and port.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased()
            && port(a) == port(b)
    }

    /// A +1 `cef_request_t` for `request`.
    private static func makeRequest(_ request: URLRequest, url: URL) -> UnsafeMutablePointer<cef_request_t>? {
        guard let raw = cef_request_create() else { return nil }
        CefStringUtil.withCefString(url.absoluteString) { raw.pointee.set_url(raw, $0) }
        CefStringUtil.withCefString(request.httpMethod ?? "GET") { raw.pointee.set_method(raw, $0) }
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            withCefStringMultimap(headers.lazy.map { (name: $0.key, value: $0.value) }) { raw.pointee.set_header_map(raw, $0) }
        }
        if let body = request.httpBody, let postData = cef_post_data_create() {
            if let element = cef_post_data_element_create() {
                body.withUnsafeBytes { element.pointee.set_to_bytes(element, $0.count, $0.baseAddress) }
                _ = postData.pointee.add_element(postData, element)
            }
            raw.pointee.set_post_data(raw, postData)
        }
        return raw
    }
}
