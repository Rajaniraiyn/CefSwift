import CCef
import Foundation
import CefBase

/// An error reply from the Chrome DevTools Protocol.
public struct CefDevToolsError: Error, Sendable, Equatable, CustomStringConvertible {
    public var method: String
    public var code: Int
    public var message: String

    public var description: String { "\(method) failed (\(code)): \(message)" }
}

/// Chrome DevTools Protocol access to one browser — the same protocol
/// DevTools, Puppeteer and Playwright speak, available in-process with no
/// debugging port.
///
/// ```swift
/// // Emulate a phone, then watch network activity.
/// try await browser.devTools.send("Emulation.setDeviceMetricsOverride",
///     ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true])
/// try await browser.devTools.send("Network.enable")
/// for await event in browser.devTools.events("Network.responseReceived") {
///     print(event["response"]["url"].stringValue ?? "")
/// }
/// ```
///
/// Reference: <https://chromedevtools.github.io/devtools-protocol/>
///
/// The session attaches to the browser on the first message and stays
/// attached until the browser closes. With no domain enabled, an attached
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
@MainActor
public final class CefDevTools {
    private weak var browser: CefBrowser?
    private var registration: CefRef<cef_registration_t>?
    /// Calls waiting for their reply; the operation's identifier is the
    /// protocol message's `id`.
    private let pending = CefPendingOperations<Reply>()
    private var listeners: [String: [UUID: @MainActor (CefJSON) -> Void]] = [:]
    /// Counts sessions: a call that suspended across a new session (a
    /// discard) or the browser closing starts over or fails.
    private var session = 0

    struct Reply: Sendable {
        var succeeded: Bool
        var result: Data
    }

    init(browser: CefBrowser) {
        self.browser = browser
    }

    /// Domains enabled through this session (`Network.enable` and the
    /// like), with their latest parameters, in the order they were enabled.
    private var enabledDomains: [(method: String, params: CefJSON)] = []
    /// Unmatched `X.enable` calls, by `X.enable`.
    private var domainLeases: [String: Int] = [:]
    /// Set when the browser was discarded by closing it: the next session
    /// enables ``enabledDomains`` again before anything else is sent.
    private var needsDomainReplay = false

    /// Calls a protocol method and returns its result object.
    ///
    /// Waits for the browser to be ready (``CefBrowser/ready()``),
    /// restoring a discarded browser first. Throws ``CefDevToolsError``
    /// for an error reply, ``CefError/browserClosed`` when the browser
    /// closes first, and `CancellationError` when the calling task is
    /// cancelled; Chromium still runs a call that was already sent.
    @discardableResult
    public func send(_ method: String, _ params: CefJSON = [:]) async throws -> CefJSON {
        guard let browser else { throw CefError.browserClosed }
        // Each suspension can outlive the session: start over in the new
        // one after a discard; fail once the browser has closed.
        var current: Int
        repeat {
            try await browser.ready()
            current = session
            await enableDomainsAgain(in: browser)
            try Task.checkCancellation()
            guard browser.state != .closed else { throw CefError.browserClosed }
        } while current != session || browser.raw == nil
        attachIfNeeded(to: browser)
        if let lease = Self.lease(for: method), lease.isDisable, (domainLeases[lease.enable] ?? 0) > 1 {
            // Another user of the domain still needs it.
            domainLeases[lease.enable, default: 1] -= 1
            return [:]
        }
        let result = try await deliver(method, params, to: browser)
        if current == session { recordDomainState(method, params) }
        return result
    }

    /// For `X.enable` or `X.disable`, the enable method and which it is.
    private static func lease(for method: String) -> (enable: String, isDisable: Bool)? {
        guard let dot = method.lastIndex(of: ".") else { return nil }
        let enable = String(method[..<dot]) + ".enable"
        switch method[method.index(after: dot)...] {
        case "enable": return (enable, false)
        case "disable": return (enable, true)
        default: return nil
        }
    }

    /// How many users hold `domain` (`"Debugger"`, say) enabled.
    func leaseCount(_ domain: String) -> Int {
        domainLeases[domain + ".enable"] ?? 0
    }

    /// In the session of a browser created again after a discard, enables
    /// the domains enabled before. The browser does this before it loads
    /// its page; ``send(_:_:)`` does it for a session used earlier.
    func enableDomainsAgain() async {
        guard let browser else { return }
        await enableDomainsAgain(in: browser)
    }

    private func enableDomainsAgain(in browser: CefBrowser) async {
        // A session that was never used stays unattached.
        guard needsDomainReplay else { return }
        attachIfNeeded(to: browser)
        guard registration != nil else { return }
        needsDomainReplay = false
        for domain in enabledDomains {
            _ = try? await deliver(domain.method, domain.params, to: browser)
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

    /// How many protocol messages this session has sent: zero for a browser
    /// that nothing has used the protocol in.
    @_spi(Testing) public private(set) var sentMessageCount = 0

    /// Whether the session is attached to the browser. Once attached, it
    /// stays attached until the browser closes; CEF offers no way to
    /// detach it.
    @_spi(Testing) public var isAttached: Bool { registration != nil }

    private func deliver(_ method: String, _ params: CefJSON, to browser: CefBrowser) async throws -> CefJSON {
        sentMessageCount += 1
        let reply = try await pending.wait { id in
            let message = CefJSON.object(["id": .number(Double(id)), "method": .string(method), "params": params]).data
            let sent = browser.withHost { host in
                message.withUnsafeBytes { host.pointee.send_dev_tools_message(host, $0.baseAddress, $0.count) != 0 }
            }
            if sent != true { pending.complete(id, .failure(CefError.browserClosed)) }
        }
        return try Self.result(of: reply, for: method)
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

    /// Calls a protocol method and decodes its result as `Result`.
    public func send<Result: Decodable>(
        _ method: String, _ params: CefJSON = [:], as type: Result.Type
    ) async throws -> Result {
        try await send(method, params).decode(Result.self)
    }

    /// How many undelivered events ``events(_:bufferingPolicy:)`` keeps by
    /// default: the newest 1,000, so a consumer that falls behind a busy
    /// domain such as `Network` holds a bounded amount of memory.
    public static let defaultEventBuffering = AsyncStream<CefJSON>.Continuation.BufferingPolicy.bufferingNewest(1_000)

    /// The stream of a protocol event's parameters. Enable the event's
    /// domain first (for example `Network.enable`). The stream ends when the
    /// browser closes or the consuming task is cancelled.
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

    // MARK: Internal listeners

    /// Registers a synchronous event listener. Returns a token for removal.
    func addListener(for method: String, _ handler: @escaping @MainActor (CefJSON) -> Void) -> UUID {
        let token = UUID()
        listeners[method, default: [:]][token] = handler
        return token
    }

    func removeListener(_ token: UUID, for method: String) {
        listeners[method]?[token] = nil
        streams[token] = nil
    }

    /// The browser was discarded by closing it, and a new Chromium browser
    /// takes its place when it is restored. Event streams stay open and
    /// the domains enabled so far are enabled again in the new session.
    /// CefKit's own listeners are dropped: bridges install themselves again.
    func prepareForNewSession() {
        registration = nil
        session += 1
        pending.completeAll(.failure(CefError.browserClosed))
        for method in listeners.keys {
            listeners[method] = listeners[method]?.filter { streams[$0.key] != nil }
        }
        needsDomainReplay = !enabledDomains.isEmpty
    }

    /// Fails outstanding calls and ends event streams. Called at browser close.
    func invalidate() {
        registration = nil
        session += 1
        pending.completeAll(.failure(CefError.browserClosed))
        listeners = [:]
        streams.values.forEach { $0.finish() }
        streams = [:]
    }

    // MARK: Observer

    /// Attaches the observer unless it is attached already.
    private func attachIfNeeded(to browser: CefBrowser) {
        guard registration == nil else { return }
        let observer = DevToolsObserver(devTools: self).makeObserver()
        // add_dev_tools_message_observer takes over the observer reference;
        // the returned registration keeps it installed until released.
        registration = browser.withHost { host in
            CefRef(adopting: host.pointee.add_dev_tools_message_observer(host, observer))
        } ?? nil
    }

    fileprivate func received(result: Data, forMessage id: Int32, succeeded: Bool) {
        pending.complete(Int(id), .success(Reply(succeeded: succeeded, result: result)))
    }

    func received(event method: String, params: Data) {
        params.withUnsafeBytes { received(event: method, params: $0) }
    }

    /// An event, its parameters borrowed for the call. Nothing is copied
    /// or parsed for an event nobody listens to.
    func received(event method: String, params: UnsafeRawBufferPointer) {
        guard let handlers = listeners[method], !handlers.isEmpty, let base = params.baseAddress else { return }
        // Parsed before the call returns, so the bytes need no copy.
        let params = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: params.count, deallocator: .none)
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
    private weak let devTools: CefDevTools?

    @MainActor
    init(devTools: CefDevTools) {
        self.devTools = devTools
    }

    func makeObserver() -> UnsafeMutablePointer<cef_dev_tools_message_observer_t> {
        let observer = cefAllocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { _, browser, _, _ in
            cefRelease(browser)
            return 0  // not consumed: CEF goes on to the typed callbacks below
        }
        observer.pointee.on_dev_tools_method_result = { s, browser, messageID, success, result, size in
            let started = CefDiagnostics.start()
            defer { CefDiagnostics.record(.devToolsResult, since: started) }
            cefRelease(browser)
            let data = result.map { Data(bytes: $0, count: size) } ?? Data()
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(result: data, forMessage: messageID, succeeded: success != 0)
            }
        }
        observer.pointee.on_dev_tools_event = { s, browser, method, params, size in
            let started = CefDiagnostics.start()
            defer { CefDiagnostics.record(.devToolsEvent, since: started) }
            cefRelease(browser)
            let method = CefStringUtil.string(from: method)
            nonisolated(unsafe) let bytes = UnsafeRawBufferPointer(start: params, count: params == nil ? 0 : size)
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(event: method, params: bytes)
            }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in cefRelease(browser) }
        observer.pointee.on_dev_tools_agent_detached = { _, browser in cefRelease(browser) }
        return observer
    }
}
