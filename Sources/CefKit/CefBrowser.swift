import AppKit
import CCef
import Foundation

/// A live CEF browser embedded in an NSView hierarchy. Create instances via
/// ``CefBrowserFactory/createBrowser(parentView:bounds:url:options:delegate:)``.
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
