import AppKit
import CefKit
import SwiftUI

/// A full-browser window running the real **Chrome runtime** that hosts your
/// own SwiftUI chrome (tab strip, omnibox, …) as native overlays — in **one
/// real `NSWindow`**, with no child-window overlay and no frame-syncing.
///
/// This is CefSwift's "full browser" hosting mode (the *inverted-ownership*
/// model). Unlike ``CefWebView`` (Alloy style, NSView-embedded) which cannot
/// composite native UI *over* the page, and unlike ``CefChromeWebView`` (a
/// separate child window overlaid on a SwiftUI window), `CefChromeWindow` puts
/// the full Chrome runtime and your native chrome in the same window:
///
/// - **CEF owns the window.** It is a CEF Views top-level window
///   (`cef_window` + `cef_browser_view`, Chrome style, Chrome's own toolbar
///   hidden). The window is created and driven by CEF, *outside* SwiftUI's
///   `WindowGroup`/`Scene` graph — see "App model" below. That is expected and
///   correct for a browser shell.
/// - **Native overlays composite on top.** ``setOverlay(_:)`` hosts your
///   SwiftUI view in an `NSHostingView` added as a subview of the CEF window's
///   content view, stacked above the browser region.
/// - **Insets, not covering.** ``setContentInsets(_:)`` reserves space by
///   *resizing the browser view* within the window (a CEF BoxLayout), so web
///   content fills the area below your toolbar rather than hiding under it.
/// - **The full Chrome runtime renders.** `chrome://history`,
///   `chrome://extensions`, `chrome://settings`, `chrome://downloads`,
///   `chrome://flags`, extension installs and Chrome profiles all work here —
///   the WebUI pages that render blank in NSView-embedded (Alloy) browsers.
///
/// The wrapped ``browser`` is an ordinary ``CefBrowser``: delegate events,
/// JavaScript execution, downloads, DevTools and the JS bridge work exactly as
/// for embedded browsers.
///
/// ```swift
/// let window = CefChromeWindow.open(url: URL(string: "https://example.com")!)
/// window.setContentInsets(NSEdgeInsets(top: 96, left: 0, bottom: 0, right: 0))
/// window.setOverlay {
///     MyArcChrome()   // tab strip + omnibox, hosted on top
/// }
/// ```
///
/// ### App model (CEF owns the window)
///
/// Because CEF — not SwiftUI — owns this `NSWindow`, it lives outside the
/// SwiftUI `Scene` graph. Don't try to host it in a `WindowGroup`. Instead,
/// open it from an app-level controller (see ``CefChromeWindowController``)
/// once the runtime is up — e.g. from a tiny `WindowGroup`'s `.task`, or an
/// `NSApplicationDelegate`. Keep a strong reference (the controller does this
/// for you); the instance is also retained by CefSwift until its window is
/// destroyed, so fire-and-forget ``open(url:delegate:configure:)`` is safe.
@MainActor
public final class CefChromeWindow: Identifiable {

    /// The wrapped browser. Full delegate / JS / download / DevTools surface
    /// works exactly as for ``CefWebView``.
    public let browser: CefBrowser

    /// Called after the window is destroyed (user close, ``close()``, or app
    /// teardown). The instance is unusable afterwards.
    public var onClose: (() -> Void)?

    /// The CEF-owned `NSWindow`, once available. CEF owns it — drive lifecycle
    /// through ``show()`` / ``close()`` rather than closing it directly.
    public var nsWindow: NSWindow? { chrome.nsWindow }

    /// Whether the window is still alive.
    public var isAlive: Bool { chrome.isWindowAlive }

    /// The underlying chrome browser (CEF Views window). Exposed for advanced
    /// use; prefer this type's API.
    public let chrome: CefChromeBrowser

    // NSTitlebarAccessoryViewController hosting the SwiftUI overlay.
    // Lives in the window's titlebar area — fully outside CEF's content view —
    // so text fields, buttons and menus get proper AppKit key-view routing.
    private var titlebarAccessory: NSTitlebarAccessoryViewController?
    private var insets = NSEdgeInsets()
    private var resizeObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    private init(chrome: CefChromeBrowser) {
        self.chrome = chrome
        self.browser = chrome.browser
    }

    // MARK: Creation

    /// Opens a Chrome-runtime browser window loading `url`.
    ///
    /// Requires an initialized runtime (use ``CefSwiftApp`` or
    /// `CefRuntime.shared.initialize()`). The window is shown immediately.
    ///
    /// - Parameters:
    ///   - url: The page to load.
    ///   - initialBounds: Initial window frame in AppKit screen coordinates
    ///     (points, bottom-left origin). `nil` centers a default-sized window.
    ///   - backgroundColor: Background painted before the first frame.
    ///   - delegate: Optional ``CefBrowserDelegate`` for navigation/JS/download
    ///     events. (A ``CefWebViewModel`` is a delegate, so you can pass one.)
    ///   - configure: Called once with the new window before it returns — the
    ///     place to call ``setContentInsets(_:)`` and ``setOverlay(_:)``.
    @discardableResult
    public static func open(
        url: URL,
        initialBounds: CGRect? = nil,
        backgroundColor: NSColor? = nil,
        delegate: CefBrowserDelegate? = nil,
        configure: ((CefChromeWindow) -> Void)? = nil
    ) -> CefChromeWindow {
        var options = CefChromeBrowserOptions()
        options.showsChromeToolbar = false   // Chrome's own toolbar hidden (CEF_CTT_NONE).
        options.isFrameless = false          // a real top-level window with traffic lights.
        options.initialBounds = initialBounds
        options.backgroundColor = backgroundColor

        let chrome = CefChromeBrowser.create(url: url, options: options, delegate: delegate)
        let window = CefChromeWindow(chrome: chrome)
        Self.liveInstances.insert(window)

        chrome.onWindowDestroyed = { [weak window] in
            guard let window else { return }
            window.teardown()
            window.onClose?()
            Self.liveInstances.remove(window)
        }

        // The CEF Views window is created synchronously inside create(), so the
        // content view is already available — wire overlay tracking now.
        window.bindWindowObservers()
        configure?(window)
        return window
    }

    // MARK: Overlay + insets

    /// Hosts a SwiftUI view as a native overlay stacked **above** the browser
    /// view, inside the same window. Replaces any previous overlay.
    ///
    /// The overlay fills the window by default; pair it with
    /// ``setContentInsets(_:)`` so the page isn't obscured (typically the
    /// overlay draws an opaque toolbar in the top inset region and is
    /// transparent elsewhere, letting clicks reach the page below — set
    /// `allowsHitTesting`/background accordingly in your SwiftUI view).
    /// Hosts a SwiftUI view as a **titlebar accessory** — placed immediately
    /// below the window's traffic-light row, fully outside CEF's content view.
    /// Text fields, buttons, and menus all receive proper AppKit key-view
    /// routing with no special handling needed.
    ///
    /// Pair with ``setContentInsets(_:)`` so the browser view starts below the
    /// toolbar (the top inset value = toolbar height).
    public func setOverlay<Content: View>(@ViewBuilder _ content: () -> Content) {
        installOverlay(AnyView(content()))
    }

    private func installOverlay(_ root: AnyView) {
        guard let nsWindow else {
            DispatchQueue.main.async { [weak self] in self?.installOverlay(root) }
            return
        }
        if let existing = titlebarAccessory {
            // Update in place — replace the hosted root view.
            (existing.view as? NSHostingView<AnyView>)?.rootView = root
            return
        }
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false

        let vc = NSTitlebarAccessoryViewController()
        vc.view = host
        // .bottom places it below the traffic-lights row, above the content.
        vc.layoutAttribute = .bottom
        nsWindow.addTitlebarAccessoryViewController(vc)
        titlebarAccessory = vc
    }

    /// Removes the SwiftUI overlay, if any.
    public func clearOverlay() {
        titlebarAccessory?.removeFromParent()
        titlebarAccessory = nil
    }

    /// Reserves space inside the window so web content isn't hidden under the
    /// overlay. Implemented by **insetting the browser view's frame** within
    /// the window (a CEF BoxLayout), not by covering the page. A `top` inset
    /// equal to your toolbar height yields the Arc/Chrome layout.
    public func setContentInsets(_ insets: NSEdgeInsets) {
        self.insets = insets
        chrome.setContentInsets(
            top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
    }

    // MARK: Window controls

    /// Shows (or re-shows) the window.
    public func show() { chrome.show() }

    /// Hides the window without destroying it.
    public func hide() { chrome.hide() }

    /// Closes the window and its browser (JS `onbeforeunload` may prompt).
    public func close() { chrome.close() }

    // MARK: Internals

    private func bindWindowObservers() {
        observedWindow = nsWindow
        // NSTitlebarAccessoryViewController resizes with the window automatically;
        // no manual resize observer needed.
    }

    private func teardown() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        observedWindow = nil
        titlebarAccessory?.removeFromParent()
        titlebarAccessory = nil
    }

    // Strong references so fire-and-forget windows live until destroyed.
    private static var liveInstances: Set<CefChromeWindow> = []
}

extension CefChromeWindow: Hashable {
    public nonisolated static func == (lhs: CefChromeWindow, rhs: CefChromeWindow) -> Bool {
        lhs === rhs
    }
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

