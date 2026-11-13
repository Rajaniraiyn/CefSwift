import CCef
import CefBase

/// Bridges, user scripts and script evaluation, implemented in the
/// renderer with the V8 API: the renderer half of `CefBridge`,
/// `CefUserScript` and `CefBrowser.evaluateJavaScript`.
///
/// A browser's configuration (its bridges and user scripts) arrives in the
/// browser's `extra_info`, so the first document already has it, and
/// changes arrive as ``CefPageScriptingMessage/configure`` messages. A
/// browser without bridges or scripts costs nothing here: no global, no
/// script, no message.
@MainActor
final class PageScripting: CefRendererExtension {
    let messagePrefix = "cefswift.page."

    /// `file` and the custom schemes registered with
    /// `CEF_SCHEME_OPTION_LOCAL` (`1 << 1`), from the helper's command line.
    private static let localSchemes: Set<String> = Set(
        ["file"] + CefSchemeList.entries(inArguments: CommandLine.arguments)
            .filter { $0.options & (1 << 1) != 0 }.map { $0.name.lowercased() })

    // MARK: Configuration

    struct Bridge {
        enum Access {
            case mainFrame
            case origins([String])
            case anyFrame
        }

        var name: String
        var access: Access

        /// Mirrors `CefBridge`'s check in the browser process, which has the
        /// last word: a top-level `about:` document (a popup's
        /// `about:blank`) inherits its opener's origin, which the browser
        /// process cannot confirm, so an `.origins` bridge leaves it out.
        func permits(isMainFrame: Bool, origin: String, url: String) -> Bool {
            switch access {
            case .mainFrame: return isMainFrame
            case .origins(let allowed):
                if isMainFrame, url.lowercased().hasPrefix("about:") { return false }
                return allowed.contains(origin)
            case .anyFrame: return true
            }
        }
    }

    struct Script {
        var source: String
        var urlPattern: String?
        var atDocumentEnd: Bool
        var mainFrameOnly: Bool

        func applies(to url: String, isMainFrame: Bool) -> Bool {
            if mainFrameOnly, !isMainFrame { return false }
            return urlPattern.map { PageScripting.matches(url, pattern: $0) } ?? true
        }

        /// A scoped script runs inside a function, so its top-level
        /// declarations stay out of the page's globals.
        var runnableSource: String {
            urlPattern == nil ? source : "(() => {\n\(source)\n})();"
        }
    }

    struct Configuration {
        var generation = 0
        var bridges: [Bridge] = []
        var scripts: [Script] = []

        var isEmpty: Bool { bridges.isEmpty && scripts.isEmpty }

        init() {}

        init?(json: JSONValue) {
            guard let generation = json["generation"]?.number else { return nil }
            self.generation = Int(generation)
            bridges = (json["bridges"]?.array ?? []).compactMap { bridge in
                guard let name = bridge["name"]?.string else { return nil }
                switch bridge["access"]?.string {
                case "anyFrame":
                    return Bridge(name: name, access: .anyFrame)
                case "origins":
                    return Bridge(name: name, access: .origins((bridge["origins"]?.array ?? []).compactMap(\.string)))
                default:
                    return Bridge(name: name, access: .mainFrame)
                }
            }
            scripts = (json["scripts"]?.array ?? []).compactMap { script in
                guard let source = script["source"]?.string else { return nil }
                return Script(
                    source: source, urlPattern: script["urlPattern"]?.string,
                    atDocumentEnd: script["atDocumentEnd"]?.bool ?? false,
                    mainFrameOnly: script["mainFrameOnly"]?.bool ?? false)
            }
        }
    }

    /// Each browser's configuration, by browser identifier.
    private var configurations: [Int32: Configuration] = [:]
    /// Browsers whose configuration generation this process has reported.
    private var reportedBrowsers: Set<Int32> = []

    // MARK: Per-document state

    /// One main-world context that has a bridge.
    final class Document {
        let id: Int
        let context: V8Context
        let browserID: Int32
        let isMainFrame: Bool
        let origin: String
        var nextCall = 0
        /// Promises of calls waiting for the browser process, by bridge and call.
        var pendingCalls: [String: [Int: V8Value]] = [:]
        /// `<bridge>.on(event, listener)` listeners, by bridge and event.
        var listeners: [String: [String: [V8Value]]] = [:]

        init(id: Int, context: V8Context, browserID: Int32, isMainFrame: Bool, origin: String) {
            self.id = id
            self.context = context
            self.browserID = browserID
            self.isMainFrame = isMainFrame
            self.origin = origin
        }
    }

    private var documents: [Int: Document] = [:]
    private var nextDocumentID = 0
    /// Evaluations whose result is a promise that has not settled.
    private var pendingEvaluations: [EvaluationID: PendingEvaluation] = [:]

    /// One evaluation. Each browser numbers its requests on its own, and
    /// browsers of one profile may share this process, so a request
    /// number alone is ambiguous; with the browser it is unique, since a
    /// browser never reuses one.
    struct EvaluationID: Hashable {
        var browserID: Int32
        var request: Int
    }

    struct PendingEvaluation {
        var context: V8Context
        var frame: CefRendererFrame
    }

    // MARK: Browser lifetime

    func browserCreated(_ browserID: Int32, extraInfo: UnsafeMutablePointer<cef_dictionary_value_t>?) {
        guard let extraInfo else { return }
        let text = CefStringUtil.withCefString(CefPageScriptingMessage.configurationKey) {
            CefStringUtil.takingUserFree(extraInfo.pointee.get_string(extraInfo, $0))
        }
        guard let text, let json = JSONValue(parsing: text), let configuration = Configuration(json: json),
              configuration.generation >= configurations[browserID]?.generation ?? -1
        else { return }
        configurations[browserID] = configuration
    }

    /// CEF reports a browser destroyed in this process when its last frame
    /// here goes, which happens in the middle of a navigation that replaces
    /// the main frame's renderer-side frame, and created again right after.
    /// So the configuration, which may be newer than the one the browser
    /// was created with, stays; documents go as their contexts are released.
    func browserDestroyed(_ browserID: Int32) {}

    // MARK: Contexts

    func contextCreated(_ context: V8Context, in frame: CefRendererFrame) {
        guard let configuration = configurations[frame.browserID] else { return }
        // A renderer process that joins a browser later than its
        // configuration changed learns of the change from the reply.
        if reportedBrowsers.insert(frame.browserID).inserted {
            frame.send(CefProcessMessage(CefPageScriptingMessage.sync, [.int(Int32(configuration.generation))]))
        }
        guard !configuration.isEmpty, let mainWorld = frame.mainWorldContext, mainWorld.isSame(context),
              let global = context.global
        else { return }

        let isMainFrame = frame.isMain
        let url = frame.url
        for script in configuration.scripts where !script.atDocumentEnd && script.applies(to: url, isMainFrame: isMainFrame) {
            run(script, in: context)
        }
        let atEnd = configuration.scripts.filter { $0.atDocumentEnd && $0.applies(to: url, isMainFrame: isMainFrame) }
        if !atEnd.isEmpty { runAtDocumentEnd(atEnd, global: global, context: context) }

        guard !configuration.bridges.isEmpty else { return }
        // The document's origin, `self.origin`, read before any page script
        // runs. `location.origin` is its address's, which differs for
        // `about:blank` and `srcdoc` documents: theirs is opaque, while the
        // document has its parent's origin.
        let locationOrigin = global["location"]?["origin"]?.stringValue ?? ""
        var origin = global["origin"].flatMap { $0.isString ? $0.stringValue : nil } ?? locationOrigin
        // Chromium gives `file:` documents (and those of `.local` custom
        // schemes) an opaque `self.origin` but the address's
        // `location.origin`. A main frame's is taken as its address's, as
        // the browser process does; a subframe's stays opaque, since a
        // sandboxed one looks the same.
        if origin == "null", isMainFrame, locationOrigin != "null",
           let scheme = url.split(separator: ":", maxSplits: 1).first?.lowercased(), Self.localSchemes.contains(scheme) {
            origin = locationOrigin
        }
        let permitted = configuration.bridges.filter { $0.permits(isMainFrame: isMainFrame, origin: origin, url: url) }
        guard !permitted.isEmpty else { return }
        nextDocumentID += 1
        let document = Document(
            id: nextDocumentID, context: context, browserID: frame.browserID, isMainFrame: isMainFrame, origin: origin)
        documents[document.id] = document
        for bridge in permitted where global[bridge.name]?.isUndefined ?? true {
            if let object = makeBridgeObject(named: bridge.name, for: document) {
                global.set(bridge.name, object, hidden: true)
            }
        }
    }

    func contextReleased(_ context: V8Context, in frame: CefRendererFrame) {
        for (id, document) in documents where document.context.isSame(context) {
            documents[id] = nil
        }
        for (id, pending) in pendingEvaluations where pending.context.isSame(context) {
            pendingEvaluations[id] = nil
            Self.sendEvaluated(Int32(id.request), from: frame, error: "The document went away before the result was ready.")
        }
    }

    // MARK: User scripts

    private func run(_ script: Script, in context: V8Context) {
        if case .failure(let error) = context.run(script.runnableSource) {
            report(error.message, in: context)
        }
    }

    /// Runs `scripts` as the document's `DOMContentLoaded` fires, before
    /// the page's own listeners for it, which are added later.
    private func runAtDocumentEnd(_ scripts: [Script], global: V8Value, context: V8Context) {
        guard let document = global["document"], let addEventListener = document["addEventListener"] else { return }
        let listener = context.durableFunction { [weak self, weak context] _, _ in
            if let context { for script in scripts { self?.run(script, in: context) } }
            return .success(nil)
        }
        guard let listener else { return }
        let options = V8Value.object()
        options.set("once", .bool(true))
        addEventListener.call(this: document, [.string("DOMContentLoaded"), listener, options])
    }

    /// Reports an exception of CefSwift's own making on the page's console,
    /// as an uncaught one would be.
    private func report(_ message: String, in context: V8Context) {
        guard let console = context.global?["console"], let error = console["error"] else { return }
        error.call(this: console, [.string(message)])
    }

    /// Whether `url` matches `pattern`, where `*` stands for any run of
    /// characters.
    nonisolated static func matches(_ url: String, pattern: String) -> Bool {
        let text = Array(url.unicodeScalars)
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        guard let first = parts.first, let last = parts.last else { return true }
        if parts.count == 1 { return text == first }
        guard text.starts(with: first) else { return false }
        var position = first.count
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let found = find(part, in: text, from: position) else { return false }
            position = found + part.count
        }
        return text.count - position >= last.count && Array(text.suffix(last.count)) == last
    }

    private nonisolated static func find(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int) -> Int? {
        guard needle.count <= haystack.count - start else { return nil }
        for index in start...(haystack.count - needle.count) where Array(haystack[index..<index + needle.count]) == needle {
            return index
        }
        return nil
    }

    // MARK: Bridges

    /// The names `Object.prototype` defines, which the bridge object
    /// inherits instead of treating as methods.
    private static let inheritedNames: Set<String> = [
        "constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "toString",
        "valueOf", "__proto__", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
    ]

    /// The bridge's global object: `invoke`, `on`, `off`, and any other
    /// name as a method that calls Swift.
    private func makeBridgeObject(named bridge: String, for document: Document) -> V8Value? {
        V8Value.object { [weak self, weak document] name in
            guard let self, let document else { return nil }
            switch name {
            case "invoke":
                return V8Value.function("invoke") { [weak self, weak document] _, arguments in
                    guard let self, let document else { return .success(nil) }
                    guard let method = arguments.first, method.isString else {
                        return .failure(V8Exception(message: "\(bridge).invoke: the method name must be a string"))
                    }
                    return .success(self.call(bridge, method, arguments.dropFirst().first, in: document))
                }
            case "on":
                return V8Value.function("on") { [weak self, weak document] _, arguments in
                    guard let self, let document, arguments.count >= 2, arguments[1].isFunction else {
                        return .failure(V8Exception(message: "\(bridge).on: expected an event name and a function"))
                    }
                    let event = arguments[0].stringValue, listener = arguments[1]
                    document.listeners[bridge, default: [:]][event, default: []].append(listener)
                    return .success(V8Value.function("") { [weak self, weak document] _, _ in
                        if let document { self?.removeListener(listener, for: event, of: bridge, in: document) }
                        return .success(nil)
                    })
                }
            case "off":
                return V8Value.function("off") { [weak self, weak document] _, arguments in
                    guard let self, let document, let event = arguments.first?.stringValue else { return .success(nil) }
                    if arguments.count >= 2, arguments[1].isFunction {
                        self.removeListener(arguments[1], for: event, of: bridge, in: document)
                    } else {
                        document.listeners[bridge]?[event] = nil
                    }
                    return .success(nil)
                }
            case "then":
                // Not a thenable: `await bridge` gives the bridge itself.
                return nil
            case _ where Self.inheritedNames.contains(name):
                return nil
            default:
                return V8Value.function(name) { [weak self, weak document] _, arguments in
                    guard let self, let document else { return .success(nil) }
                    return .success(self.call(bridge, name, arguments.first, in: document))
                }
            }
        }
    }

    private func removeListener(_ listener: V8Value, for event: String, of bridge: String, in document: Document) {
        document.listeners[bridge]?[event]?.removeAll { $0.isSame(listener) }
    }

    /// Sends a call to the browser process and returns its promise. The
    /// argument goes from V8 straight into the message's payload.
    private func call(_ bridge: String, _ method: V8Value, _ argument: V8Value?, in document: Document) -> V8Value? {
        call(bridge, method: { $0.append(utf16: method.raw) }, describe: { method.stringValue }, argument, in: document)
    }

    private func call(_ bridge: String, _ method: String, _ argument: V8Value?, in document: Document) -> V8Value? {
        call(bridge, method: { $0.append(method) }, describe: { method }, argument, in: document)
    }

    private func call(
        _ bridge: String, method writeMethod: (inout CefWireBuffer) -> Void, describe: () -> String,
        _ argument: V8Value?, in document: Document
    ) -> V8Value? {
        guard let promise = V8Value.promise() else { return nil }
        guard let frame = document.context.raw.pointee.get_frame(document.context.raw) else {
            promise.reject("\(bridge).\(describe()): the document is closing")
            return promise
        }
        defer { cefRelease(frame) }
        document.nextCall += 1
        let callID = document.nextCall
        document.pendingCalls[bridge, default: [:]][callID] = promise
        var payload = CefWireBuffer()
        payload.append(header: CefWireHeader(target: Int32(document.id), call: Int32(callID)))
        payload.append(bridge)
        writeMethod(&payload)
        payload.append(document.origin)
        do {
            try V8Wire.write(argument?.raw, to: &payload)
        } catch {
            document.pendingCalls[bridge]?[callID] = nil
            promise.reject("\(bridge).\(describe()): \(error.message)")
            return promise
        }
        if !payload.send(CefPageScriptingMessage.call, from: frame, to: PID_BROWSER) {
            document.pendingCalls[bridge]?[callID] = nil
            promise.reject("\(bridge).\(describe()): the document is closing")
        }
        return promise
    }

    private func settle(_ payload: CefWirePayload) {
        var reader = payload.reader
        guard let header = try? reader.header() else { return }
        reader.skipHeader()
        guard let bridge = try? reader.readString(),
              let document = documents[Int(header.target)],
              let promise = document.pendingCalls[bridge]?.removeValue(forKey: Int(header.call))
        else { return }
        document.context.entered {
            if header.succeeded != 0 {
                if let value = V8Wire.read(&reader) { promise.resolve(V8Value(adopting: value)) }
            } else {
                promise.reject((try? reader.readString()) ?? "")
            }
        }
        document.context.runMicrotasksSoon()
    }

    private func emit(_ payload: CefWirePayload, in frame: CefRendererFrame) {
        var reader = payload.reader
        reader.skipHeader()
        guard let bridge = try? reader.readString(), let event = try? reader.readString(),
              let context = frame.mainWorldContext,
              let document = documents.values.first(where: { $0.context.isSame(context) }),
              let listeners = document.listeners[bridge]?[event], !listeners.isEmpty
        else { return }
        let start = reader.offset
        context.entered {
            for listener in listeners {
                // Each listener gets a value of its own.
                var copy = reader
                copy.offset = start
                guard let value = V8Wire.read(&copy) else { continue }
                if case .failure(let error) = listener.call(this: nil, [V8Value(adopting: value)]) {
                    report(error.message, in: context)
                }
            }
        }
        context.runMicrotasksSoon()
    }

    // MARK: Evaluation

    /// Sends an evaluation's result: the value, from V8 straight into the
    /// payload, or the error message.
    private static func sendEvaluated(
        _ request: Int32, from frame: CefRendererFrame, value: V8Value? = nil, error: String? = nil,
        line: Int = 0, column: Int = 0
    ) {
        var payload = CefWireBuffer()
        var error = error
        if error == nil {
            payload.append(header: CefWireHeader(target: request, succeeded: true))
            do {
                try V8Wire.write(value?.raw, to: &payload)
            } catch let failure {
                // A getter threw, or the value is too large: the evaluation
                // fails with that, and the partial value is dropped.
                error = failure.message
                payload = CefWireBuffer()
            }
        }
        if let error {
            payload.append(header: CefWireHeader(
                target: request, succeeded: false, line: Int32(clamping: line), column: Int32(clamping: column)))
            payload.append(error)
        }
        payload.send(CefPageScriptingMessage.evaluated, from: frame.raw, to: PID_BROWSER)
    }

    /// Runs a script for `CefBrowser.evaluateJavaScript` and sends its
    /// result back; a promise is awaited first.
    private func evaluate(_ payload: CefWirePayload, in frame: CefRendererFrame) {
        var reader = payload.reader
        guard let header = try? reader.header() else { return }
        reader.skipHeader()
        let request = header.target
        guard let context = frame.mainWorldContext else {
            Self.sendEvaluated(request, from: frame, error: "The frame has no document.")
            return
        }
        guard let source = try? reader.readStringBytes() else { return }
        context.entered {
            switch context.run(utf8: source) {
            case .failure(let error):
                Self.sendEvaluated(request, from: frame, error: error.message, line: error.line, column: error.column)
            case .success(let value) where value.isPromise:
                awaitPromise(value, request: Int(request), context: context, frame: frame)
            case .success(let value):
                Self.sendEvaluated(request, from: frame, value: value)
            }
        }
        // The script may have queued promise jobs of its own.
        context.runMicrotasksSoon()
    }

    private func awaitPromise(_ promise: V8Value, request: Int, context: V8Context, frame: CefRendererFrame) {
        let id = EvaluationID(browserID: frame.browserID, request: request)
        let settle: (Bool) -> V8Value? = { [weak self] succeeded in
            context.durableFunction { [weak self] _, arguments in
                guard let self, self.pendingEvaluations.removeValue(forKey: id) != nil else { return .success(nil) }
                let value = arguments.first ?? .undefined
                if succeeded {
                    Self.sendEvaluated(Int32(request), from: frame, value: value)
                } else {
                    Self.sendEvaluated(Int32(request), from: frame, error: Self.describe(rejection: value))
                }
                return .success(nil)
            }
        }
        guard let then = promise["then"], let fulfilled = settle(true), let rejected = settle(false),
              case .success = then.call(this: promise, [fulfilled, rejected])
        else {
            Self.sendEvaluated(Int32(request), from: frame, error: "The promise could not be awaited.")
            return
        }
        pendingEvaluations[id] = PendingEvaluation(context: context, frame: frame)
    }

    /// `Uncaught (in promise) Error: message`, as Chromium's console words a
    /// rejection.
    private static func describe(rejection value: V8Value) -> String {
        var text: String
        if value.isObject, let message = value["message"], message.isString {
            let name = value["name"].flatMap { $0.isString ? $0.stringValue : nil } ?? "Error"
            text = "\(name): \(message.stringValue)"
        } else if value.isString {
            text = value.stringValue
        } else {
            var payload = CefWireBuffer()
            do {
                try V8Wire.write(value.raw, to: &payload)
                payload.materializeDeferred()
                text = JSONValue.text(wire: payload.bytes)
            } catch {
                text = error.message
            }
        }
        return "Uncaught (in promise) " + text
    }

    // MARK: Messages

    func received(_ message: CefProcessMessage, in frame: CefRendererFrame) {
        switch message.name {
        case CefPageScriptingMessage.configure.text:
            guard message.arguments.count == 1, let text = message.string(0),
                  let json = JSONValue(parsing: text), let configuration = Configuration(json: json),
                  configuration.generation >= (configurations[frame.browserID]?.generation ?? -1)
            else { return }
            configurations[frame.browserID] = configuration
        default:
            break
        }
    }

    func received(_ kind: CefPageScriptingMessage.Kind, payload: CefWirePayload, in frame: CefRendererFrame) {
        switch kind {
        case .reply: settle(payload)
        case .emit: emit(payload, in: frame)
        case .evaluate: evaluate(payload, in: frame)
        default: break
        }
    }
}
