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
    /// Counts configuration changes; the renderer keeps the newest.
    private(set) var generation = 0
    private var nextRequest = 0
    private var pendingEvaluations: [Int: CheckedContinuation<CefJSON, Error>] = [:]

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
        return Self.configuration(bridges: browser.options.bridges, scripts: browser.userScripts, generation: generation)
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

    func makeExtraInfo() -> UnsafeMutablePointer<cef_dictionary_value_t>? {
        Self.makeExtraInfo(configuration)
    }

    /// Sends the browser's configuration to every renderer that shows one
    /// of its frames. Documents loaded from then on use it.
    func configurationDidChange() {
        generation += 1
        let message = CefProcessMessage(CefPageScriptingMessage.configure, [.string(configuration.text)])
        browser?.forEachFrame { message.send(from: $0, to: PID_RENDERER) }
    }

    // MARK: Evaluation

    /// Runs `script` in the main frame's main world and returns its value.
    func evaluate(_ script: String) async throws -> CefJSON {
        guard let browser else { throw CefError.browserClosed }
        try await browser.ready()
        nextRequest += 1
        let request = nextRequest
        return try await withCheckedThrowingContinuation { continuation in
            pendingEvaluations[request] = continuation
            var sent = false
            browser.withMainFrame { frame in
                sent = CefProcessMessage(CefPageScriptingMessage.evaluate, [.int(Int32(request)), .string(script)])
                    .send(from: frame, to: PID_RENDERER)
            }
            if !sent, let continuation = pendingEvaluations.removeValue(forKey: request) {
                continuation.resume(throwing: CefError.browserClosed)
            }
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
        let pending = pendingEvaluations
        pendingEvaluations = [:]
        pending.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: Messages

    /// A message from one of the browser's renderers. Returns whether it
    /// was one of page scripting's.
    func received(_ message: CefProcessMessage, from frame: CefRef<cef_frame_t>) -> Bool {
        switch message.name {
        case CefPageScriptingMessage.sync:
            if message.int(0) < generation {
                CefProcessMessage(CefPageScriptingMessage.configure, [.string(configuration.text)])
                    .send(from: frame.pointer, to: PID_RENDERER)
            }
        case CefPageScriptingMessage.evaluated:
            guard let continuation = pendingEvaluations.removeValue(forKey: message.int(0)) else { return true }
            if message.bool(1) {
                continuation.resume(returning: (try? CefJSON(data: Data(message.string(2).utf8))) ?? .null)
            } else {
                continuation.resume(throwing: CefJavaScriptError(
                    message: message.string(2), line: message.int(3), column: message.int(4)))
            }
        case CefPageScriptingMessage.call:
            guard let browser, let bridge = browser.options.bridges.first(where: { $0.name == message.string(0) }) else {
                return true
            }
            bridge.received(message, in: browser, from: frame)
        default:
            return false
        }
        return true
    }
}

extension CefBrowser {
    /// Runs `body` with every frame of the browser.
    func forEachFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw = raw?.pointer, let list = cef_string_list_alloc() else { return }
        defer { cef_string_list_free(list) }
        raw.pointee.get_frame_identifiers(raw, list)
        for identifier in cefStrings(from: list) {
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
        if let urlPattern { json["urlPattern"] = .string(urlPattern) }
        return .object(json)
    }
}

