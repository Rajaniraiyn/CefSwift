import CCef
import CefBase
import Foundation

/// The browser-process half of bridges, user scripts and
/// ``CefBrowser/evaluateJavaScript(_:userGesture:)``; the renderer half is
/// `PageScripting` in the helper (`Sources/CefRenderer`).
///
/// A browser's bridges and user scripts travel in its `extra_info`, which
/// CEF hands to every renderer process that shows one of its frames before
/// the frame's first document starts. Changes after creation
/// (``CefBrowser/addUserScript(_:)``, ``CefBridge/access``) go to every
/// frame's renderer as a message, and a renderer process that joins the
/// browser later reports which configuration it has, so it is brought up
/// to date. Nothing here uses the DevTools protocol.
@MainActor
final class CefPageScripting {
    private weak var browser: CefBrowser?
    /// Numbers the configuration; the renderer keeps the newest. Numbers
    /// come from one counter for every browser, so a configuration made
    /// later is newer than any a renderer got earlier, as a tab Chromium
    /// opens gets its window's first browser's `extra_info`.
    private(set) var generation = CefPageScripting.nextGeneration()

    private static var lastGeneration = 0

    private static func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }
    /// Evaluations waiting for the renderer, by request. A request number
    /// is unique for the browser's lifetime; the renderer tells requests of
    /// different browsers apart by the browser's identifier.
    let pendingEvaluations = CefPendingOperations<CefWirePayload>()
    /// The frame each evaluation sent to a frame other than the main one
    /// runs in, by request.
    private var evaluationFrames: [Int: CefFrame.ID] = [:]
    /// Whether the browser is a service host, whose replies
    /// ``CefDiagnostics`` counts.
    var isServiceHost = false

    init(browser: CefBrowser) {
        self.browser = browser
    }

    // MARK: Configuration

    /// The configuration the renderer reads, as JSON.
    static func configuration(bridges: [CefBridge], scripts: [CefUserScript], generation: Int) -> CefJSON {
        [
            "generation": .number(Double(generation)),
            "bridges": .array(bridges.map(\.rendererConfiguration)),
            "scripts": .array(scripts.map(\.rendererConfiguration)),
        ]
    }

    private var configuration: CefJSON {
        guard let browser else { return .null }
        return Self.configuration(bridges: browser.bridges, scripts: browser.userScripts, generation: generation)
    }

    /// A browser's `extra_info` for creation, with one reference, which the
    /// creation call consumes.
    static func makeExtraInfo(_ configuration: CefJSON) -> UnsafeMutablePointer<cef_dictionary_value_t>? {
        guard let dictionary = cef_dictionary_value_create() else { return nil }
        CefStringUtil.withCefString(CefPageScriptingMessage.configurationKey) { key in
            CefStringUtil.withCefString(configuration.text) { _ = dictionary.pointee.set_string(dictionary, key, $0) }
        }
        return dictionary
    }

    /// The browser's `extra_info` for its creation, which renderers get
    /// with it.
    func makeExtraInfo() -> UnsafeMutablePointer<cef_dictionary_value_t>? {
        extraInfoGeneration = generation
        return Self.makeExtraInfo(configuration)
    }

    /// `extra_info` for a popup of this browser, which gets this browser's
    /// configuration.
    func makeExtraInfoForPopup() -> UnsafeMutablePointer<cef_dictionary_value_t>? {
        Self.makeExtraInfo(configuration)
    }

    /// The generation the browser's `extra_info` carried; `nil` for a
    /// browser Chromium created, whose `extra_info` CefKit did not write.
    private var extraInfoGeneration: Int?

    /// A frame connected to a renderer, which may be a process new to the
    /// browser. When the configuration is not the one the browser's
    /// `extra_info` carried (it changed since, or Chromium created the
    /// browser without it), the frame's renderer gets the current one now,
    /// for the documents it loads from then on. CEF connects a frame once
    /// its first document has committed, so that document goes without.
    func frameDidAttach(_ frame: UnsafeMutablePointer<cef_frame_t>) {
        guard extraInfoGeneration != generation, extraInfoGeneration != nil || hasConfiguration else { return }
        CefProcessMessage(CefPageScriptingMessage.configure, [.string(configuration.text)])
            .send(from: frame, to: PID_RENDERER)
    }

    /// Whether the browser has bridges or user scripts.
    var hasConfiguration: Bool {
        guard let browser else { return false }
        return !browser.bridges.isEmpty || !browser.userScripts.isEmpty
    }

    /// Sends the browser's configuration to every renderer that shows one
    /// of its frames. Documents loaded from then on use it.
    func configurationDidChange() {
        generation = Self.nextGeneration()
        let message = CefProcessMessage(CefPageScriptingMessage.configure, [.string(configuration.text)])
        browser?.forEachFrame { message.send(from: $0, to: PID_RENDERER) }
    }

    // MARK: Evaluation

    /// Runs `script` in the main frame's main world and decodes its value
    /// as `T`, straight from the reply's payload. Cancelling the calling
    /// task ends the wait with `CancellationError`; the script itself runs
    /// on.
    func evaluate<T: Decodable>(_ script: String, as type: T.Type = T.self, in frame: CefFrame.ID? = nil) async throws -> T {
        try await evaluatedPayload(script, in: frame).decode(T.self, at: Self.valueOffset)
    }

    /// Runs `script` and returns its value as `CefJSON`.
    func evaluate(_ script: String) async throws -> CefJSON {
        try await evaluate(script, as: CefJSON.self)
    }

    /// Where a reply's value starts: after the header.
    private static let valueOffset = CefWireHeader.size

    /// Sends `script` to `frameID`'s renderer, or the main frame's, and
    /// waits for the reply: its header, then the value or the error.
    /// `didSend` runs once the script has gone to the renderer, and only
    /// then: a caller cancelled or a browser closed before that sends
    /// nothing.
    func evaluatedPayload(
        _ script: String, in frameID: CefFrame.ID?, didSend: () -> Void = {}
    ) async throws -> CefWirePayload {
        guard let browser else { throw CefError.browserClosed }
        try await browser.ready()
        if let frameID, browser.frame(withID: frameID) == nil { throw CefError.frameDetached }
        return try await pendingEvaluations.wait { request in
            var sent = false
            var payload = CefWireBuffer(capacity: script.utf8.count + 64)
            payload.append(header: CefWireHeader(target: Int32(truncatingIfNeeded: request)))
            payload.append(script)
            let send = { (frame: UnsafeMutablePointer<cef_frame_t>) in
                sent = payload.send(CefPageScriptingMessage.evaluate, from: frame, to: PID_RENDERER)
            }
            if let frameID {
                browser.withFrame(frameID, send)
                if sent { evaluationFrames[request] = frameID }
            } else {
                browser.withMainFrame(send)
            }
            if sent {
                didSend()
            } else {
                pendingEvaluations.complete(request, .failure(frameID == nil ? CefError.browserClosed : CefError.frameDetached))
            }
        }
    }

    /// Runs `script` in the main frame without waiting for it: request 0,
    /// which the renderer does not answer.
    func evaluateWithoutReply(_ script: String) {
        guard let browser, browser.state == .live else { return }
        var payload = CefWireBuffer(capacity: script.utf8.count + 64)
        payload.append(header: CefWireHeader(target: 0))
        payload.append(script)
        browser.withMainFrame { _ = payload.send(CefPageScriptingMessage.evaluate, from: $0, to: PID_RENDERER) }
    }

    /// A frame lost its renderer: evaluations still waiting in it fail.
    func frameDidDetach(_ id: CefFrame.ID) {
        for (request, frame) in evaluationFrames where frame == id {
            evaluationFrames[request] = nil
            pendingEvaluations.complete(request, .failure(CefError.frameDetached))
        }
    }

    /// The main frame started loading a new document: evaluations still
    /// waiting for the previous one fail, since its renderer may have gone
    /// before it could answer.
    func mainFrameDidStartLoading() {
        failPendingEvaluations(CefJavaScriptError(
            message: "The page navigated before the script's result was ready.", line: 0, column: 0))
    }

    /// Fails every evaluation still waiting: the renderer went away.
    func failPendingEvaluations(_ error: Error = CefError.browserClosed) {
        evaluationFrames = [:]
        pendingEvaluations.completeAll(.failure(error))
    }

    // MARK: Messages

    /// A page-scripting message, as the client reads it.
    enum Received: Sendable {
        case message(CefProcessMessage)
        case wire(CefPageScriptingMessage.Kind, CefWirePayload)
    }

    /// The generation a `sync` message reports: exactly one `.int`
    /// argument. `nil` for anything else, which a renderer that is not
    /// CefSwift's (or a compromised one) may send.
    nonisolated static func reportedGeneration(_ message: CefProcessMessage) -> Int? {
        guard message.arguments.count == 1, case .int(let generation) = message.arguments[0] else { return nil }
        return Int(generation)
    }

    /// A message from one of the browser's renderers. Returns whether it
    /// was one of page scripting's. A renderer may be compromised, so a
    /// malformed message is dropped (and an evaluation it answers fails);
    /// nothing here trusts its shape.
    func received(_ received: Received, from frame: CefRef<cef_frame_t>) -> Bool {
        switch received {
        case .message(let message) where message.name == CefPageScriptingMessage.sync.text:
            guard let reported = Self.reportedGeneration(message) else {
                CefLog.error("CefPageScripting: dropped a malformed \(message.name) message")
                return true
            }
            // A renderer that had none reports -1; it needs one only if
            // there is something to configure.
            if reported != generation, reported >= 0 || hasConfiguration {
                CefProcessMessage(CefPageScriptingMessage.configure, [.string(configuration.text)])
                    .send(from: frame.pointer, to: PID_RENDERER)
            }
        case .wire(.evaluated, let payload):
            var reader = payload.reader
            guard let header = try? reader.header() else { return true }
            reader.skipHeader()
            let request = Int(header.target)
            if isServiceHost { CefDiagnostics.record(.serviceReplyBytes, amount: payload.bytes.count) }
            evaluationFrames[request] = nil
            if header.succeeded != 0 {
                // Decoding the value validates it; a malformed one throws.
                pendingEvaluations.complete(request, .success(payload))
            } else {
                pendingEvaluations.complete(request, .failure(CefJavaScriptError(
                    message: (try? reader.readString()) ?? "The renderer sent a malformed error.",
                    line: Int(header.line), column: Int(header.column))))
            }
        case .wire(.call, let payload):
            var reader = payload.reader
            reader.skipHeader()
            guard let browser, let name = try? reader.readString(),
                  let bridge = browser.bridges.first(where: { $0.name == name })
            else { return true }
            bridge.received(payload, reader: reader, in: browser, from: frame)
        default:
            return false
        }
        return true
    }
}

extension CefBrowser {
    /// Runs `body` with every frame of the browser.
    fileprivate func forEachFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw = raw?.pointer else { return }
        for identifier in cefStrings({ raw.pointee.get_frame_identifiers(raw, $0) }) {
            guard let frame = CefStringUtil.withCefString(identifier, { raw.pointee.get_frame_by_identifier(raw, $0) })
            else { continue }
            body(frame)
            cefRelease(frame)
        }
    }
}

extension CefUserScript {
    var rendererConfiguration: CefJSON {
        var json: [String: CefJSON] = [
            "source": .string(source),
            "atDocumentEnd": .bool(injectionTime == .documentEnd),
            "mainFrameOnly": .bool(frames == .mainFrame),
        ]
        if !matches.isEmpty { json["matches"] = .array(matches.map(CefJSON.string)) }
        if !excludeMatches.isEmpty { json["excludeMatches"] = .array(excludeMatches.map(CefJSON.string)) }
        return .object(json)
    }
}

