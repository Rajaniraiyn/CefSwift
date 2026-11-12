import Foundation

/// A typed, promise-based API your Swift code exposes to JavaScript.
///
/// Declare methods in Swift, attach the bridge to a browser, and call them
/// from the page as ordinary async functions on a global object:
///
/// ```swift
/// struct Person: Codable { var name: String }
///
/// let bridge = CefBridge(name: "app")
/// bridge.handle("greet") { (person: Person) in
///     "Hello, \(person.name)!"
/// }
///
/// var options = CefBrowserOptions()
/// options.bridges = [bridge]
/// let browser = CefBrowser(url: appURL, options: options)
/// ```
///
/// ```js
/// const reply = await app.greet({ name: "Ada" });   // "Hello, Ada!"
/// app.on("themeChanged", theme => applyTheme(theme));
/// ```
///
/// The global exists before any page script runs. Arguments and results
/// travel as JSON, so any `Codable` type works on the Swift side. A handler
/// that throws rejects the promise.
///
/// **Who may call.** Handlers run with your app's privileges, so the bridge
/// only exists where ``access`` permits — by default in the top-level page,
/// never in embedded frames. A bridge for your own pages in a browser that
/// also shows the web is limited to their origin; other pages never see the
/// global:
///
/// ```swift
/// bridge.access = .origins(["app://start"])
/// ```
///
/// Calls are checked again in Swift against the caller's origin and frame
/// as Chromium reports them, which a page cannot forge; each handler can
/// also inspect ``CefBridgeCall/origin``.
@MainActor
public final class CefBridge {

    /// Which documents get the bridge and may call it.
    public enum Access: Sendable, Equatable {
        /// Only top-level documents (the default).
        case mainFrame
        /// Documents, in any frame, whose origin is listed, e.g.
        /// `"https://app.example.com"` or `"app://start"`.
        case origins(Set<String>)
        /// Every frame of every page. Use only for browsers that load
        /// nothing but your own content.
        case anyFrame
    }

    /// The name of the JavaScript global, e.g. `"app"` for `window.app`.
    public let name: String

    /// Which documents get the bridge and may call it. A document outside
    /// it has no global; a change applies to calls from then on and to
    /// documents loaded afterwards.
    public var access: Access = .mainFrame {
        didSet {
            guard access != oldValue else { return }
            sessions = sessions.filter { $0.value.browser?.state == .live }
            for session in sessions.values { Task { await reinject(into: session) } }
        }
    }

    private typealias Handler = @MainActor (CefJSON, CefBridgeCall) async throws -> CefJSON
    private var handlers: [String: Handler] = [:]
    private var sessions: [ObjectIdentifier: Session] = [:]

    /// - Parameter name: A JavaScript identifier for the global object.
    public init(name: String = "native") {
        precondition(
            name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil,
            "CefBridge name must be a JavaScript identifier, got '\(name)'.")
        self.name = name
    }

    // MARK: Declaring methods

    /// Exposes `method` to JavaScript. The call's argument is decoded as
    /// `Input`; the returned value is encoded as the promise's result.
    public func handle<Input: Decodable, Output: Encodable>(
        _ method: String,
        _ handler: @escaping @MainActor (Input, CefBridgeCall) async throws -> Output
    ) {
        handlers[method] = { arguments, call in
            try CefJSON(encoding: await handler(arguments.decode(Input.self), call))
        }
    }

    /// Exposes `method` to JavaScript, ignoring who is calling.
    public func handle<Input: Decodable, Output: Encodable>(
        _ method: String,
        _ handler: @escaping @MainActor (Input) async throws -> Output
    ) {
        handle(method) { (input: Input, _: CefBridgeCall) in try await handler(input) }
    }

    /// Exposes a `method` that returns nothing; its promise resolves to `null`.
    public func handle<Input: Decodable>(
        _ method: String,
        _ handler: @escaping @MainActor (Input, CefBridgeCall) async throws -> Void
    ) {
        handlers[method] = { arguments, call in
            try await handler(arguments.decode(Input.self), call)
            return .null
        }
    }

    /// Exposes a `method` that returns nothing, ignoring who is calling.
    public func handle<Input: Decodable>(
        _ method: String,
        _ handler: @escaping @MainActor (Input) async throws -> Void
    ) {
        handle(method) { (input: Input, _: CefBridgeCall) in try await handler(input) }
    }

    /// Stops exposing `method`.
    public func removeHandler(for method: String) {
        handlers[method] = nil
    }

    // MARK: Events

    /// Delivers an event to listeners registered with `<name>.on(event, fn)`
    /// in the top-level page of `browser` — or of every browser this bridge
    /// is attached to when `browser` is nil.
    public func emit(_ event: String, _ payload: some Encodable = CefJSON.null, to browser: CefBrowser? = nil) {
        guard let payload = try? CefJSON(encoding: payload) else {
            CefLog.error("CefBridge.emit(\(event)): payload is not JSON-encodable")
            return
        }
        let expression = "globalThis.\(emitFunction)?.(\(CefJSON.string(event).text), \(payload.text))"
        sessions = sessions.filter { $0.value.browser?.state == .live }
        // A discarded page is gone; its next document starts afresh.
        for session in sessions.values where (browser == nil || session.browser === browser)
            && session.browser?.isDiscarded == false {
            session.browser?.executeJavaScript(expression)
        }
    }

    // MARK: Installation

    /// Wires the bridge into `browser`. Called while the browser bootstraps,
    /// before its first real navigation.
    func install(in browser: CefBrowser) async throws {
        let session = Session(browser: browser)
        sessions[ObjectIdentifier(browser)] = session
        let devTools = browser.devTools

        devTools.addListener(for: "Runtime.executionContextCreated") { [weak session] event in
            let context = event["context"]
            guard let id = context["id"].intValue else { return }
            session?.contexts[id] = Session.Context(
                origin: context["origin"].stringValue ?? "",
                frameID: context["auxData"]["frameId"].stringValue ?? "",
                isDefault: context["auxData"]["isDefault"].boolValue ?? false)
        }
        devTools.addListener(for: "Runtime.executionContextDestroyed") { [weak session] event in
            if let id = event["executionContextId"].intValue { session?.contexts[id] = nil }
        }
        devTools.addListener(for: "Runtime.executionContextsCleared") { [weak session] _ in
            session?.contexts = [:]
        }
        devTools.addListener(for: "Page.frameNavigated") { [weak session] event in
            let frame = event["frame"]
            if frame["parentId"].isNull, let id = frame["id"].stringValue { session?.mainFrameID = id }
        }
        devTools.addListener(for: "Runtime.bindingCalled") { [weak self, weak session] event in
            guard let self, let session, event["name"].stringValue == self.bindingName else { return }
            self.received(event, in: session)
        }

        try await devTools.send("Page.enable")
        session.mainFrameID = try await devTools.send("Page.getFrameTree")["frameTree"]["frame"]["id"].stringValue ?? ""
        try await devTools.send("Runtime.enable")
        try await devTools.send("Runtime.addBinding", ["name": .string(bindingName)])
        session.scriptID = try await devTools.send(
            "Page.addScriptToEvaluateOnNewDocument", ["source": .string(shim)])["identifier"].stringValue
    }

    /// Replaces the document-start script after ``access`` changed.
    private func reinject(into session: Session) async {
        guard let browser = session.browser else { return }
        if let scriptID = session.scriptID {
            _ = try? await browser.devTools.send("Page.removeScriptToEvaluateOnNewDocument", ["identifier": .string(scriptID)])
        }
        session.scriptID = try? await browser.devTools.send(
            "Page.addScriptToEvaluateOnNewDocument", ["source": .string(shim)])["identifier"].stringValue
    }

    // MARK: Dispatch

    private func received(_ event: CefJSON, in session: Session) {
        guard let contextID = event["executionContextId"].intValue,
              let payload = event["payload"].stringValue,
              let message = try? CefJSON(data: Data(payload.utf8)),
              let callID = message["id"].intValue,
              let method = message["method"].stringValue,
              let browser = session.browser
        else { return }

        func reply(ok: Bool, _ value: CefJSON) {
            let expression = "globalThis.\(replyFunction)?.(\(callID), \(ok), \(value.text))"
            Task {
                _ = try? await browser.devTools.send(
                    "Runtime.evaluate", ["expression": .string(expression), "contextId": .number(Double(contextID))])
            }
        }

        // An unknown context means the frame is already gone; nothing to answer.
        guard let context = session.contexts[contextID] else { return }
        let call = CefBridgeCall(
            browser: browser, method: method, origin: context.origin,
            isMainFrame: context.frameID == session.mainFrameID)

        guard context.isDefault, isPermitted(call) else {
            reply(ok: false, .string("\(name).\(method): caller is not permitted to use this bridge"))
            return
        }
        guard let handler = handlers[method] else {
            reply(ok: false, .string("\(name).\(method) is not defined"))
            return
        }
        Task {
            do {
                reply(ok: true, try await handler(message["args"], call))
            } catch {
                reply(ok: false, .string(String(describing: error)))
            }
        }
    }

    private func isPermitted(_ call: CefBridgeCall) -> Bool {
        switch access {
        case .mainFrame: return call.isMainFrame
        case .origins(let allowed): return allowed.contains(call.origin)
        case .anyFrame: return true
        }
    }

    // MARK: JavaScript side

    private var bindingName: String { "__cefswift_\(name)" }
    private var replyFunction: String { "__cefswift_\(name)_reply" }
    private var emitFunction: String { "__cefswift_\(name)_emit" }

    /// Whether a document gets the global, by the same rule as
    /// ``isPermitted(_:)``; a JavaScript expression.
    private var installCondition: String {
        switch access {
        case .mainFrame:
            return "globalThis === globalThis.top"
        case .origins(let allowed):
            return "\(CefJSON.array(allowed.sorted().map(CefJSON.string)).text).includes(location.origin)"
        case .anyFrame:
            return "true"
        }
    }

    /// The page-side half of the bridge, injected at document start.
    ///
    /// Chromium adds the binding it calls to every document; the shim takes
    /// it off the global object, so pages only ever see the bridge itself,
    /// and only where ``access`` allows.
    var shim: String {
        """
        (() => {
          const send = globalThis.\(bindingName);
          if (typeof send !== 'function') return;
          delete globalThis.\(bindingName);
          if (!(\(installCondition)) || globalThis.\(name)) return;
          let sequence = 0;
          const pending = new Map();
          const listeners = new Map();
          const hidden = (key, value) => Object.defineProperty(globalThis, key, { value });
          hidden('\(replyFunction)', (id, ok, value) => {
            const call = pending.get(id);
            if (!call) return;
            pending.delete(id);
            ok ? call.resolve(value) : call.reject(new Error(value));
          });
          hidden('\(emitFunction)', (event, payload) => {
            for (const listener of [...(listeners.get(event) ?? [])]) {
              try { listener(payload); } catch (error) { console.error(error); }
            }
          });
          const api = {
            invoke(method, args) {
              return new Promise((resolve, reject) => {
                const id = ++sequence;
                pending.set(id, { resolve, reject });
                send(JSON.stringify({ id, method, args: args === undefined ? null : args }));
              });
            },
            on(event, listener) {
              if (!listeners.has(event)) listeners.set(event, new Set());
              listeners.get(event).add(listener);
              return () => api.off(event, listener);
            },
            off(event, listener) {
              listener ? listeners.get(event)?.delete(listener) : listeners.delete(event);
            },
          };
          hidden('\(name)', new Proxy(api, {
            get(target, key) {
              if (typeof key !== 'string' || key === 'then') return undefined;
              return key in target ? target[key] : (args) => target.invoke(key, args);
            },
          }));
        })();
        """
    }

    /// Per-browser bookkeeping: which JavaScript contexts exist and where
    /// they came from, as reported by Chromium.
    @MainActor
    private final class Session {
        struct Context {
            var origin: String
            var frameID: String
            var isDefault: Bool
        }

        weak var browser: CefBrowser?
        var contexts: [Int: Context] = [:]
        var mainFrameID = ""
        /// The document-start script's identifier, for replacing it.
        var scriptID: String?

        init(browser: CefBrowser) {
            self.browser = browser
        }
    }
}

/// Describes one JavaScript → Swift bridge call.
@MainActor
public struct CefBridgeCall {
    /// The browser the call came from.
    public let browser: CefBrowser
    /// The method being called.
    public let method: String
    /// The calling document's origin (`"https://example.com"`), as reported
    /// by Chromium.
    public let origin: String
    /// Whether the caller is the top-level document.
    public let isMainFrame: Bool
}
