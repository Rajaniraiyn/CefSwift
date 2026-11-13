import CCef
import CefBase
import Foundation
import os

/// One request made with ``CefProfile/data(for:configuration:)`` or
/// ``CefProfile/bytes(for:configuration:)``, and the owner of its
/// `cef_urlrequest_client_t`.
///
/// Everything happens on Chromium's IO thread. `cef_urlrequest_create`
/// needs a thread with a Chromium task runner, calls the client back on
/// the thread that created the request, and only takes `cancel` and the
/// other `cef_urlrequest_t` calls there; `get_auth_credentials` comes on
/// the IO thread whatever the creating thread. Creating requests on the
/// IO thread keeps all of it off the main thread and needs no lock: the
/// loader is isolated to ``CefIOActor``, and CEF's callbacks enter it with
/// `CefIOActor.assumeIsolated`.
///
/// Ownership: the client struct retains the loader; the loader holds the
/// `cef_urlrequest_t` until the request finishes, and CEF holds the
/// client until the `cef_urlrequest_t` goes. Dropping the request when it
/// finishes breaks that cycle, so the census returns to zero.
@CefIOActor
final class URLRequestLoader {
    enum Mode: Sendable {
        /// Collect the body into one `Data`.
        case collect
        /// Hand chunks to a ``CefProfile/ResponseBody``, failing when more
        /// than `limit` bytes are unread.
        case stream(limit: Int)
    }

    /// Why CefKit ended a request.
    enum Stop: Sendable {
        case cancelled
        case timedOut
        case bufferLimit(Int)
        case shutdown

        func error(url: URL) -> any Error {
            switch self {
            case .cancelled: CancellationError()
            case .timedOut: CefLoadError(netError: -7, url: url, detail: "no progress within the request's timeoutInterval")
            case .bufferLimit(let limit):
                CefLoadError(netError: -12, url: url, detail: "more than \(limit) received bytes were not read; raise RequestConfiguration.streamBufferLimit or read faster")
            case .shutdown: CefError.shutDown
            }
        }
    }

    nonisolated let plan: URLRequestPlan
    nonisolated let configuration: CefProfile.RequestConfiguration
    nonisolated let mode: Mode
    nonisolated let buffer = URLRequestStreamBuffer()

    /// Needed only to create the request.
    private var context: CefRef<cef_request_context_t>?
    private var request: CefRef<cef_urlrequest_t>?
    private var stopReason: Stop?
    private var isFinished = false
    private var response: HTTPURLResponse?
    private var lastActivity = ContinuousClock.now
    private var watchdog: Task<Void, Never>?

    // .collect
    private var body = Data()
    private var collector: CheckedContinuation<(Data, HTTPURLResponse), any Error>?

    // .stream
    private var headWaiter: CheckedContinuation<(CefProfile.ResponseBody, HTTPURLResponse), any Error>?
    private var chunks: AsyncThrowingStream<Data, any Error>.Continuation?
    /// The body until it is handed to the caller with the response.
    private var responseBody: CefProfile.ResponseBody?

    nonisolated init(plan: URLRequestPlan, configuration: CefProfile.RequestConfiguration, context: CefRef<cef_request_context_t>, mode: Mode) {
        self.plan = plan
        self.configuration = configuration
        self.context = context
        self.mode = mode
    }

    deinit {
        // CEF released the client without completing the request.
        let error = CefError.operationFailed("Chromium dropped the request to \(plan.url) without finishing it")
        collector?.resume(throwing: error)
        headWaiter?.resume(throwing: error)
        chunks?.finish(throwing: error)
    }

    // MARK: Starting

    func collect() async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector = continuation
                start()
            }
        } onCancel: {
            Task { @CefIOActor in self.halt(.cancelled) }
        }
    }

    func stream() async throws -> (CefProfile.ResponseBody, HTTPURLResponse) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        chunks = continuation
        responseBody = CefProfile.ResponseBody(chunks: stream, buffer: buffer) { [weak self] in
            guard let self else { return }
            Task { @CefIOActor in self.halt(.cancelled) }
        }
        // The caller left the loop early or dropped the body.
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { @CefIOActor in self.halt(.cancelled) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                headWaiter = continuation
                start()
            }
        } onCancel: {
            Task { @CefIOActor in self.halt(.cancelled) }
        }
    }

    private func start() {
        // Ended before it started: quitting halted it on the IO thread.
        if isFinished { return deliver(.failure((stopReason ?? .shutdown).error(url: plan.url))) }
        if Task.isCancelled { return finish(.failure(CancellationError())) }
        guard let context, CefThreadExecutor.io.isOnChromium else {
            return finish(.failure(CefError.shutDown))
        }
        self.context = nil
        // cef_urlrequest_create consumes the request, the client and the
        // context reference.
        let created = cef_urlrequest_create(makeRequest(), makeClient(), context.retainedPointer())
        guard let created else {
            return finish(.failure(CefLoadError(netError: -2, url: plan.url, detail: "Chromium did not start the request")))
        }
        if isFinished {
            cefRelease(created)
        } else {
            request = CefRef(adopting: created)
            if let timeout = plan.idleTimeout { startWatchdog(timeout) }
        }
    }

    /// A `cef_request_t` for the plan, with the caller's reference.
    private func makeRequest() -> UnsafeMutablePointer<cef_request_t> {
        guard let request = cef_request_create() else { fatalError("CefSwift: cef_request_create returned NULL") }
        let r = request.pointee
        CefStringUtil.withCefString(plan.url.absoluteString) { r.set_url(request, $0) }
        CefStringUtil.withCefString(plan.method) { r.set_method(request, $0) }
        if !plan.headers.isEmpty {
            withCefStringMultimap(plan.headers.lazy.map { (name: $0.name, value: $0.value) }) { r.set_header_map(request, $0) }
        }
        if let referrer = plan.referrer {
            CefStringUtil.withCefString(referrer.absoluteString) { r.set_referrer(request, $0, REFERRER_POLICY_DEFAULT) }
        }
        CefStringUtil.withCefString(plan.siteForCookies.absoluteString) { r.set_first_party_for_cookies(request, $0) }
        if let body = plan.body, let postData = cef_post_data_create() {
            if let element = cef_post_data_element_create() {
                switch body {
                case .bytes(let data):
                    data.withUnsafeBytes { element.pointee.set_to_bytes(element, $0.count, $0.baseAddress) }
                case .file(let url):
                    CefStringUtil.withCefString(url.path) { element.pointee.set_to_file(element, $0) }
                }
                _ = postData.pointee.add_element(postData, element)
            }
            r.set_post_data(request, postData)
        }
        r.set_flags(request, plan.flags)
        return request
    }

    private func startWatchdog(_ timeout: Duration) {
        watchdog = Task { [weak self] in
            while let deadline = self?.idleDeadline(timeout) {
                if ContinuousClock.now >= deadline {
                    self?.halt(.timedOut)
                    return
                }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
    }

    private func idleDeadline(_ timeout: Duration) -> ContinuousClock.Instant? {
        isFinished ? nil : lastActivity + timeout
    }

    // MARK: Progress

    /// Ends the request early. Safe to call any number of times.
    func halt(_ reason: Stop) {
        guard !isFinished, stopReason == nil else { return }
        stopReason = reason
        if let request, CefThreadExecutor.io.isOnChromium {
            // May complete the request at once.
            request.pointer.pointee.cancel(request.pointer)
        }
        finish(.failure(reason.error(url: plan.url)))
    }

    /// Reads the response from `request` the first time it is there. Called
    /// from CEF's callbacks on the IO thread; only the parsed response
    /// enters the actor.
    private nonisolated func receiveHeadIfNeeded(from request: UnsafeMutablePointer<cef_urlrequest_t>) {
        guard !CefIOActor.assumeIsolated({ self.response != nil }),
              let head = Self.response(of: request, fallbackURL: plan.url)
        else { return }
        CefIOActor.assumeIsolated { if self.response == nil { self.didReceive(head) } }
    }

    private func didReceive(_ head: HTTPURLResponse) {
        response = head
        switch mode {
        case .collect:
            // One copy of each chunk: into a buffer of the announced size.
            let expected = head.expectedContentLength
            if expected > 0 { body.reserveCapacity(Int(min(expected, 256 << 20))) }
        case .stream:
            if let waiter = headWaiter, let responseBody {
                headWaiter = nil
                self.responseBody = nil
                waiter.resume(returning: (responseBody, head))
            }
        }
    }

    private func receive(_ bytes: UnsafeRawBufferPointer) {
        guard !isFinished, let base = bytes.baseAddress, bytes.count > 0 else { return }
        lastActivity = .now
        switch mode {
        case .collect:
            body.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        case .stream(let limit):
            let chunk = Data(bytes: base, count: bytes.count)
            let unread = buffer.received(chunk.count)
            chunks?.yield(chunk)
            if unread > limit { halt(.bufferLimit(limit)) }
        }
    }

    private func didProgress(upload: Bool, _ current: Int64, _ total: Int64) {
        lastActivity = .now
        guard let report = upload ? configuration.uploadProgress : configuration.downloadProgress else { return }
        report(CefProfile.TransferProgress(completed: current, total: total >= 0 ? total : nil))
    }

    private func complete(status: cef_urlrequest_status_t, error: Int) {
        if let stopReason { return finish(.failure(stopReason.error(url: plan.url))) }
        if status == UR_SUCCESS, let response { return finish(.success(response)) }
        // A redirect Chromium stopped at, as asked: the 3xx is the answer.
        if configuration.stopsAtRedirects, let response, (300..<400).contains(response.statusCode) {
            return finish(.success(response))
        }
        let code = status == UR_SUCCESS ? -320 : (error == 0 ? -2 : error)  // INVALID_RESPONSE, FAILED
        finish(.failure(CefLoadError(netError: code, url: plan.url)))
    }

    private func finish(_ result: Result<HTTPURLResponse, any Error>) {
        guard !isFinished else { return }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        // The loader's CEF references go here, on the IO thread.
        context = nil
        request = nil
        URLRequestRegistry.shared.remove(self)
        deliver(result)
    }

    /// Hands `result` to whoever waits for the request.
    private func deliver(_ result: Result<HTTPURLResponse, any Error>) {
        switch result {
        case .success(let head):
            let data = body
            body = Data()
            collector?.resume(returning: (data, head))
            // An empty body: no chunk brought the head.
            if let waiter = headWaiter, let responseBody { waiter.resume(returning: (responseBody, head)) }
            chunks?.finish()
        case .failure(let error):
            collector?.resume(throwing: error)
            headWaiter?.resume(throwing: error)
            chunks?.finish(throwing: error)
        }
        collector = nil
        headWaiter = nil
        chunks = nil
        responseBody = nil
    }

    // MARK: CEF client

    /// The client, with the caller's reference. Nonisolated, so that the
    /// closures in it are too: each enters the actor with `assumeIsolated`.
    private nonisolated func makeClient() -> UnsafeMutablePointer<cef_urlrequest_client_t> {
        let client = cefAllocate(cef_urlrequest_client_t.self, owner: self)
        client.pointee.on_request_complete = { s, request in
            let request = CefOwned(request)
            guard let loader = cefOwner(URLRequestLoader.self, s), let request else { return }
            let pointer = request.pointer
            let status = pointer.pointee.get_request_status(pointer)
            let error = Int(pointer.pointee.get_request_error(pointer).rawValue)
            loader.receiveHeadIfNeeded(from: pointer)
            CefIOActor.assumeIsolated { loader.complete(status: status, error: error) }
        }
        client.pointee.on_upload_progress = { s, request, current, total in
            cefRelease(request)
            guard let loader = cefOwner(URLRequestLoader.self, s) else { return }
            CefIOActor.assumeIsolated { loader.didProgress(upload: true, current, total) }
        }
        client.pointee.on_download_progress = { s, request, current, total in
            let request = CefOwned(request)
            guard let loader = cefOwner(URLRequestLoader.self, s), let request else { return }
            loader.receiveHeadIfNeeded(from: request.pointer)
            CefIOActor.assumeIsolated { loader.didProgress(upload: false, current, total) }
        }
        client.pointee.on_download_data = { s, request, data, length in
            let request = CefOwned(request)
            guard let loader = cefOwner(URLRequestLoader.self, s), let request, let data else { return }
            loader.receiveHeadIfNeeded(from: request.pointer)
            // CEF's buffer, valid for this call; `receive` copies it before
            // returning, and assumeIsolated runs it synchronously, here.
            nonisolated(unsafe) let bytes = UnsafeRawBufferPointer(start: data, count: length)
            CefIOActor.assumeIsolated { loader.receive(bytes) }
        }
        client.pointee.get_auth_credentials = { s, isProxy, host, port, realm, scheme, callback in
            let callback = CefRef(adopting: callback)
            guard let loader = cefOwner(URLRequestLoader.self, s), let callback else { return 0 }
            guard let answer = loader.configuration.credential else {
                // No credentials: the challenge's own response is the answer.
                callback.pointer.pointee.cancel(callback.pointer)
                return 1
            }
            let challenge = CefAuthenticationChallenge(
                url: loader.plan.url, isProxy: isProxy != 0,
                host: CefStringUtil.string(from: host), port: Int(port),
                realm: CefStringUtil.string(from: realm), scheme: CefStringUtil.string(from: scheme))
            Task {
                let credential = await answer(challenge)
                await URLRequestLoader.answer(callback, with: credential)
            }
            return 1
        }
        return client
    }

    private static func answer(_ callback: CefRef<cef_auth_callback_t>, with credential: CefCredential?) {
        guard CefThreadExecutor.io.isOnChromium else { return }
        let pointer = callback.pointer
        guard let credential else { return pointer.pointee.cancel(pointer) }
        CefStringUtil.withCefString(credential.username) { user in
            CefStringUtil.withCefString(credential.password) { password in pointer.pointee.cont(pointer, user, password) }
        }
    }

    /// The response of `request`, once its headers have arrived.
    nonisolated static func response(of request: UnsafeMutablePointer<cef_urlrequest_t>, fallbackURL: URL) -> HTTPURLResponse? {
        guard let cefResponse = CefOwned(request.pointee.get_response(request)) else { return nil }
        let r = cefResponse.pointer
        let status = Int(r.pointee.get_status(r))
        guard status > 0 else { return nil }
        let url = CefStringUtil.takingUserFree(r.pointee.get_url(r)).flatMap { URL(string: $0) } ?? fallbackURL
        let headers = cefHeaderFields { r.pointee.get_header_map(r, $0) }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    }
}

/// The requests in flight, from the moment a loader takes a request
/// context reference, so that quitting can end them while Chromium still
/// runs.
final class URLRequestRegistry: Sendable {
    static let shared = URLRequestRegistry()

    private struct State {
        var isClosed = false
        var loaders: [ObjectIdentifier: URLRequestLoader] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Adds a new loader; `false` once Chromium is shutting down.
    func insert(_ loader: URLRequestLoader) -> Bool {
        state.withLock { state in
            guard !state.isClosed else { return false }
            state.loaders[ObjectIdentifier(loader)] = loader
            return true
        }
    }

    func remove(_ loader: URLRequestLoader) {
        _ = state.withLock { $0.loaders.removeValue(forKey: ObjectIdentifier(loader)) }
    }

    /// How many requests are in flight.
    var count: Int { state.withLock { $0.loaders.count } }

    /// No new requests start; those in flight are cancelled on the IO
    /// thread. Returns once each has cancelled its `cef_urlrequest_t` and
    /// released its CEF references there, so Chromium can shut down after
    /// it; their callers get ``CefError/shutDown``. Suspends rather than
    /// blocks: the main thread keeps running Chromium's message loop.
    func drainForShutdown() async {
        let loaders = close()
        guard !loaders.isEmpty else { return }
        await Self.halt(loaders)
        // Callers awaiting on the IO actor resume there first; a second,
        // empty job runs after them, so they have handed their errors on
        // to their own callers before this returns.
        await Self.afterQueuedJobs()
    }

    /// Chromium is about to shut down: no new requests start, and any
    /// still in flight (a drain that timed out) are cancelled on the IO
    /// thread without waiting.
    func cancelAllForShutdown() {
        let loaders = close()
        guard !loaders.isEmpty else { return }
        Task { await Self.halt(loaders) }
    }

    private func close() -> [URLRequestLoader] {
        state.withLock { state in
            state.isClosed = true
            return Array(state.loaders.values)
        }
    }

    @CefIOActor private static func afterQueuedJobs() {}

    @CefIOActor private static func halt(_ loaders: [URLRequestLoader]) {
        for loader in loaders { loader.halt(.shutdown) }
    }
}
