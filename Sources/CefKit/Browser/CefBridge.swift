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
/// var configuration = CefBrowser.Configuration()
/// configuration.bridges = [bridge]
/// let browser = CefBrowser(url: appURL, configuration: configuration)
/// ```
///
/// ```js
/// const reply = await app.greet({ name: "Ada" });   // "Hello, Ada!"
/// app.on("themeChanged", theme => applyTheme(theme));
/// ```
///
/// The global exists before any page script runs, in every document
/// ``access`` permits, cross-site frames and popups included. Arguments and
/// results are JSON's kinds of values plus bytes, so any `Codable` type
/// works on the Swift side, and `Data` is an `ArrayBuffer` in the page. A
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
/// Calls are checked again in Swift against the caller's frame and origin,
/// which the browser process establishes from its own record of the
/// frame's address, so not even a compromised renderer can claim another
/// origin. A document whose origin the address cannot confirm (`data:`
/// documents, sandboxed ones, a popup's `about:blank`) has the opaque
/// origin `"null"` and never matches ``Access/origins(_:)``. `about:blank`
/// and `srcdoc` frames have their parent frame's origin, and a `blob:`
/// document the origin in its address. Each handler can also inspect
/// ``CefBridgeCall/origin``.
@MainActor
public final class CefBridge {

    /// Which documents get the bridge and may call it.
    public enum Access: Sendable, Equatable {
        /// Only top-level documents (the default).
        case mainFrame
        /// Documents, in any frame, whose origin is listed, e.g.
        /// `"https://app.example.com"` or `"app://start"`. The origin is
        /// the one ``CefBridgeCall/origin`` describes; an opaque one never
        /// matches.
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

    /// A method: decodes the call's argument from the payload, in place,
    /// and returns the work that runs the handler and encodes its result
    /// into a reply.
    private typealias Handler = @MainActor (CefWireDecoder, CefBridgeCall) throws -> Work
    private typealias Work = @MainActor (CefWireEncoder) async throws -> Void
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
        handlers[method] = { decoder, call in
            let input = try decoder.decode(Input.self)
            return { encoder in try encoder.encode(await handler(input, call)) }
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
        handlers[method] = { decoder, call in
            let input = try decoder.decode(Input.self)
            return { encoder in
                try await handler(input, call)
                encoder.buffer.appendNull()
            }
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
        let encoder = CefWireEncoder(header: CefWireHeader())
        encoder.buffer.append(name)
        encoder.buffer.append(event)
        do {
            try encoder.encode(payload)
        } catch {
            CefLog.error("CefBridge.emit(\(event)): payload cannot be encoded: \(error)")
            return
        }
        // A discarded page is gone; its next document starts afresh.
        for target in browsers where (browser == nil || target === browser) && !target.isDiscarded {
            target.withMainFrame { encoder.buffer.send(CefPageScriptingMessage.emit, from: $0, to: PID_RENDERER) }
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

    /// A call from a page, sent by `frame`'s renderer. `reader` is past
    /// the header and the bridge's name, at the method, the origin and the
    /// argument.
    func received(_ payload: CefWirePayload, reader: CefWireReader, in browser: CefBrowser, from frame: CefRef<cef_frame_t>) {
        var reader = reader
        guard let header = try? payload.reader.header(),
              let method = try? reader.readString(), let origin = try? reader.readString()
        else { return }
        let replyHeader = { (succeeded: Bool) in CefWireHeader(target: header.target, call: header.call, succeeded: succeeded) }
        let fail: (String) -> Void = { [name] message in
            let encoder = CefWireEncoder(header: replyHeader(false))
            encoder.buffer.append(name)
            encoder.buffer.append(message)
            encoder.buffer.send(CefPageScriptingMessage.reply, from: frame.pointer, to: PID_RENDERER)
        }
        let isMainFrame = frame.pointer.pointee.is_main(frame.pointer) != 0
        let url = CefStringUtil.takingUserFree(frame.pointer.pointee.get_url(frame.pointer))

        // The renderer reports the document's origin, but a compromised
        // renderer could report any; the browser process's own record of
        // the frame's address (and its parents') decides.
        let established = Self.establishedOrigin(
            claimed: origin, url: url, isMainFrame: isMainFrame, localSchemes: Self.localSchemes
        ) { Self.ancestorURLs(of: frame.pointer) }
        let call = CefBridgeCall(browser: browser, method: method, origin: established.origin ?? "null", isMainFrame: isMainFrame)
        guard established != .inconsistent, isPermitted(call, origin: established) else {
            fail("\(name).\(method): caller is not permitted to use this bridge")
            return
        }
        guard let handler = handlers[method] else {
            fail("\(name).\(method) is not defined")
            return
        }
        // The argument decodes now, in place; the payload is released once
        // it has, unless a `Data` argument keeps its shared memory.
        let work: Work
        do {
            work = try handler(CefWireDecoder(payload: payload, offset: reader.offset), call)
        } catch {
            fail(String(describing: error))
            return
        }
        Task { [name] in
            let encoder = CefWireEncoder(header: replyHeader(true))
            encoder.buffer.append(name)
            do {
                try await work(encoder)
                encoder.buffer.send(CefPageScriptingMessage.reply, from: frame.pointer, to: PID_RENDERER)
            } catch {
                fail(String(describing: error))
            }
        }
    }

    private func isPermitted(_ call: CefBridgeCall, origin: EstablishedOrigin) -> Bool {
        switch access {
        case .mainFrame: return call.isMainFrame
        case .origins(let allowed):
            // An opaque or unconfirmed origin never matches, even if
            // `"null"` is listed.
            guard case .origin(let origin) = origin else { return false }
            return allowed.contains(origin)
        case .anyFrame: return true
        }
    }

    // MARK: Origins

    /// What the browser process can say about a calling document's origin.
    enum EstablishedOrigin: Equatable {
        /// The frame's address confirms the origin the renderer reported.
        case origin(String)
        /// The document's origin is opaque (a `data:` document, a
        /// sandboxed one, `blob:null/…`) or cannot be confirmed (a
        /// top-level `about:blank`, an unparseable or missing address).
        case opaque
        /// The renderer reported an origin the frame's address rules out.
        case inconsistent

        var origin: String? {
            if case .origin(let origin) = self { return origin }
            return nil
        }
    }

    /// The origin of a document at `url`, as far as the address tells.
    enum AddressOrigin: Equatable {
        /// A scheme, host and port: `https://example.com:8443`.
        case tuple(String)
        /// Opaque, or unknown.
        case opaque
        /// `about:blank` and `about:srcdoc`, which take their origin from
        /// the frame that made them.
        case inherited
    }

    /// The origin an address gives a document. `blob:` and `filesystem:`
    /// addresses carry their origin after the scheme; `about:blank` and
    /// `about:srcdoc` inherit one; `data:`, `javascript:`, other `about:`
    /// pages and addresses without a host are opaque.
    ///
    /// `localSchemes` have `file`'s security rules: `file` itself and
    /// custom schemes registered with ``CefCustomScheme/Options/local``.
    /// Chromium gives their documents an opaque origin (`self.origin` is
    /// `"null"`), so here their origin is their address's (`file://`,
    /// `myapp://host`) only in the main frame, which an embedding page
    /// cannot sandbox. In a subframe it is opaque: CEF does not say whether
    /// the frame is sandboxed, and its document's origin is opaque anyway.
    nonisolated static func addressOrigin(
        _ text: String?, isMainFrame: Bool = true, localSchemes: Set<String> = ["file"]
    ) -> AddressOrigin {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return .opaque }
        if localSchemes.contains(scheme), !isMainFrame { return .opaque }
        switch scheme {
        case "about":
            let page = text.dropFirst("about:".count).prefix { $0 != "?" && $0 != "#" }.lowercased()
            return page == "blank" || page == "srcdoc" ? .inherited : .opaque
        case "blob", "filesystem":
            // The inner address's origin, if it has a host: `blob:null/…`
            // and nested `blob:` are opaque.
            let inner = String(text.dropFirst(scheme.count + 1))
            guard let innerScheme = URL(string: inner)?.scheme?.lowercased(), innerScheme != "blob", innerScheme != "filesystem",
                  !localSchemes.contains(innerScheme), case .tuple(let origin) = addressOrigin(inner)
            else { return .opaque }
            return .tuple(origin)
        case "file":
            return .tuple("file://")
        default:
            guard let host = url.host, !host.isEmpty else { return .opaque }
            var origin = "\(scheme)://" + (host.contains(":") ? "[\(host.lowercased())]" : host.lowercased())
            let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443]
            if let port = url.port, defaultPorts[scheme] != port { origin += ":\(port)" }
            return .tuple(origin)
        }
    }

    /// The calling document's origin, established from the browser
    /// process's own record of its frame's address, `url`, and for an
    /// inheriting address, of its ancestors' (`ancestors`, nearest first,
    /// the main frame last):
    ///
    /// - An address with a host confirms `claimed` only if it is the
    ///   address's origin; `"null"` (a sandboxed document) is opaque, and
    ///   anything else inconsistent.
    /// - `blob:https://host/…` is `https://host`'s.
    /// - `about:blank` and `about:srcdoc` take the nearest ancestor's
    ///   origin. CEF does not expose the frame that created a document,
    ///   so a top-level one (a popup's `about:blank`) is opaque.
    /// - A `localSchemes` address (`file:`) is its address's origin in the
    ///   main frame and opaque in a subframe, as ``addressOrigin(_:isMainFrame:localSchemes:)``
    ///   explains; `about:blank` and `srcdoc` inside it are opaque.
    /// - `data:` and every other address are opaque, whatever the renderer
    ///   claims.
    nonisolated static func establishedOrigin(
        claimed: String, url: String?, isMainFrame: Bool = false, localSchemes: Set<String> = ["file"],
        ancestors: () -> [String?]
    ) -> EstablishedOrigin {
        var origin = addressOrigin(url, isMainFrame: isMainFrame, localSchemes: localSchemes)
        if origin == .inherited {
            // Inheriting from a local-scheme document is opaque even from
            // the main frame: Chromium makes such children opaque
            // (`self.origin` is `"null"`), and a sandboxed one looks the same.
            origin = ancestors().lazy
                .map { addressOrigin($0, isMainFrame: false, localSchemes: localSchemes) }
                .first { $0 != .inherited } ?? .opaque
        }
        guard case .tuple(let expected) = origin else { return .opaque }
        if claimed == expected { return .origin(expected) }
        return claimed == "null" ? .opaque : .inconsistent
    }

    /// `file` and the custom schemes registered with `.local`.
    private static var localSchemes: Set<String> {
        Set(["file"] + (CefRuntime.shared.configuration?.customSchemes ?? [])
            .filter { $0.options.contains(.local) }.map { $0.name.lowercased() })
    }

    /// The addresses of `frame`'s ancestors, nearest first, as the browser
    /// process knows them.
    private static func ancestorURLs(of frame: UnsafeMutablePointer<cef_frame_t>) -> [String?] {
        var urls: [String?] = []
        var current = frame.pointee.get_parent(frame)
        // Frames nest only so deep; the bound guards against a cycle.
        while let parent = current, urls.count < 64 {
            urls.append(CefStringUtil.takingUserFree(parent.pointee.get_url(parent)))
            current = parent.pointee.get_parent(parent)
            cefRelease(parent)
        }
        cefRelease(current)
        return urls
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
    /// browser process establishes it from the frame's address: the
    /// address's origin; for `about:blank` and `about:srcdoc`, the nearest
    /// parent frame's; for `blob:https://example.com/…`, the one it names;
    /// `"file://"` for a top-level `file:` page (a `file:` subframe is
    /// opaque, as is one of a custom scheme registered with `.local`).
    /// `"null"` when the origin is opaque or the address cannot confirm it:
    /// `data:` documents, sandboxed documents, and a top-level
    /// `about:blank` such as a new popup's, whose opener CEF does not say.
    public let origin: String
    /// Whether the caller is the top-level document.
    public let isMainFrame: Bool
}
