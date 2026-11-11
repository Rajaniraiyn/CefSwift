import CCef
import Foundation

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
@MainActor
public final class CefDevTools {
    private weak var browser: CefBrowser?
    private var registration: CefRef<cef_registration_t>?
    private var nextMessageID: Int32 = 0
    private var pending: [Int32: (method: String, continuation: CheckedContinuation<CefJSON, Error>)] = [:]
    private var listeners: [String: [UUID: @MainActor (CefJSON) -> Void]] = [:]

    init(browser: CefBrowser) {
        self.browser = browser
    }

    /// Calls a protocol method and returns its result object.
    ///
    /// Waits for the browser to be created if it is still pending.
    @discardableResult
    public func send(_ method: String, _ params: CefJSON = [:]) async throws -> CefJSON {
        guard let browser else { throw CefError.browserClosed }
        try await browser.ready()
        attachIfNeeded(to: browser)

        nextMessageID += 1
        let id = nextMessageID
        let message = CefJSON.object(["id": .number(Double(id)), "method": .string(method), "params": params]).data

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            let sent = browser.withHost { host in
                message.withUnsafeBytes { host.pointee.send_dev_tools_message(host, $0.baseAddress, $0.count) != 0 }
            }
            if sent != true {
                pending[id] = nil
                continuation.resume(throwing: CefError.browserClosed)
            }
        }
    }

    /// Calls a protocol method and decodes its result as `Result`.
    public func send<Result: Decodable>(
        _ method: String, _ params: CefJSON = [:], as type: Result.Type
    ) async throws -> Result {
        try await send(method, params).decode(Result.self)
    }

    /// The stream of a protocol event's parameters. Enable the event's
    /// domain first (for example `Network.enable`). The stream ends when the
    /// browser closes or the consuming task is cancelled.
    public func events(_ method: String) -> AsyncStream<CefJSON> {
        AsyncStream { continuation in
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
    @discardableResult
    func addListener(for method: String, _ handler: @escaping @MainActor (CefJSON) -> Void) -> UUID {
        let token = UUID()
        listeners[method, default: [:]][token] = handler
        return token
    }

    func removeListener(_ token: UUID, for method: String) {
        listeners[method]?[token] = nil
        streams[token] = nil
    }

    /// Fails outstanding calls and ends event streams. Called at browser close.
    func invalidate() {
        registration = nil
        pending.values.forEach { $0.continuation.resume(throwing: CefError.browserClosed) }
        pending = [:]
        listeners = [:]
        streams.values.forEach { $0.finish() }
        streams = [:]
    }

    // MARK: Observer

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
        guard let (method, continuation) = pending.removeValue(forKey: id) else { return }
        let json = (try? CefJSON(data: result)) ?? .null
        if succeeded {
            continuation.resume(returning: json)
        } else {
            continuation.resume(throwing: CefDevToolsError(
                method: method,
                code: json["code"].intValue ?? 0,
                message: json["message"].stringValue ?? "unknown error"))
        }
    }

    fileprivate func received(event method: String, params: Data) {
        guard let handlers = listeners[method], !handlers.isEmpty else { return }
        let json = (try? CefJSON(data: params)) ?? .null
        handlers.values.forEach { $0(json) }
    }
}

/// Owner of the `cef_dev_tools_message_observer_t`. Callbacks arrive on the
/// UI thread; the message buffers are only valid for the duration of a call.
private final class DevToolsObserver: @unchecked Sendable {
    private weak var devTools: CefDevTools?

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
            cefRelease(browser)
            let data = result.map { Data(bytes: $0, count: size) } ?? Data()
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(result: data, forMessage: messageID, succeeded: success != 0)
            }
        }
        observer.pointee.on_dev_tools_event = { s, browser, method, params, size in
            cefRelease(browser)
            let method = CefStringUtil.string(from: method)
            let data = params.map { Data(bytes: $0, count: size) } ?? Data()
            guard let owner = cefOwner(DevToolsObserver.self, s) else { return }
            MainActor.assumeIsolated {
                owner.devTools?.received(event: method, params: data)
            }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in cefRelease(browser) }
        observer.pointee.on_dev_tools_agent_detached = { _, browser in cefRelease(browser) }
        return observer
    }
}
