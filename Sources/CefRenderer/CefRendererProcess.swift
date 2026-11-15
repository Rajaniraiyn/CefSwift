import CCef
import CefBase

/// A feature that runs in renderer processes.
///
/// The helper's render process handler calls every registered extension,
/// in order, on the renderer's main thread, which on macOS is the process's
/// main thread: CEF's `TID_RENDERER`. An extension keeps whatever state it
/// needs per browser and per V8 context, and talks to the browser process
/// with ``CefProcessMessage``s whose names start with its
/// ``messagePrefix``.
@MainActor
protocol CefRendererExtension: AnyObject {
    /// The start of the names of the messages this extension receives,
    /// such as `"cefswift.page."`.
    var messagePrefix: String { get }
    /// A browser has its first frame in this process. `extraInfo` is the
    /// dictionary the browser process created the browser with.
    func browserCreated(_ browserID: Int32, extraInfo: UnsafeMutablePointer<cef_dictionary_value_t>?)
    func browserDestroyed(_ browserID: Int32)
    /// A JavaScript context was created: the main world or an isolated
    /// world of a frame's new document, before any of its scripts run.
    func contextCreated(_ context: V8Context, in frame: CefRendererFrame)
    func contextReleased(_ context: V8Context, in frame: CefRendererFrame)
    /// A message from the browser process for this extension.
    func received(_ message: CefProcessMessage, in frame: CefRendererFrame)
    /// A page-scripting message with a wire payload.
    func received(_ kind: CefPageScriptingMessage.Kind, payload: CefWirePayload, in frame: CefRendererFrame)
}

extension CefRendererExtension {
    func browserCreated(_ browserID: Int32, extraInfo: UnsafeMutablePointer<cef_dictionary_value_t>?) {}
    func browserDestroyed(_ browserID: Int32) {}
    func contextCreated(_ context: V8Context, in frame: CefRendererFrame) {}
    func contextReleased(_ context: V8Context, in frame: CefRendererFrame) {}
    func received(_ message: CefProcessMessage, in frame: CefRendererFrame) {}
    func received(_ kind: CefPageScriptingMessage.Kind, payload: CefWirePayload, in frame: CefRendererFrame) {}
}

/// A frame of a browser, as a renderer sees it.
@MainActor
final class CefRendererFrame {
    private let reference: CefRef<cef_frame_t>
    var raw: UnsafeMutablePointer<cef_frame_t> { reference.pointer }
    let browserID: Int32

    init(adopting frame: UnsafeMutablePointer<cef_frame_t>, browserID: Int32) {
        reference = CefRef(adopting: frame)
        self.browserID = browserID
    }

    var isMain: Bool { raw.pointee.is_main(raw) != 0 }
    var url: String { CefStringUtil.takingUserFree(raw.pointee.get_url(raw)) ?? "" }

    /// The frame's main-world context, created if the document has none yet.
    var mainWorldContext: V8Context? {
        raw.pointee.get_v8_context(raw).map(V8Context.init(adopting:))
    }

    /// Sends `message` to the browser process.
    @discardableResult
    func send(_ message: CefProcessMessage) -> Bool {
        message.send(from: raw, to: PID_BROWSER)
    }
}

/// The `cef_app_t` of helper processes, with the render process handler
/// that drives the registered ``CefRendererExtension``s.
@MainActor
final class CefRendererProcess {
    private let extensions: [CefRendererExtension]
    private nonisolated let schemes: [CefSchemeList.Entry]
    /// Set once, before `cef_execute_process`; read from any thread.
    private nonisolated(unsafe) var renderProcessHandler: UnsafeMutablePointer<cef_render_process_handler_t>?

    init(extensions: [CefRendererExtension], schemes: [CefSchemeList.Entry]) {
        self.extensions = extensions
        self.schemes = schemes
    }

    /// The app object for `cef_execute_process`. It lives as long as the
    /// process.
    func makeApp() -> UnsafeMutablePointer<cef_app_t> {
        let handler = cefAllocate(cef_render_process_handler_t.self, owner: self)
        handler.pointee.on_browser_created = { s, browser, extraInfo in
            let browserID = browser.map { $0.pointee.get_identifier($0) } ?? -1
            cefRelease(browser)
            nonisolated(unsafe) let extraInfo = extraInfo
            CefRendererProcess.with(s) { process in
                process.extensions.forEach { $0.browserCreated(browserID, extraInfo: extraInfo) }
            }
            cefRelease(extraInfo)
        }
        handler.pointee.on_browser_destroyed = { s, browser in
            let browserID = browser.map { $0.pointee.get_identifier($0) } ?? -1
            cefRelease(browser)
            CefRendererProcess.with(s) { process in
                process.extensions.forEach { $0.browserDestroyed(browserID) }
            }
        }
        handler.pointee.on_context_created = { s, browser, frame, context in
            CefRendererProcess.dispatch(s, browser, frame, context) { process, context, frame in
                process.extensions.forEach { $0.contextCreated(context, in: frame) }
            }
        }
        handler.pointee.on_context_released = { s, browser, frame, context in
            CefRendererProcess.dispatch(s, browser, frame, context) { process, context, frame in
                process.extensions.forEach { $0.contextReleased(context, in: frame) }
            }
        }
        handler.pointee.on_process_message_received = { s, browser, frame, _, message in
            let browserID = browser.map { $0.pointee.get_identifier($0) } ?? -1
            cefRelease(browser)
            guard let owned = CefOwned(message), let process = cefOwner(CefRendererProcess.self, s) else {
                cefRelease(frame)
                return 0
            }
            let message = owned.pointer
            guard let frame else { return 0 }
            // Page-scripting payloads are read in place; only other
            // messages are copied into a `CefProcessMessage`.
            let name = message.pointee.get_name(message)
            let kind = CefPageScriptingMessage.Kind(name: name)
            cef_string_userfree_utf16_free(name)
            let payload = kind?.isWire == true ? CefWirePayload(message: message) : nil
            let received = payload == nil ? CefProcessMessage(reading: message) : nil
            nonisolated(unsafe) let raw = frame
            return MainActor.assumeIsolated {
                let frame = CefRendererFrame(adopting: raw, browserID: browserID)
                if let kind, let payload {
                    guard let target = process.extensions.first(where: { $0.messagePrefix == CefPageScriptingMessage.prefix.description })
                    else { return 0 }
                    target.received(kind, payload: payload, in: frame)
                    return 1
                }
                guard let received,
                      let target = process.extensions.first(where: { received.name.hasPrefix($0.messagePrefix) })
                else { return 0 }
                target.received(received, in: frame)
                return 1
            }
        }
        renderProcessHandler = handler

        let app = cefAllocate(cef_app_t.self, owner: self)
        app.pointee.get_render_process_handler = { s in
            cefRetained(cefOwner(CefRendererProcess.self, s)?.renderProcessHandler)
        }
        app.pointee.on_register_custom_schemes = { s, registrar in
            guard let registrar, let process = cefOwner(CefRendererProcess.self, s) else { return }
            CefSchemeList.register(process.schemes, with: registrar)
        }
        return app
    }

    // MARK: Callback plumbing

    /// Runs `body` with the process object on the main thread, where CEF
    /// calls every handler of a renderer. Returns whether the object exists.
    @discardableResult
    private nonisolated static func with<S>(
        _ cefSelf: UnsafeMutablePointer<S>?, _ body: @MainActor (CefRendererProcess) -> Void
    ) -> Bool {
        guard let process = cefOwner(CefRendererProcess.self, cefSelf) else { return false }
        MainActor.assumeIsolated { body(process) }
        return true
    }

    private nonisolated static func dispatch<S>(
        _ cefSelf: UnsafeMutablePointer<S>?,
        _ browser: UnsafeMutablePointer<cef_browser_t>?,
        _ frame: UnsafeMutablePointer<cef_frame_t>?,
        _ context: UnsafeMutablePointer<cef_v8_context_t>?,
        _ body: @MainActor (CefRendererProcess, V8Context, CefRendererFrame) -> Void
    ) {
        let browserID = browser.map { $0.pointee.get_identifier($0) } ?? -1
        cefRelease(browser)
        guard let frame, let context else {
            cefRelease(frame)
            cefRelease(context)
            return
        }
        nonisolated(unsafe) let rawFrame = frame
        nonisolated(unsafe) let rawContext = context
        let handled = with(cefSelf) { process in
            body(process, V8Context(adopting: rawContext), CefRendererFrame(adopting: rawFrame, browserID: browserID))
        }
        if !handled {
            cefRelease(rawFrame)
            cefRelease(rawContext)
        }
    }
}
