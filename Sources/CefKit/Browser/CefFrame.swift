import CCef
import CefBase
import Foundation

/// One frame of a page: the main frame or an `iframe`, as Chromium reports
/// it.
///
/// A browser's ``CefBrowser/frames`` lists the frames connected to a
/// renderer now. A value is a snapshot; read the browser's list again for
/// the frame's current address.
///
/// ```swift
/// for frame in browser.frames where !frame.isMain {
///     let title = try await browser.evaluateJavaScript("document.title", in: frame)
///     print(frame.url as Any, title)
/// }
/// ```
public struct CefFrame: Sendable, Hashable, Identifiable {
    /// Chromium's identifier for the frame, unique within the browser
    /// process for its lifetime. A cross-site navigation of a frame gives it
    /// a new identifier.
    public let id: String
    /// The document's address; `nil` before the frame loads one.
    public internal(set) var url: URL?
    /// The frame's name: the `name` attribute of its `iframe`, or what the
    /// page set `window.name` to. Empty for most frames.
    public internal(set) var name: String
    /// Whether this is the page's main (top-level) frame.
    public internal(set) var isMain: Bool
    /// The identifier of the frame that contains this one; `nil` for the
    /// main frame.
    public let parentID: String?
    /// The origin of the frame's document (`"https://example.com"`), as the
    /// browser process establishes it from its own record of the frame's
    /// address, as ``CefBridge`` does for its callers: the address's
    /// origin; for `about:blank` and `about:srcdoc`, the nearest parent
    /// frame's; for `blob:https://example.com/…`, the one it names;
    /// `"file://"` for a top-level `file:` page. `nil` when the address
    /// gives an opaque origin (`data:`, a top-level `about:blank`, a
    /// `file:` subframe). A sandboxed document's origin is opaque although
    /// its address has one; ``CefBridge/Call/origin`` tells that case apart
    /// with the renderer's report.
    public internal(set) var origin: String?

    public init(id: String, url: URL?, name: String = "", isMain: Bool, parentID: String? = nil, origin: String? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.isMain = isMain
        self.parentID = parentID
        self.origin = origin
    }

    /// Reads a frame CEF passed in, without taking its reference. Any
    /// thread.
    init(reading frame: UnsafeMutablePointer<cef_frame_t>) {
        id = CefStringUtil.takingUserFree(frame.pointee.get_identifier(frame)) ?? ""
        let address = CefStringUtil.takingUserFree(frame.pointee.get_url(frame))
        url = address.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        origin = CefBridge.addressOrigin(ofFrame: frame, url: address)
        name = CefStringUtil.takingUserFree(frame.pointee.get_name(frame)) ?? ""
        isMain = frame.pointee.is_main(frame) != 0
        if let parent = frame.pointee.get_parent(frame) {
            parentID = CefStringUtil.takingUserFree(parent.pointee.get_identifier(parent))
            cefRelease(parent)
        } else {
            parentID = nil
        }
    }
}

// MARK: - Frame list

/// Keeps ``CefBrowser/frames`` in step with Chromium's frame handler.
///
/// Only attached frames are listed: Chromium also creates temporary frames
/// for cross-site loads that never attach and are dropped once the real
/// frame exists in its renderer.
extension CefBrowser {
    /// The frame with `id`, if it is attached.
    public func frame(withID id: CefFrame.ID) -> CefFrame? {
        frames.first { $0.id == id }
    }

    func frameDidAttach(_ frame: CefFrame) {
        if let index = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[index] = frame
        } else if frame.isMain {
            frames.insert(frame, at: 0)
        } else {
            frames.append(frame)
        }
    }

    func frameDidDetach(_ id: CefFrame.ID) {
        frames.removeAll { $0.id == id }
        pageScripting.frameDidDetach(id)
    }

    func mainFrameDidChange(from old: CefFrame.ID?, to new: CefFrame.ID?) {
        for index in frames.indices where frames[index].id == old || frames[index].id == new {
            frames[index].isMain = frames[index].id == new
        }
    }

    /// A frame started or finished loading, or changed its address, which
    /// gives it a new origin.
    func frameDidUpdate(_ id: CefFrame.ID, url: URL?) {
        guard let index = frames.firstIndex(where: { $0.id == id }), frames[index].url != url else { return }
        frames[index].url = url
        withFrame(id) { frames[index].origin = CefBridge.addressOrigin(ofFrame: $0, url: url?.absoluteString) }
    }

    /// Runs `body` with the live frame `id`, if there is one.
    func withFrame(_ id: CefFrame.ID, _ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw = raw?.pointer,
              let frame = CefStringUtil.withCefString(id, { raw.pointee.get_frame_by_identifier(raw, $0) })
        else { return }
        defer { cefRelease(frame) }
        guard frame.pointee.is_valid(frame) != 0 else { return }
        body(frame)
    }

    /// Evaluates JavaScript in `frame` and returns its value, as
    /// ``evaluateJavaScript(_:userGesture:timeout:)`` does in the main frame.
    ///
    /// The script runs in the frame's main world through the helper's
    /// renderer code, in whichever renderer process shows the frame;
    /// cross-site frames included. It throws ``CefError/frameDetached``
    /// when the frame is gone, before or while it runs, and
    /// ``CefError/timedOut`` when `timeout` runs out first, leaving the
    /// script running.
    @discardableResult
    public func evaluateJavaScript(_ script: String, in frame: CefFrame, timeout: Duration? = nil) async throws -> CefJSON {
        try await evaluateJavaScript(script, as: CefJSON.self, in: frame, timeout: timeout)
    }

    /// Evaluates JavaScript in `frame` and decodes its value as `T`.
    public func evaluateJavaScript<T: Decodable>(
        _ script: String, as type: T.Type = T.self, in frame: CefFrame, timeout: Duration? = nil
    ) async throws -> T {
        try await withOptionalDeadline(timeout) { [self] in try await pageScripting.evaluate(script, as: T.self, in: frame.id) }
    }

    /// Runs JavaScript in `frame` without waiting for a result. Does
    /// nothing when the frame is gone.
    public func executeJavaScript(_ script: String, in frame: CefFrame) {
        withFrame(frame.id) { raw in
            CefStringUtil.withCefString(script) { raw.pointee.execute_java_script(raw, $0, nil, 0) }
        }
    }
}

// MARK: - Frame handler

extension CefBrowserClient {
    func makeFrameHandler() -> UnsafeMutablePointer<cef_frame_handler_t> {
        let h = cefAllocate(cef_frame_handler_t.self, owner: self)
        h.pointee.on_frame_attached = { s, browser, frame, _ in
            let value = frame.map(CefFrame.init(reading:))
            defer { cefRelease(frame) }
            nonisolated(unsafe) let raw = frame

            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if let value { b.frameDidAttach(value) }
                if let raw { b.pageScripting.frameDidAttach(raw) }
            }
        }
        h.pointee.on_frame_detached = { s, browser, frame in
            let id = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            cefRelease(frame)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if let id { b.frameDidDetach(id) }
            }
        }
        h.pointee.on_main_frame_changed = { s, browser, old, new in
            let oldID = old.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            let newID = new.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            cefRelease(old)
            cefRelease(new)
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.mainFrameDidChange(from: oldID, to: newID) }
        }
        // Created and destroyed frames need nothing: a frame is listed from
        // attaching to detaching.
        h.pointee.on_frame_created = { _, browser, frame in
            cefRelease(frame)
            cefRelease(browser)
        }
        h.pointee.on_frame_destroyed = { _, browser, frame in
            cefRelease(frame)
            cefRelease(browser)
        }
        return h
    }
}
