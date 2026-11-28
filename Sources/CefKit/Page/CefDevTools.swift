import CCef
import Foundation
import CefBase

/// An error reply from the Chrome DevTools Protocol.
public struct CefDevToolsError: Error, Sendable, Equatable, CustomStringConvertible {
    public var method: String
    public var code: Int
    public var message: String

    /// Creates a value of your own, for previews and tests.
    public init(method: String, code: Int, message: String) {
        self.method = method
        self.code = code
        self.message = message
    }

    public var description: String { "\(method) failed (\(code)): \(message)" }
}

/// Chrome DevTools Protocol access to one page — the same protocol
/// DevTools, Puppeteer and Playwright speak, available in-process with no
/// debugging port.
///
/// ```swift
/// // Emulate a phone, then watch network activity.
/// try await page.devTools.send("Emulation.setDeviceMetricsOverride",
///     ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true])
/// try await page.devTools.send("Network.enable")
/// for await event in page.devTools.events("Network.responseReceived") {
///     print(event["response"]["url"].stringValue ?? "")
/// }
/// ```
///
/// Reference: <https://chromedevtools.github.io/devtools-protocol/>
///
/// The session attaches to the page on the first message and stays
/// attached until the page closes. With no domain enabled, an attached
/// session showed no difference in the readings of
/// `Scripts/compat/probe.html` (CEF 156.0.28, windowed and offscreen
/// hosts). Enabled domains can be seen:
/// `Runtime.enable` makes every `console` call serialize its arguments,
/// which a page can time, and `Debugger.enable` stops the page at its
/// `debugger` statements. Enable what you need and disable it when done.
/// The guide's "Compatibility with bot protection" lists which CefKit
/// features use the protocol.
///
/// CefKit's own features and your app share this one session. Enabling a
/// domain takes a lease on it: `X.disable` turns the domain off only when
/// every `X.enable` sent through the session has been matched by one, so
/// your `Runtime.disable` leaves the domain on for a feature still using
/// it, and the other way round. Each `X.enable` still reaches Chromium, so
/// the newest parameters apply.
///
/// Only this session's events reach ``events(_:bufferingPolicy:)``: a
/// session attached to another target in flat mode (`Target.attachToTarget`
/// with `flatten`, as CefKit does for a moment to ask a cross-site frame
/// about its `beforeunload` listeners) has messages of its own, which are
/// not delivered as this session's.
@MainActor
public final class CefDevTools {
    private weak var page: CefPage?
    private var registration: CefRef<cef_registration_t>?
    /// Calls waiting for their reply; the operation's identifier is the
    /// protocol message's `id`.
    private let pending = CefPendingOperations<Reply>()
    private var listeners: [String: [UUID: @MainActor (CefJSON) -> Void]] = [:]
    /// Counts sessions: a call that suspended across a new session (a
    /// discard) or the page closing starts over or fails.
    private var session = 0

    struct Reply: Sendable {
        var succeeded: Bool
        var result: Data
    }

    init(page: CefPage) {
        self.page = page
    }

    /// Domains enabled through this session (`Network.enable` and the
    /// like), with their latest parameters, in the order they were enabled.
    private var enabledDomains: [(method: String, params: CefJSON)] = []
    /// Unmatched `X.enable` calls, by `X.enable`.
    private var domainLeases: [String: Int] = [:]
    /// Set when the page was discarded by closing it: the next session
    /// enables ``enabledDomains`` again before anything else is sent.
    private var needsDomainReplay = false

    /// Calls a protocol method and returns its result object.
    ///
    /// Waits for the page to be ready (``CefPage/ready()``),
    /// restoring a discarded page first. Throws ``CefDevToolsError``
    /// for an error reply, ``CefError/pageClosed`` when the page
    /// closes first, and `CancellationError` when the calling task is
    /// cancelled; Chromium still runs a call that was already sent.
    @discardableResult
    public func send(_ method: String, _ params: CefJSON = [:]) async throws -> CefJSON {
        try await send(method, params, session: nil)
    }

    /// Calls a protocol method in a session ``send(_:_:)``'s session
    /// attached to (`Target.attachToTarget` with `flatten`), such as an
    /// out-of-process frame's. Domains enabled in it are not leased.
    package func send(_ method: String, _ params: CefJSON = [:], inSession session: String) async throws -> CefJSON {
        try await send(method, params, session: .some(session))
    }

    private func send(_ method: String, _ params: CefJSON, session childSession: String?) async throws -> CefJSON {
        let (page, current) = try await attachedPage()
        if let childSession { return try await deliver(method, params, to: page, session: childSession) }
        if let lease = Self.lease(for: method), lease.isDisable, (domainLeases[lease.enable] ?? 0) > 1 {
            // Another user of the domain still needs it.
            domainLeases[lease.enable, default: 1] -= 1
            return [:]
        }
        let result = try await deliver(method, params, to: page)
        if current == session { recordDomainState(method, params) }
        return result
    }

    /// Calls a method that is not `X.enable` or `X.disable` with
    /// parameters already encoded as a JSON object, and returns the reply
    /// as Chromium sent it: its result is not parsed here.
    func sendEncoded(_ method: String, params: Data) async throws -> Reply {
        let (page, _) = try await attachedPage()
        return try await deliver(method, encodedParams: params, to: page)
    }

    /// The page, ready and attached, and the session it is in.
    private func attachedPage() async throws -> (CefPage, Int) {
        guard let page else { throw CefError.pageClosed }
        // Each suspension can outlive the session: start over in the new
        // one after a discard; fail once the page has closed.
        var current: Int
        repeat {
            try await page.ready()
            current = session
            await enableDomainsAgain(in: page)
            try Task.checkCancellation()
            guard page.state != .closed else { throw CefError.pageClosed }
        } while current != session || page.raw == nil
        attachIfNeeded(to: page)
        return (page, current)
    }

    /// For `X.enable` or `X.disable`, the enable method and which it is.
    static func lease(for method: String) -> (enable: String, isDisable: Bool)? {
        guard let dot = method.lastIndex(of: ".") else { return nil }
        let enable = String(method[..<dot]) + ".enable"
        switch method[method.index(after: dot)...] {
        case "enable": return (enable, false)
        case "disable": return (enable, true)
        default: return nil
        }
    }

    /// How many users hold `domain` (`"Debugger"`, say) enabled.
    package func leaseCount(_ domain: String) -> Int {
        domainLeases[domain + ".enable"] ?? 0
    }

    /// In the session of a page created again after a discard, enables
    /// the domains enabled before. The page does this before it loads
    /// its page; ``send(_:_:)`` does it for a session used earlier.
    func enableDomainsAgain() async {
        guard let page else { return }
        await enableDomainsAgain(in: page)
    }

    private func enableDomainsAgain(in page: CefPage) async {
        // A session that was never used stays unattached.
        guard needsDomainReplay else { return }
        attachIfNeeded(to: page)
        guard registration != nil else { return }
        needsDomainReplay = false
        for domain in enabledDomains {
            _ = try? await deliver(domain.method, domain.params, to: page)
        }
    }

    private func recordDomainState(_ method: String, _ params: CefJSON) {
        guard let lease = Self.lease(for: method) else { return }
        if lease.isDisable {
            domainLeases[lease.enable] = nil
            enabledDomains.removeAll { $0.method == lease.enable }
        } else {
            domainLeases[method, default: 0] += 1
            enabledDomains.removeAll { $0.method == method }
            enabledDomains.append((method, params))
        }
    }

    /// How many protocol messages this session has sent: zero for a page
    /// that nothing has used the protocol in.
    @_spi(Testing) public private(set) var sentMessageCount = 0

    /// Whether the session is attached to the page. Once attached, it
    /// stays attached until the page closes; CEF offers no way to
    /// detach it.
    @_spi(Testing) public var isAttached: Bool { registration != nil }

    private func deliver(
        _ method: String, _ params: CefJSON, to page: CefPage, session: String? = nil
    ) async throws -> CefJSON {
        sentMessageCount += 1
        let reply = try await pending.wait { id in
            var fields: [String: CefJSON] = ["id": .number(Double(id)), "method": .string(method), "params": params]
            if let session { fields["sessionId"] = .string(session) }
            post(CefJSON.object(fields).data, id: id, to: page)
        }
        return try Self.result(of: reply, for: method)
    }

    /// Sends a message whose parameters are JSON text already, spliced in
    /// as they are.
    private func deliver(_ method: String, encodedParams params: Data, to page: CefPage) async throws -> Reply {
        sentMessageCount += 1
        return try await pending.wait { id in
            post(Self.message(id: id, method: method, encodedParams: params), id: id, to: page)
        }
    }

    /// `{"id":…,"method":…,"params":…}` around parameters that are a JSON
    /// object already.
    static func message(id: Int, method: String, encodedParams params: Data) -> Data {
        var message = Data()
        message.reserveCapacity(params.count + method.utf8.count + 40)
        message.append(contentsOf: #"{"id":\#(id),"method":"#.utf8)
        message.append(CefJSON.string(method).data)
        message.append(contentsOf: #","params":"#.utf8)
        message.append(params)
        message.append(UInt8(ascii: "}"))
        return message
    }

    private func post(_ message: Data, id: Int, to page: CefPage) {
        let sent = page.withHost { host in
            message.withUnsafeBytes { host.pointee.send_dev_tools_message(host, $0.baseAddress, $0.count) != 0 }
        }
        if sent != true { pending.complete(id, .failure(CefError.pageClosed)) }
    }

    /// A reply's result object, or the error it reports. A reply that is
    /// not a JSON object is malformed and throws.
    static func result(of reply: Reply, for method: String) throws -> CefJSON {
        let json = try? CefJSON(data: reply.result)
        guard let json, json.objectValue != nil else {
            throw CefError.operationFailed("\(method) returned a malformed reply")
        }
        guard reply.succeeded else {
            throw CefDevToolsError(
                method: method,
                code: json["code"].intValue ?? 0,
                message: json["message"].stringValue ?? "unknown error")
        }
        return json
    }

    /// Calls a protocol method and decodes its result as `Result`, straight
    /// from the reply's bytes.
    public func send<Result: Decodable>(
        _ method: String, _ params: CefJSON = [:], as type: Result.Type
    ) async throws -> Result {
        // Enabling and disabling a domain goes through its lease.
        if Self.lease(for: method) != nil { return try await send(method, params).decode(Result.self) }
        return try Self.decode(Result.self, from: await sendEncoded(method, params: params.data), for: method)
    }

    /// A reply's result decoded as `Result`, or the error it reports.
    static func decode<Result: Decodable>(_ type: Result.Type, from reply: Reply, for method: String) throws -> Result {
        guard reply.succeeded else {
            _ = try result(of: reply, for: method)
            throw CefError.operationFailed("\(method) failed")
        }
        return try JSONDecoder().decode(Result.self, from: reply.result)
    }

    /// How many undelivered events ``events(_:bufferingPolicy:)`` keeps by
    /// default: the newest 1,000, so a consumer that falls behind a busy
    /// domain such as `Network` holds a bounded amount of memory.
    public static let defaultEventBuffering = AsyncStream<CefJSON>.Continuation.BufferingPolicy.bufferingNewest(1_000)

    /// The stream of a protocol event's parameters. Enable the event's
    /// domain first (for example `Network.enable`). The stream ends when the
    /// page closes or the consuming task is cancelled.
    ///
    /// Events arrive faster than a consumer may read them; `bufferingPolicy`
    /// says which to keep meanwhile. Pass `.unbounded` to keep every event.
    public func events(
        _ method: String, bufferingPolicy: AsyncStream<CefJSON>.Continuation.BufferingPolicy = defaultEventBuffering
    ) -> AsyncStream<CefJSON> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let token = addListener(for: method) { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeListener(token, for: method) }
            }
            streams[token] = continuation
        }
    }

    private var streams: [UUID: AsyncStream<CefJSON>.Continuation] = [:]
    /// The listeners of typed event streams, by event method: each decodes
    /// its type from the event's bytes, borrowed for the call. They outlive
    /// a discard, as the streams do.
    var eventDecoders: [String: [UUID: @MainActor (Data) -> Void]] = [:]
    /// Ends each typed event stream, at page close.
    var typedStreamFinishers: [UUID: @MainActor () -> Void] = [:]

    // MARK: Internal listeners

    /// Registers a synchronous event listener. Returns a token for removal.
    package func addListener(for method: String, _ handler: @escaping @MainActor (CefJSON) -> Void) -> UUID {
        let token = UUID()
        listeners[method, default: [:]][token] = handler
        return token
    }

    package func removeListener(_ token: UUID, for method: String) {
        listeners[method]?[token] = nil
        streams[token] = nil
    }

    /// The page was discarded by closing it, and a new Chromium page
    /// takes its place when it is restored. Event streams stay open and
    /// the domains enabled so far are enabled again in the new session.
    /// CefKit's own listeners are dropped: bridges install themselves again.
    func prepareForNewSession() {
        registration = nil
        session += 1
        pending.completeAll(.failure(CefError.pageClosed))
        for method in listeners.keys {
            listeners[method] = listeners[method]?.filter { streams[$0.key] != nil }
        }
        needsDomainReplay = !enabledDomains.isEmpty
    }

    /// Fails outstanding calls and ends event streams. Called at page close.
    func invalidate() {
        registration = nil
        session += 1
        pending.completeAll(.failure(CefError.pageClosed))
        listeners = [:]
        streams.values.forEach { $0.finish() }
        streams = [:]
        eventDecoders = [:]
        typedStreamFinishers.values.forEach { $0() }
        typedStreamFinishers = [:]
    }

    // MARK: Observer

    /// Attaches the observer unless it is attached already.
    private func attachIfNeeded(to page: CefPage) {
        guard registration == nil else { return }
        // add_dev_tools_message_observer takes over the observer reference;
        // the returned registration keeps it installed until released. The
        // observer is made only once there is a host to take it.
        registration = page.withHost { host in
            let observer = DevToolsObserver(devTools: self).makeObserver()
            return CefRef(adopting: host.pointee.add_dev_tools_message_observer(host, observer))
        } ?? nil
    }

    fileprivate func received(result: Data, forMessage id: Int32, succeeded: Bool) {
        pending.complete(Int(id), .success(Reply(succeeded: succeeded, result: result)))
    }

    /// A message of a child session (one with a top-level `sessionId`),
    /// which CEF's typed callbacks do not handle: a reply completes its
    /// call; an event is dropped, so that listeners of this session never
    /// take another session's event for one of its own. Returns whether it
    /// was such a message.
    static let sessionMarker = Data(#""sessionId""#.utf8)

    func receivedChildSessionMessage(_ message: Data) -> Bool {
        guard message.range(of: Self.sessionMarker) != nil, let json = try? CefJSON(data: message),
              json["sessionId"].stringValue != nil
        else { return false }
        if let id = json["id"].intValue {
            let error = json["error"]
            let succeeded = error.isNull
            pending.complete(id, .success(Reply(succeeded: succeeded, result: (succeeded ? json["result"] : error).data)))
        }
        return true
    }

    func received(event method: String, params: Data) {
        params.withUnsafeBytes { received(event: method, params: $0) }
    }

    /// An event, its parameters borrowed for the call. Nothing is copied
    /// or parsed for an event nobody listens to.
    func received(event method: String, params: UnsafeRawBufferPointer) {
        let handlers = listeners[method] ?? [:], decoders = eventDecoders[method] ?? [:]
        guard !handlers.isEmpty || !decoders.isEmpty, let base = params.baseAddress else { return }
        // Parsed before the call returns, so the bytes need no copy.
        let params = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: params.count, deallocator: .none)
        // Typed streams decode their event type straight from the bytes.
        decoders.values.forEach { $0(params) }
        guard !handlers.isEmpty else { return }
        // An event whose parameters are not a JSON object is malformed.
        guard let json = try? CefJSON(data: params), json.objectValue != nil else {
            CefLog.error("devTools: dropped \(method) with malformed parameters")
            return
        }
        handlers.values.forEach { $0(json) }
    }
}

/// Owner of the `cef_dev_tools_message_observer_t`. Callbacks arrive on the
/// UI thread; the message buffers are only valid for the duration of a call.
private final class DevToolsObserver: Sendable {
    private let devToolsReference: CefWeak<CefDevTools>
    private var devTools: CefDevTools? { devToolsReference.object }

    @MainActor
    init(devTools: CefDevTools) {
        devToolsReference = CefWeak(devTools)
    }

    func makeObserver() -> UnsafeMutablePointer<cef_dev_tools_message_observer_t> {
        let observer = cefAllocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { s, page, message, size in
            cefRelease(page)
            guard let message, size > 0, let owner = cefOwner(DevToolsObserver.self, s) else { return 0 }
            // Borrowed for the call: searched in place, copied only to parse.
            let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: message), count: size, deallocator: .none)
            return MainActor.assumeIsolated {
                // Otherwise not consumed: CEF goes on to the typed callbacks below.
                owner.devTools?.receivedChildSessionMessage(bytes) == true ? 1 : 0
            }
        }
        observer.pointee.on_dev_tools_method_result = { s, page, messageID, success, result, size in
            cefRelease(page)
            let data = result.map { Data(bytes: $0, count: size) } ?? Data()
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(result: data, forMessage: messageID, succeeded: success != 0)
            }
        }
        observer.pointee.on_dev_tools_event = { s, page, method, params, size in
            let started = CefDiagnostics.start()
            defer { CefDiagnostics.record(.devToolsEvent, since: started) }
            cefRelease(page)
            let method = CefStringUtil.string(from: method)
            nonisolated(unsafe) let bytes = UnsafeRawBufferPointer(start: params, count: params == nil ? 0 : size)
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(event: method, params: bytes)
            }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, page in cefRelease(page) }
        observer.pointee.on_dev_tools_agent_detached = { _, page in cefRelease(page) }
        return observer
    }
}
