import CCef
import CefBase
import Foundation

extension CefProfile {
    // Each call below waits for Chromium to finish; a cancelled task stops
    // waiting and throws `CancellationError`, and Chromium still finishes.

    /// Empties the profile's HTTP cache. Cookies and site data stay.
    public func clearHTTPCache() async throws {
        try await completing { context, callback in
            guard let clear = context.pointee.clear_http_cache else { return cefRelease(callback) }
            clear(context, callback)
        }
    }

    /// Forgets the certificate errors the user chose to proceed despite
    /// (``CefBrowserDelegate/browser(_:shouldProceedDespite:)``), so the
    /// delegate is asked again. Call ``closeAllConnections()`` too, or a
    /// connection still open keeps the exception in use.
    public func clearCertificateExceptions() async throws {
        try await completing { context, callback in context.pointee.clear_certificate_exceptions(context, callback) }
    }

    /// Forgets the HTTP authentication credentials sites were given.
    public func clearHTTPAuthenticationCredentials() async throws {
        try await completing { context, callback in context.pointee.clear_http_auth_credentials(context, callback) }
    }

    /// Closes every open and idle connection. Requests already started
    /// fail; later ones connect again.
    public func closeAllConnections() async throws {
        try await completing { context, callback in context.pointee.close_all_connections(context, callback) }
    }

    /// The IP addresses Chromium resolves `host` to, with the profile's DNS
    /// settings (Secure DNS included).
    ///
    /// Throws ``CefError/operationFailed(_:)`` with Chromium's network
    /// error when the name does not resolve, and `CancellationError` at
    /// once when the task is cancelled.
    public func resolveHost(_ host: String) async throws -> [String] {
        try await ready()
        guard let context = requestContext() else { throw CefError.notInitialized }
        let url = host.contains("://") ? host : "https://\(host)"
        let result = try await CefResumeOnce<(Int32, [String])>.cancellable(fallback: (-2, [])) { once in
            let callback = ResolveCallback(once).makeCallback()
            CefStringUtil.withCefString(url) { context.pointer.pointee.resolve_host(context.pointer, $0, callback) }
        }
        guard result.0 == 0, !result.1.isEmpty else {
            throw CefError.operationFailed("Cannot resolve \(host): net error \(result.0)")
        }
        return result.1
    }

    /// Runs a request-context call that reports completion through a
    /// `cef_completion_callback_t`, and waits for it. A cancelled task
    /// stops waiting and throws `CancellationError`; Chromium finishes the
    /// call.
    private func completing(
        _ call: (UnsafeMutablePointer<cef_request_context_t>, UnsafeMutablePointer<cef_completion_callback_t>) -> Void
    ) async throws {
        do {
            try await ready()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A profile Chromium could not load has nothing to clear.
            return
        }
        guard let context = requestContext() else { return }
        try await CefResumeOnce<Void>.cancellable(fallback: ()) { once in
            call(context.pointer, CompletionCallback(once).makeCallback())
        }
    }
}

/// Bridges `cef_completion_callback_t` to a continuation, which also
/// resumes if CEF drops the callback without calling it.
private final class CompletionCallback: Sendable {
    private let continuation: CefResumeOnce<Void>

    init(_ continuation: CefResumeOnce<Void>) {
        self.continuation = continuation
    }

    /// The returned +1 reference is consumed by the call it is passed to.
    func makeCallback() -> UnsafeMutablePointer<cef_completion_callback_t> {
        let callback = cefAllocate(cef_completion_callback_t.self, owner: self)
        callback.pointee.on_complete = { s in cefOwner(CompletionCallback.self, s)?.continuation.resume(returning: ()) }
        return callback
    }
}

/// Bridges `cef_resolve_callback_t` to a continuation, which resumes with
/// `ERR_FAILED` if CEF drops the callback without calling it.
private final class ResolveCallback: Sendable {
    private let continuation: CefResumeOnce<(Int32, [String])>

    init(_ continuation: CefResumeOnce<(Int32, [String])>) {
        self.continuation = continuation
    }

    func makeCallback() -> UnsafeMutablePointer<cef_resolve_callback_t> {
        let callback = cefAllocate(cef_resolve_callback_t.self, owner: self)
        callback.pointee.on_resolve_completed = { s, result, addresses in
            cefOwner(ResolveCallback.self, s)?.continuation.resume(returning: (result.rawValue, cefStrings(from: addresses)))
        }
        return callback
    }
}
