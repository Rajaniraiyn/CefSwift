import AppKit
import CCef
import Foundation

/// Options for a chrome-style browser window created via
/// ``CefChromeBrowser/create(url:options:delegate:)``.
@MainActor
public struct CefChromeBrowserOptions {
    /// Shows Chrome's own toolbar (back/forward/omnibox) inside the window.
    /// `false` (the default) hides Chrome's UI entirely — the window shows
    /// only web content while the full Chrome runtime remains available.
    public var showsChromeToolbar: Bool = false

    /// Creates the CEF window without a frame or title bar (and without the
    /// standard close/minimize/zoom buttons). Used by `CefChromeWebView` to
    /// blend the window into a host app; for standalone windows keep `false`.
    public var isFrameless: Bool = false

    /// Initial window frame in AppKit screen coordinates (points,
    /// bottom-left origin). `nil` centers a default-sized window.
    public var initialBounds: CGRect?

    /// Background color applied before the first paint.
    public var backgroundColor: NSColor?

    public init() {}
}

/// A browser hosted in a CEF Views window running the real **Chrome runtime
/// style** — the full Chrome browser machinery, including the WebUI pages
/// that never render in NSView-embedded (Alloy-style) browsers:
/// `chrome://history`, `chrome://extensions`, `chrome://settings`,
/// `chrome://downloads`, `chrome://flags`, plus extension installs and
/// Chrome profiles.
///
/// The wrapped ``browser`` is an ordinary ``CefBrowser``: delegate events,
/// JavaScript execution, downloads, DevTools and the JS bridge all work
/// exactly as they do for embedded browsers. The window itself is created
/// and owned by CEF (this is what unlocks Chrome style — CEF forces Alloy
/// for `parent_view` embedding); access it via ``nsWindow``.
///
/// Instances are kept alive by CefSwift until their window is destroyed, so
/// fire-and-forget creation is safe:
///
/// ```swift
/// CefChromeBrowser.create(url: URL(string: "chrome://history")!)
/// ```
@MainActor
public final class CefChromeBrowser {
    /// The browser wrapper. Its `id` is `-1` until CEF finishes creating the
    /// browser (views-hosted creation is asynchronous but typically completes
    /// within the `create` call).
    public let browser: CefBrowser

    /// The options this window was created with.
    public let options: CefChromeBrowserOptions

    /// Called after CEF destroys the window (user close, ``close()``, or app
    /// teardown). The instance is unusable afterwards.
    public var onWindowDestroyed: (() -> Void)?

    /// The AppKit window CEF created, once available. CEF owns this window —
    /// don't close or release it directly (use ``close()``); ordering,
    /// frame changes and child-window arrangements are fine.
    public var nsWindow: NSWindow? {
        rootView?.window
    }

    /// The root NSView of the CEF window (its `cef_window_handle_t`).
    public var rootView: NSView? {
        guard let rawWindow,
            let handle = rawWindow.pointee.get_window_handle?(rawWindow)
        else { return nil }
        return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
    }

    /// Whether the CEF window is still alive.
    public var isWindowAlive: Bool { rawWindow != nil }

    // Owned +1 references; nil after the window is destroyed.
    private var rawWindow: UnsafeMutablePointer<cef_window_t>?
    private var rawBrowserView: UnsafeMutablePointer<cef_browser_view_t>?

    // Keep the Swift delegate owners reachable for the window's lifetime
    // (CEF's refs on the structs retain them too; this is belt and braces).
    private var viewDelegate: ChromeBrowserViewDelegate?
    private var windowDelegate: ChromeWindowDelegate?

    /// Instances stay alive until their window is destroyed.
    private static var liveInstances: [ObjectIdentifier: CefChromeBrowser] = [:]

    private init(browser: CefBrowser, options: CefChromeBrowserOptions) {
        self.browser = browser
        self.options = options
    }

    // MARK: Creation

    /// Creates a chrome-style browser window loading `url`.
    ///
    /// Requires an initialized runtime. The window is shown immediately
    /// (at ``CefChromeBrowserOptions/initialBounds`` if set, otherwise
    /// centered). The returned instance is retained by CefSwift until the
    /// window is destroyed.
    @discardableResult
    public static func create(
        url: URL,
        options: CefChromeBrowserOptions = .init(),
        delegate: CefBrowserDelegate? = nil
    ) -> CefChromeBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefChromeBrowser.create requires CefRuntime.shared.initialize() to have succeeded first."
        )

        let client = BrowserClient()
        let clientPointer = client.makeClient()

        // Same wrapper as embedded browsers: all existing functionality
        // (delegate events, bridge, downloads, devtools…) works identically.
        // The raw cef_browser_t is adopted in on_browser_created.
        let cefBrowser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(cefBrowser)

        let chrome = CefChromeBrowser(browser: cefBrowser, options: options)
        liveInstances[ObjectIdentifier(chrome)] = chrome

        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
            settings.background_color = cefColor(color)
        }

        let viewDelegate = ChromeBrowserViewDelegate(chrome: chrome, options: options)
        chrome.viewDelegate = viewDelegate
        // cef_browser_view_create consumes our +1 client and +1 delegate refs
        // and returns a +1 browser view that `chrome` owns.
        chrome.rawBrowserView = CefStringUtil.withCefString(url.absoluteString) { cefURL in
            cef_browser_view_create(clientPointer, cefURL, &settings, nil, nil, viewDelegate.makeStruct())
        }

        let windowDelegate = ChromeWindowDelegate(chrome: chrome, options: options)
        chrome.windowDelegate = windowDelegate
        // Synchronously triggers is_frameless/get_initial_bounds/…, then
        // on_window_created (where the browser view is attached and the
        // window shown). Consumes the +1 delegate ref, returns a +1 window.
        chrome.rawWindow = cef_window_create_top_level(windowDelegate.makeStruct())

        return chrome
    }

    // MARK: Window controls

    /// Shows (or re-shows) the window.
    public func show() {
        guard let rawWindow else { return }
        rawWindow.pointee.show?(rawWindow)
    }

    /// Hides the window without destroying it.
    public func hide() {
        guard let rawWindow else { return }
        rawWindow.pointee.hide?(rawWindow)
    }

    /// Closes the window (and its browser). JavaScript `onbeforeunload`
    /// handlers may prompt first; ``onWindowDestroyed`` fires when done.
    public func close() {
        guard let rawWindow else { return }
        rawWindow.pointee.close?(rawWindow)
    }

    // MARK: Callbacks from delegates

    /// The window exists in the views hierarchy: attach the browser view.
    fileprivate func handleWindowCreated(_ window: UnsafeMutablePointer<cef_window_t>) {
        guard let rawBrowserView else { return }
        // add_child_view consumes one reference on the passed view.
        cefAddRef(UnsafeMutableRawPointer(rawBrowserView))
        let view = UnsafeMutableRawPointer(rawBrowserView).assumingMemoryBound(to: cef_view_t.self)
        withUnsafeMutablePointer(to: &window.pointee.base) { panel in
            panel.pointee.add_child_view?(panel, view)
        }
        if options.initialBounds == nil {
            var size = cef_size_t(width: 1100, height: 760)
            window.pointee.center_window?(window, &size)
        }
        window.pointee.show?(window)
    }

    fileprivate func handleBrowserCreated(_ raw: UnsafeMutablePointer<cef_browser_t>) {
        browser.adoptRaw(raw)
    }

    fileprivate func handleCanClose() -> Bool {
        browser.tryCloseFromWindow()
    }

    fileprivate func handleWindowDestroyed() {
        if let rawWindow {
            cefRelease(UnsafeMutableRawPointer(rawWindow))
        }
        rawWindow = nil
        if let rawBrowserView {
            cefRelease(UnsafeMutableRawPointer(rawBrowserView))
        }
        rawBrowserView = nil
        viewDelegate = nil
        windowDelegate = nil
        onWindowDestroyed?()
        Self.liveInstances[ObjectIdentifier(self)] = nil
    }

    // MARK: Helpers

    /// Converts AppKit screen coordinates (bottom-left origin) to CEF DIP
    /// screen coordinates (top-left origin of the primary display).
    static func cefScreenRect(from appKitRect: CGRect) -> cef_rect_t {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? appKitRect.maxY
        return cef_rect_t(
            x: Int32(appKitRect.origin.x.rounded()),
            y: Int32((primaryHeight - appKitRect.maxY).rounded()),
            width: Int32(appKitRect.width.rounded()),
            height: Int32(appKitRect.height.rounded())
        )
    }

    /// Converts an sRGB NSColor to CEF's ARGB `cef_color_t`.
    private static func cefColor(_ color: NSColor) -> cef_color_t {
        let a = UInt32((color.alphaComponent * 255).rounded()) & 0xFF
        let r = UInt32((color.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((color.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((color.blueComponent * 255).rounded()) & 0xFF
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}

// MARK: - cef_browser_view_delegate_t bridge

/// Swift owner behind a `cef_browser_view_delegate_t`. One instance per
/// browser view; popup browser views get their own (chrome-less) instance so
/// popup toolbar configuration is inherited without cross-wiring browsers.
@MainActor
final class ChromeBrowserViewDelegate {
    /// nil for popup-view delegates (no CefChromeBrowser to wire back to).
    private weak var chrome: CefChromeBrowser?
    private let options: CefChromeBrowserOptions

    init(chrome: CefChromeBrowser?, options: CefChromeBrowserOptions) {
        self.chrome = chrome
        self.options = options
    }

    private nonisolated static func owner(_ cefSelf: UnsafeMutableRawPointer?) -> ChromeBrowserViewDelegate? {
        cefOwner(ChromeBrowserViewDelegate.self, cefSelf)
    }

    /// Builds the delegate struct. The returned pointer carries one reference
    /// owned by the caller (transferred to CEF at browser view creation).
    func makeStruct() -> UnsafeMutablePointer<cef_browser_view_delegate_t> {
        let d = cefAllocate(cef_browser_view_delegate_t.self, owner: self)

        d.pointee.on_browser_created = { delegateSelf, browserView, rawBrowser in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)),
                let rawBrowser
            else {
                cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
                return
            }
            MainActor.assumeIsolated {
                guard let chrome = me.chrome else {
                    // Popup browser views have no wrapper; drop our +1.
                    cefRelease(UnsafeMutableRawPointer(rawBrowser))
                    return
                }
                // Transfers the +1 to the CefBrowser wrapper.
                chrome.handleBrowserCreated(rawBrowser)
            }
        }

        d.pointee.on_browser_destroyed = { _, browserView, rawBrowser in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            cefRelease(rawBrowser.map(UnsafeMutableRawPointer.init))
            // Browser teardown is handled via cef_life_span_handler_t
            // (BrowserClient.on_before_close → CefBrowser.handleBeforeClose).
        }

        d.pointee.get_delegate_for_popup_browser_view = { delegateSelf, browserView, _, popupClient, _ in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            cefRelease(popupClient.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return nil
            }
            // (Pointer return types aren't Sendable, so hop manually.)
            nonisolated(unsafe) var result: UnsafeMutablePointer<cef_browser_view_delegate_t>?
            MainActor.assumeIsolated {
                // Fresh delegate so the popup inherits toolbar config but has
                // no back-reference to the originating CefChromeBrowser.
                let popupDelegate = ChromeBrowserViewDelegate(chrome: nil, options: me.options)
                // The struct's initial +1 transfers to CEF via this return.
                result = popupDelegate.makeStruct()
            }
            return result
        }

        d.pointee.on_popup_browser_view_created = { _, browserView, popupBrowserView, _ in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            cefRelease(popupBrowserView.map(UnsafeMutableRawPointer.init))
            // Return 0: CEF creates a default top-level window for the popup
            // (DevTools windows included), using the popup view delegate above.
            return 0
        }

        d.pointee.get_chrome_toolbar_type = { delegateSelf, browserView in
            cefRelease(browserView.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeBrowserViewDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return CEF_CTT_NONE
            }
            return MainActor.assumeIsolated {
                me.options.showsChromeToolbar ? CEF_CTT_NORMAL : CEF_CTT_NONE
            }
        }

        d.pointee.get_browser_runtime_style = { _ in
            // The entire point of this hosting mode.
            CEF_RUNTIME_STYLE_CHROME
        }

        return d
    }
}

// MARK: - cef_window_delegate_t bridge

/// Swift owner behind a `cef_window_delegate_t`.
@MainActor
final class ChromeWindowDelegate {
    private weak var chrome: CefChromeBrowser?
    private let options: CefChromeBrowserOptions

    /// `chrome` is optional for testability; in production it is always set.
    init(chrome: CefChromeBrowser?, options: CefChromeBrowserOptions) {
        self.chrome = chrome
        self.options = options
    }

    private nonisolated static func owner(_ cefSelf: UnsafeMutableRawPointer?) -> ChromeWindowDelegate? {
        cefOwner(ChromeWindowDelegate.self, cefSelf)
    }

    /// Builds the delegate struct. The returned pointer carries one reference
    /// owned by the caller (transferred to CEF at window creation).
    func makeStruct() -> UnsafeMutablePointer<cef_window_delegate_t> {
        let d = cefAllocate(cef_window_delegate_t.self, owner: self)

        d.pointee.on_window_created = { delegateSelf, window in
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)),
                let window
            else {
                cefRelease(window.map(UnsafeMutableRawPointer.init))
                return
            }
            MainActor.assumeIsolated {
                me.chrome?.handleWindowCreated(window)
            }
            cefRelease(UnsafeMutableRawPointer(window))
        }

        d.pointee.on_window_destroyed = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                me.chrome?.handleWindowDestroyed()
            }
        }

        d.pointee.can_close = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 1
            }
            return MainActor.assumeIsolated {
                // Routes through try_close_browser so JS onbeforeunload
                // handlers get their say (mirrors cefsimple's CanClose).
                (me.chrome?.handleCanClose() ?? true) ? 1 : 0
            }
        }

        d.pointee.is_frameless = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 0
            }
            return MainActor.assumeIsolated { me.options.isFrameless ? 1 : 0 }
        }

        d.pointee.with_standard_window_buttons = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return 1
            }
            return MainActor.assumeIsolated { me.options.isFrameless ? 0 : 1 }
        }

        d.pointee.get_initial_bounds = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            guard let me = ChromeWindowDelegate.owner(delegateSelf.map(UnsafeMutableRawPointer.init)) else {
                return cef_rect_t()
            }
            return MainActor.assumeIsolated {
                guard let bounds = me.options.initialBounds else { return cef_rect_t() }
                return CefChromeBrowser.cefScreenRect(from: bounds)
            }
        }

        d.pointee.get_initial_show_state = { delegateSelf, window in
            cefRelease(window.map(UnsafeMutableRawPointer.init))
            return CEF_SHOW_STATE_NORMAL
        }

        d.pointee.get_window_runtime_style = { _ in
            CEF_RUNTIME_STYLE_CHROME
        }

        return d
    }
}
