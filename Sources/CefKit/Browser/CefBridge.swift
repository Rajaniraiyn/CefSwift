import CCef
import CefBase
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
/// The global exists before any page script runs, in every document
/// ``access`` permits, cross-site frames and popups included. Arguments and
/// results travel as JSON, so any `Codable` type works on the Swift side. A
/// handler that throws rejects the promise.
///
/// The helper's renderer code defines the global with the V8 API as each
/// document's JavaScript context is created: native functions, no injected
/// script and no DevTools session, so a page sees the global and nothing
/// else.
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
/// Calls are checked again in Swift against the caller's origin and frame,
/// which a page cannot forge: the renderer reads the origin from the
/// document, and the browser process checks it against the frame's address.
/// Each handler can also inspect ``CefBridgeCall/origin``.
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
            for browser in browsers { browser.pageScripting.configurationDidChange() }
        }
    }

    private typealias Handler = @MainActor (CefJSON, CefBridgeCall) async throws -> CefJSON
    private var handlers: [String: Handler] = [:]
    /// The browsers whose options list this bridge.
    private var attachedBrowsers: [WeakBrowser] = []

    private var browsers: [CefBrowser] {
        attachedBrowsers.removeAll { $0.browser == nil || $0.browser?.state == .closed }
        return attachedBrowsers.compactMap(\.browser)
    }

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
        let message = CefProcessMessage(
            CefPageScriptingMessage.emit, [.string(name), .string(event), .string(payload.text)])
        // A discarded page is gone; its next document starts afresh.
        for target in browsers where (browser == nil || target === browser) && !target.isDiscarded {
            target.withMainFrame { message.send(from: $0, to: PID_RENDERER) }
        }
    }

    // MARK: Installation

    /// Attaches the bridge to a browser whose options list it, as the
    /// browser is created. Its configuration reaches the renderer through
    /// the browser's `extra_info`.
    func attach(to browser: CefBrowser) {
        guard !browsers.contains(where: { $0 === browser }) else { return }
        attachedBrowsers.append(WeakBrowser(browser: browser))
    }

    /// The bridge as the renderer reads it.
    var rendererConfiguration: CefJSON {
        switch access {
        case .mainFrame:
            return ["name": .string(name), "access": "mainFrame"]
        case .anyFrame:
            return ["name": .string(name), "access": "anyFrame"]
        case .origins(let origins):
            return ["name": .string(name), "access": "origins", "origins": .array(origins.sorted().map(CefJSON.string))]
        }
    }

    // MARK: Dispatch

    /// A call from a page, `[bridge, context, call, method, arguments,
    /// origin]`, sent by `frame`'s renderer.
    func received(_ message: CefProcessMessage, in browser: CefBrowser, from frame: CefRef<cef_frame_t>) {
        let method = message.string(3)
        let context = message.int(1), callID = message.int(2)
        let reply: (Bool, CefJSON) -> Void = { [name] ok, value in
            _ = CefProcessMessage(CefPageScriptingMessage.reply, [
                .string(name), .int(Int32(context)), .int(Int32(callID)), .bool(ok),
                .string(ok ? value.text : (value.stringValue ?? value.text)),
            ]).send(from: frame.pointer, to: PID_RENDERER)
        }
        let isMainFrame = frame.pointer.pointee.is_main(frame.pointer) != 0
        let url = CefStringUtil.takingUserFree(frame.pointer.pointee.get_url(frame.pointer)).flatMap(URL.init(string:))
        let origin = message.string(5)
        let call = CefBridgeCall(browser: browser, method: method, origin: origin, isMainFrame: isMainFrame)

        // The renderer reports the document's origin; the browser process
        // knows the frame and its address, which must agree with it.
        guard Self.origin(origin, isConsistentWith: url), isPermitted(call) else {
            reply(false, .string("\(name).\(method): caller is not permitted to use this bridge"))
            return
        }
        guard let handler = handlers[method] else {
            reply(false, .string("\(name).\(method) is not defined"))
            return
        }
        let arguments = (try? CefJSON(data: Data(message.string(4).utf8))) ?? .null
        Task {
            do {
                reply(true, try await handler(arguments, call))
            } catch {
                reply(false, .string(String(describing: error)))
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

    /// Whether a document at `url` can have `origin`: the address's own
    /// origin for an address with a host, or an opaque origin (`"null"`,
    /// a sandboxed document's); any origin for an address that inherits
    /// its document's origin (`about:blank`, `data:`, `blob:` and the like).
    static func origin(_ origin: String, isConsistentWith url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return true }
        var expected = "\(scheme)://\(host.lowercased())"
        if let port = url.port { expected += ":\(port)" }
        return origin == expected || origin == "null"
    }
}

private struct WeakBrowser {
    weak var browser: CefBrowser?
}

/// Describes one JavaScript → Swift bridge call.
@MainActor
public struct CefBridgeCall {
    /// The browser the call came from.
    public let browser: CefBrowser
    /// The method being called.
    public let method: String
    /// The calling document's origin (`"https://example.com"`), as the
    /// renderer reads it from the document.
    public let origin: String
    /// Whether the caller is the top-level document.
    public let isMainFrame: Bool
}
