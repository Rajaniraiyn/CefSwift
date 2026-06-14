import AppKit
import CCef
import Foundation

// MARK: - CefMouseButton

/// A mouse button for OSR input forwarding.
public enum CefMouseButton: Sendable {
    case left, middle, right

    var cefValue: cef_mouse_button_type_t {
        switch self {
        case .left: return MBT_LEFT
        case .middle: return MBT_MIDDLE
        case .right: return MBT_RIGHT
        }
    }
}

// MARK: - CefBrowser

/// A live CEF browser embedded in an NSView hierarchy. Create instances via
/// ``CefBrowser/createBrowser(parentView:bounds:url:options:delegate:)``.
///
/// All members are main-actor isolated; CEF's UI thread is the main thread
/// when using the external message pump.
@MainActor
public final class CefBrowser: Identifiable {
    /// CEF's browser identifier (unique per process; `-1` if creation failed
    /// or, for views-hosted browsers, until creation completes).
    ///
    /// `nonisolated(unsafe)` keeps the `Identifiable` conformance nonisolated
    /// (as it was when this was a `let`): written only on the main actor (at
    /// init and in `adoptRaw`), so cross-actor reads are benign.
    nonisolated(unsafe) public private(set) var id: Int32

    /// Event observer. Held weakly.
    public weak var delegate: CefBrowserDelegate?

    /// Current main-frame URL.
    public private(set) var url: URL?
    /// Current page title.
    public private(set) var title: String = ""
    /// Whether the browser is currently loading.
    public private(set) var isLoading: Bool = false
    /// Whether back navigation is possible.
    public private(set) var canGoBack: Bool = false
    /// Whether forward navigation is possible.
    public private(set) var canGoForward: Bool = false

    /// Owned +1 reference to the underlying cef_browser_t; nil after close.
    private var raw: UnsafeMutablePointer<cef_browser_t>?
    let client: BrowserClient?

    init(raw: UnsafeMutablePointer<cef_browser_t>?, client: BrowserClient?, delegate: CefBrowserDelegate?) {
        self.raw = raw
        self.client = client
        self.delegate = delegate
        self.id = raw.map { $0.pointee.get_identifier?($0) ?? -1 } ?? -1
    }

    // MARK: Navigation

    /// Navigates the main frame to `url`.
    public func load(_ url: URL) {
        withMainFrame { frame in
            CefStringUtil.withCefString(url.absoluteString) { cefURL in
                frame.pointee.load_url?(frame, cefURL)
            }
        }
    }

    /// Navigates back in session history.
    public func goBack() {
        guard let raw else { return }
        raw.pointee.go_back?(raw)
    }

    /// Navigates forward in session history.
    public func goForward() {
        guard let raw else { return }
        raw.pointee.go_forward?(raw)
    }

    /// Reloads the current page.
    public func reload(ignoreCache: Bool = false) {
        guard let raw else { return }
        if ignoreCache {
            raw.pointee.reload_ignore_cache?(raw)
        } else {
            raw.pointee.reload?(raw)
        }
    }

    /// Cancels the current load.
    public func stopLoading() {
        guard let raw else { return }
        raw.pointee.stop_load?(raw)
    }

    /// Executes JavaScript in the main frame.
    public func executeJavaScript(_ script: String) {
        withMainFrame { frame in
            CefStringUtil.withCefString(script) { code in
                CefStringUtil.withCefString(url?.absoluteString ?? "about:blank") { scriptURL in
                    frame.pointee.execute_java_script?(frame, code, scriptURL, 0)
                }
            }
        }
    }

    // MARK: Host controls

    /// Page zoom level (0 = default; each unit is a ~20% zoom step).
    public var zoomLevel: Double {
        get { withHost { $0.pointee.get_zoom_level?($0) ?? 0 } ?? 0 }
        set { withHost { $0.pointee.set_zoom_level?($0, newValue) } }
    }

    /// Mutes or unmutes page audio.
    public var isAudioMuted: Bool {
        get { withHost { ($0.pointee.is_audio_muted?($0) ?? 0) != 0 } ?? false }
        set { withHost { $0.pointee.set_audio_muted?($0, newValue ? 1 : 0) } }
    }

    /// Opens Chrome DevTools for this browser in its own window. No-op if a
    /// DevTools window is already open (CEF brings it to front).
    public func showDevTools() {
        withHost { host in
            var windowInfo = cef_window_info_t()
            windowInfo.size = MemoryLayout<cef_window_info_t>.stride
            // Give DevTools a real top-level window rather than a zero-rect:
            // parent_view stays nil so CEF creates its own NSWindow.
            windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: 900, height: 700)
            windowInfo.runtime_style = CEF_RUNTIME_STYLE_DEFAULT
            var settings = cef_browser_settings_t()
            settings.size = MemoryLayout<cef_browser_settings_t>.stride
            host.pointee.show_dev_tools?(host, &windowInfo, nil, &settings, nil)
        }
    }

    /// Closes the DevTools window, if open.
    public func closeDevTools() {
        withHost { $0.pointee.close_dev_tools?($0) }
    }

    /// Whether a DevTools window is currently open for this browser.
    public var hasDevTools: Bool {
        withHost { ($0.pointee.has_dev_tools?($0) ?? 0) != 0 } ?? false
    }

    /// Opens DevTools if closed, closes it if open.
    public func toggleDevTools() {
        if hasDevTools {
            closeDevTools()
        } else {
            showDevTools()
        }
    }

    /// Searches the page for `text`.
    public func find(_ text: String, forward: Bool, matchCase: Bool) {
        withHost { host in
            CefStringUtil.withCefString(text) { cefText in
                host.pointee.find?(host, cefText, forward ? 1 : 0, matchCase ? 1 : 0, 0)
            }
        }
    }

    /// Requests that the browser close. With `force: false` JavaScript
    /// `onbeforeunload` handlers may cancel the close; ``CefBrowserDelegate/browserDidClose(_:)``
    /// fires when the close completes.
    public func close(force: Bool = false) {
        withHost { $0.pointee.close_browser?($0, force ? 1 : 0) }
    }

    /// The NSView CEF created for this browser, once available. Add it to
    /// your view hierarchy is not required (CEF parents it automatically);
    /// use it for sizing/focus.
    public var nativeView: NSView? {
        withHost { host -> NSView? in
            guard let handle = host.pointee.get_window_handle?(host) else { return nil }
            return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
        } ?? nil
    }

    // MARK: Internal plumbing

    /// Adopts a raw browser after the fact (views-hosted browsers are created
    /// asynchronously by CEF; ``CefChromeBrowser`` calls this from
    /// `on_browser_created`). Takes ownership of the caller's +1 reference.
    /// If a raw browser is already owned the extra reference is released —
    /// this guards against popup browsers reusing the same client.
    func adoptRaw(_ newRaw: UnsafeMutablePointer<cef_browser_t>) {
        guard raw == nil else {
            cefRelease(UnsafeMutableRawPointer(newRaw))
            return
        }
        raw = newRaw
        id = newRaw.pointee.get_identifier?(newRaw) ?? -1
        CefRuntime.shared.registerBrowser(self)
    }

    /// Whether a live raw cef_browser_t is attached.
    var hasRawBrowser: Bool { raw != nil }

    /// Module-internal raw `cef_browser_t` accessor for the editing extension
    /// (used to resolve the focused/main frame for clipboard commands).
    var rawBrowserPointer: UnsafeMutablePointer<cef_browser_t>? { raw }

    /// Calls `try_close_browser` on the host: gives JavaScript
    /// `onbeforeunload` handlers their say, then proceeds with the close.
    /// Used by the views window delegate's `can_close`.
    func tryCloseFromWindow() -> Bool {
        withHost { ($0.pointee.try_close_browser?($0) ?? 1) != 0 } ?? true
    }

    /// Runs `body` with a +1 host reference, releasing it afterwards.
    private func withHost<R>(_ body: (UnsafeMutablePointer<cef_browser_host_t>) -> R) -> R? {
        guard let raw, let host = raw.pointee.get_host?(raw) else { return nil }
        defer { cefRelease(UnsafeMutableRawPointer(host)) }
        return body(host)
    }

    /// Module-internal host accessor for the OSR input extension.
    func withHostInternal(_ body: (UnsafeMutablePointer<cef_browser_host_t>) -> Void) {
        withHost(body)
    }

    /// Runs `body` with a +1 main-frame reference, releasing it afterwards.
    private func withMainFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw, let frame = raw.pointee.get_main_frame?(raw) else { return }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        body(frame)
    }

    // State updates from BrowserClient (CEF UI thread == main thread).

    func applyTitle(_ title: String) {
        self.title = title
        delegate?.browser(self, didChangeTitle: title)
    }

    func applyURL(_ urlString: String) {
        let url = URL(string: urlString)
        self.url = url
        delegate?.browser(self, didChangeURL: url)
    }

    func applyLoadingState(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        delegate?.browser(self, didChangeLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func handleBeforeClose() {
        delegate?.browserDidClose(self)
        if let raw {
            cefRelease(UnsafeMutableRawPointer(raw))
        }
        raw = nil
        CefRuntime.shared.unregisterBrowser(id: id)
    }
}

// MARK: - Factory

extension CefBrowser {
    /// Creates a windowed browser as a child of `parentView` filling
    /// `bounds` (parent-view coordinates).
    ///
    /// Requires an initialized runtime (``CefRuntime/initialize(configuration:)``)
    /// and a `parentView` that is part of a window. Creation is synchronous;
    /// the returned browser is live (its ``CefBrowser/nativeView`` exists)
    /// unless creation failed, in which case `id == -1`.
    ///
    /// - Note: CEF always uses Alloy runtime style for browsers embedded via
    ///   a parent view, regardless of ``CefBrowserOptions/runtimeStyle``.
    public static func createBrowser(
        parentView: NSView,
        bounds: CGRect,
        url: URL,
        options: CefBrowserOptions = .init(),
        delegate: CefBrowserDelegate?
    ) -> CefBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefBrowser.createBrowser requires CefRuntime.shared.initialize() to have succeeded first."
        )

        let client = BrowserClient()
        let clientPointer = client.makeClient()

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.bounds = cef_rect_t(
            x: Int32(bounds.origin.x.rounded()),
            y: Int32(bounds.origin.y.rounded()),
            width: Int32(bounds.size.width.rounded()),
            height: Int32(bounds.size.height.rounded())
        )
        windowInfo.parent_view = Unmanaged.passUnretained(parentView).toOpaque()
        // Fall back to the runtime-wide default style when the per-browser
        // option is .default.
        var style = options.runtimeStyle
        if case .default = style,
            let configured = CefRuntime.shared.configuration?.defaultRuntimeStyle
        {
            style = configured
        }
        windowInfo.runtime_style = style.cefValue

        var browserSettings = cef_browser_settings_t()
        browserSettings.size = MemoryLayout<cef_browser_settings_t>.stride
        if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
            browserSettings.background_color = cefColorFromNSColor(color)
        }

        let requestContext = options.profile?.makeRequestContext()

        let rawBrowser = CefStringUtil.withCefString(url.absoluteString) { cefURL in
            cef_browser_host_create_browser_sync(&windowInfo, clientPointer, cefURL, &browserSettings, nil, requestContext)
        }

        let browser = CefBrowser(raw: rawBrowser, client: client, delegate: delegate)
        client.attach(browser)
        CefRuntime.shared.registerBrowser(browser)
        return browser
    }

    /// Creates an **offscreen-rendered** (OSR) browser with no CEF-owned
    /// window: Chromium paints into a shared `IOSurface` delivered to `host`
    /// via the render handler, so the host can composite the pixels into a
    /// genuine in-tree `CALayer`/`CAMetalLayer`. This is the "indistinguishable
    /// embedded web view" mode.
    ///
    /// Requires ``CefConfiguration/windowlessRenderingEnabled`` to have been
    /// `true` when the runtime was initialized — otherwise this traps with an
    /// actionable message.
    ///
    /// Creation is asynchronous (CEF calls back into `on_after_created`); the
    /// returned ``CefBrowser`` has `id == -1` until then but is safe to retain
    /// and to forward input to once frames begin arriving.
    ///
    /// - Parameters:
    ///   - initialSize: Logical (DIP) size of the view.
    ///   - scale: Backing scale factor (e.g. 2.0 on retina).
    ///   - url: Initial URL.
    ///   - options: Background color etc. (runtime style is forced to Alloy).
    ///   - host: The view that supplies geometry and receives frames.
    ///   - delegate: Navigation/state observer (typically the same model).
    public static func createOSRBrowser(
        initialSize: CGSize,
        scale: CGFloat,
        url: URL,
        options: CefBrowserOptions = .init(),
        host: CefOSRHost,
        delegate: CefBrowserDelegate?
    ) -> CefBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefBrowser.createOSRBrowser requires CefRuntime.shared.initialize() to have succeeded first."
        )
        precondition(
            CefRuntime.shared.configuration?.windowlessRenderingEnabled == true,
            """
            CefBrowser.createOSRBrowser requires windowless rendering. Set \
            `configuration.windowlessRenderingEnabled = true` before \
            CefRuntime.shared.initialize(configuration:).
            """
        )

        let client = BrowserClient()
        client.osrHost = host
        let clientPointer = client.makeClient()

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.windowless_rendering_enabled = 1
        windowInfo.shared_texture_enabled = 1
        // Display-synced painting: the host drives begin-frames from a
        // CADisplayLink so scrolling/animation pace to the real refresh rate.
        windowInfo.external_begin_frame_enabled = 1
        windowInfo.bounds = cef_rect_t(
            x: 0, y: 0,
            width: Int32(max(1, initialSize.width.rounded())),
            height: Int32(max(1, initialSize.height.rounded()))
        )
        // Windowless rendering forces Alloy style on macOS regardless of the
        // requested option.
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY

        var browserSettings = cef_browser_settings_t()
        browserSettings.size = MemoryLayout<cef_browser_settings_t>.stride
        browserSettings.windowless_frame_rate = 60
        if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
            browserSettings.background_color = cefColorFromNSColor(color)
        }

        let requestContext = options.profile?.makeRequestContext()

        let browser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(browser)
        client.pendingOSRBrowser = browser

        _ = CefStringUtil.withCefString(url.absoluteString) { cefURL in
            cef_browser_host_create_browser(&windowInfo, clientPointer, cefURL, &browserSettings, nil, requestContext)
        }
        return browser
    }

    /// Converts an sRGB NSColor to CEF's ARGB `cef_color_t`.
    private static func cefColorFromNSColor(_ color: NSColor) -> cef_color_t {
        let a = UInt32((color.alphaComponent * 255).rounded()) & 0xFF
        let r = UInt32((color.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((color.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((color.blueComponent * 255).rounded()) & 0xFF
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}

// MARK: - OSR Input

extension CefBrowser {

    /// Whether this browser was created in offscreen-rendering mode.
    public var isOffscreen: Bool { client?.osrHost != nil }

    // MARK: Mouse

    private func mouseEvent(at point: CGPoint, modifiers: UInt32) -> cef_mouse_event_t {
        cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers)
    }

    /// Forwards a mouse-move (or mouse-leave when `leaving` is true).
    public func sendMouseMove(to point: CGPoint, modifiers: UInt32, leaving: Bool = false) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_move_event?(host, &event, leaving ? 1 : 0)
        }
    }

    /// Forwards a mouse button press.
    public func sendMouseDown(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_click_event?(host, &event, button.cefValue, 0, Int32(clickCount))
        }
    }

    /// Forwards a mouse button release.
    public func sendMouseUp(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_click_event?(host, &event, button.cefValue, 1, Int32(clickCount))
        }
    }

    /// Forwards a scroll-wheel event. Deltas are in device-independent units.
    public func sendMouseWheel(at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_wheel_event?(host, &event, Int32(deltaX.rounded()), Int32(deltaY.rounded()))
        }
    }

    // MARK: Keyboard

    /// Forwards a raw CEF key event (built by the host view from `NSEvent`).
    public func sendKeyEvent(_ event: cef_key_event_t) {
        withHostInternal { host in
            var e = event
            host.pointee.send_key_event?(host, &e)
        }
    }

    // MARK: Focus

    /// Sets the browser's logical focus (call from `becomeFirstResponder` /
    /// `resignFirstResponder`).
    public func setFocus(_ focused: Bool) {
        withHostInternal { $0.pointee.set_focus?($0, focused ? 1 : 0) }
    }

    // MARK: Geometry

    /// Notifies CEF that the view size changed; CEF re-queries `get_view_rect`
    /// and repaints at the new size.
    public func wasResized() {
        withHostInternal { $0.pointee.was_resized?($0) }
    }

    /// Notifies CEF that the screen scale/geometry changed; CEF re-queries
    /// `get_screen_info` (drives retina correctness).
    public func notifyScreenInfoChanged() {
        withHostInternal { $0.pointee.notify_screen_info_changed?($0) }
    }

    /// Notifies CEF the view's visibility changed (pause painting when hidden).
    public func wasHidden(_ hidden: Bool) {
        withHostInternal { $0.pointee.was_hidden?($0, hidden ? 1 : 0) }
    }

    /// Forces a full repaint of the view.
    public func invalidate() {
        withHostInternal { $0.pointee.invalidate?($0, PET_VIEW) }
    }

    /// Requests one frame from CEF. Used when the browser is created with
    /// `external_begin_frame_enabled`: the host drives this each display tick
    /// (via `CADisplayLink`) so painting is paced to the real display refresh,
    /// giving vsync-smooth scrolling/animation instead of CEF's free-running
    /// internal timer.
    public func sendExternalBeginFrame() {
        withHostInternal { $0.pointee.send_external_begin_frame?($0) }
    }

    // MARK: IME

    /// Begins/updates an IME composition (bridged from `NSTextInputClient.setMarkedText`).
    public func imeSetComposition(text: String, selectionRange: NSRange, replacementRange: NSRange?) {
        withHostInternal { host in
            CefStringUtil.withCefString(text) { cefText in
                var sel = cef_range_t(from: UInt32(max(0, selectionRange.location)),
                                      to: UInt32(max(0, selectionRange.location + selectionRange.length)))
                var underline = cef_composition_underline_t(
                    size: MemoryLayout<cef_composition_underline_t>.stride,
                    range: cef_range_t(from: 0, to: UInt32(text.utf16.count)),
                    color: 0xFF000000, background_color: 0, thick: 0, style: CEF_CUS_SOLID)
                if let replacementRange {
                    var rep = cef_range_t(from: UInt32(max(0, replacementRange.location)),
                                          to: UInt32(max(0, replacementRange.location + replacementRange.length)))
                    host.pointee.ime_set_composition?(host, cefText, 1, &underline, &rep, &sel)
                } else {
                    host.pointee.ime_set_composition?(host, cefText, 1, &underline, nil, &sel)
                }
            }
        }
    }

    /// Commits IME text (bridged from `NSTextInputClient.insertText`).
    public func imeCommitText(_ text: String, replacementRange: NSRange?) {
        withHostInternal { host in
            CefStringUtil.withCefString(text) { cefText in
                if let replacementRange {
                    var rep = cef_range_t(from: UInt32(max(0, replacementRange.location)),
                                          to: UInt32(max(0, replacementRange.location + replacementRange.length)))
                    host.pointee.ime_commit_text?(host, cefText, &rep, 0)
                } else {
                    host.pointee.ime_commit_text?(host, cefText, nil, 0)
                }
            }
        }
    }

    /// Completes the current composition (keeping the selection).
    public func imeFinishComposing(keepSelection: Bool = true) {
        withHostInternal { $0.pointee.ime_finish_composing_text?($0, keepSelection ? 1 : 0) }
    }

    /// Cancels the current composition.
    public func imeCancelComposition() {
        withHostInternal { $0.pointee.ime_cancel_composition?($0) }
    }

    // MARK: Accessibility

    /// Enables or disables accessibility for this browser. When enabled, CEF
    /// builds the AX tree and delivers it via the accessibility handler.
    public func setAccessibilityEnabled(_ enabled: Bool) {
        withHostInternal { $0.pointee.set_accessibility_state?($0, enabled ? STATE_ENABLED : STATE_DISABLED) }
    }
}

// MARK: - Editing

extension CefBrowser {

    /// Runs `body` with the focused frame if one exists, otherwise the main
    /// frame. The frame is a +1 reference released after `body` returns.
    private func withEditingFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let frame = focusedOrMainFrame() else { return }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        body(frame)
    }

    /// Resolves the focused frame, falling back to the main frame. Caller owns
    /// the returned +1 reference.
    private func focusedOrMainFrame() -> UnsafeMutablePointer<cef_frame_t>? {
        guard let raw = rawBrowserPointer else { return nil }
        if let focused = raw.pointee.get_focused_frame?(raw) {
            return focused
        }
        return raw.pointee.get_main_frame?(raw)
    }

    /// Copies the current selection to the clipboard.
    public func copySelection() { withEditingFrame { $0.pointee.copy?($0) } }

    /// Cuts the current selection to the clipboard.
    public func cutSelection() { withEditingFrame { $0.pointee.cut?($0) } }

    /// Pastes the clipboard contents at the caret, preserving source styling.
    public func paste() { withEditingFrame { $0.pointee.paste?($0) } }

    /// Pastes the clipboard contents as plain text (matching the destination
    /// style).
    public func pasteAndMatchStyle() { withEditingFrame { $0.pointee.paste_and_match_style?($0) } }

    /// Deletes the current selection (forward delete).
    public func deleteSelection() { withEditingFrame { $0.pointee.del?($0) } }

    /// Selects all content in the focused frame.
    public func selectAll() { withEditingFrame { $0.pointee.select_all?($0) } }

    /// Undoes the last edit in the focused frame.
    public func undo() { withEditingFrame { $0.pointee.undo?($0) } }

    /// Redoes the last undone edit in the focused frame.
    public func redo() { withEditingFrame { $0.pointee.redo?($0) } }
}
