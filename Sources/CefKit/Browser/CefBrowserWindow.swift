import AppKit
import CCef
import Foundation
import Observation

/// A top-level window hosting one **Chrome-style** browser — the full Chrome
/// runtime, with `chrome://settings`, `chrome://extensions`, history,
/// downloads, password and autofill UI, extensions, and PDF/print preview.
///
/// Chromium only provides Chrome style in windows it creates itself, so this
/// type owns its `NSWindow` rather than living in a SwiftUI `WindowGroup`.
/// You still decide what the window looks like:
///
/// - ``Toolbar/none`` shows only the page; add your own chrome with
///   ``topAccessory`` (CefSwiftUI adds `setToolbar { … }` for SwiftUI views).
/// - ``Toolbar/chrome`` shows Chrome's own toolbar and omnibox.
///
/// ```swift
/// let window = CefBrowserWindow(browser: CefBrowser(url: home))
/// window.show()
/// ```
///
/// For a window drawn entirely by Chrome, tab strip included, use
/// ``CefRuntime/openChromeWindow(url:frame:options:delegate:)`` instead.
///
/// Each window holds one browser. To present several as tabs, give the
/// windows the same ``Configuration/tabbingIdentifier`` and macOS groups
/// them under a native tab bar; or keep one window per tab and show the
/// selected one.
@MainActor
@Observable
public final class CefBrowserWindow: Identifiable {

    /// Which toolbar Chrome draws inside the window.
    public enum Toolbar: Sendable {
        /// No Chrome UI: the page fills the window.
        case none
        /// Chrome's toolbar: navigation buttons, omnibox, app menu.
        case chrome
        /// Chrome's read-only location bar, as popups show.
        case location
    }

    /// How a window is created.
    public struct Configuration {
        public var toolbar: Toolbar = .none
        /// Initial frame in screen coordinates. `nil` centers a
        /// default-sized window.
        public var frame: CGRect?
        /// Removes the title bar and window buttons.
        public var isFrameless = false
        /// Keeps the window title in sync with the page title.
        public var titleFollowsPage = true
        /// Windows sharing an identifier are grouped as native macOS tabs.
        /// `nil` keeps the window out of tab groups.
        public var tabbingIdentifier: String?

        public init() {}
    }

    /// The browser shown in this window.
    public let browser: CefBrowser
    public let configuration: Configuration

    /// Whether the window has been closed and destroyed.
    public private(set) var isClosed = false

    /// Called after the window is destroyed.
    @ObservationIgnored public var onClose: (() -> Void)?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Every open browser window, in creation order.
    public private(set) static var all: [CefBrowserWindow] = []

    @ObservationIgnored private var window: CefRef<cef_window_t>?
    @ObservationIgnored private var browserView: CefRef<cef_browser_view_t>?
    @ObservationIgnored private var accessoryController: NSTitlebarAccessoryViewController?

    /// Creates the window and its browser. `browser` must not have been
    /// hosted elsewhere. The window stays hidden until ``show()``.
    public init(browser: CefBrowser, configuration: Configuration = .init()) {
        self.browser = browser
        self.configuration = configuration
        Self.all.append(self)

        let viewDelegate = BrowserViewDelegate(toolbar: configuration.toolbar)
        browserView = CefRef(adopting: browser.createBrowserView(delegate: viewDelegate.makeDelegate()))
        // Creation is synchronous: windowCreated(_:) has run by the time
        // this returns.
        window = CefRef(adopting: cef_window_create_top_level(WindowDelegate(owner: self).makeDelegate()))
        if configuration.titleFollowsPage {
            mirrorPageTitle()
        }
    }

    private func mirrorPageTitle() {
        guard !isClosed else { return }
        let title = withObservationTracking {
            browser.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirrorPageTitle() }
        }
        nsWindow?.title = title.isEmpty ? (browser.url?.host() ?? "") : title
    }

    // MARK: Window

    /// The AppKit window. Chromium owns its lifetime — close it with
    /// ``close()`` — but ordering, frames, titles and tabbing are yours.
    public var nsWindow: NSWindow? {
        guard let window = window?.pointer, let handle = window.pointee.get_window_handle(window) else { return nil }
        return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue().window
    }

    public func show() {
        window.map { $0.pointer.pointee.show($0.pointer) }
    }

    public func hide() {
        window.map { $0.pointer.pointee.hide($0.pointer) }
    }

    /// Closes the window and its browser. The page's `beforeunload` handler
    /// may keep it open.
    public func close() {
        window.map { $0.pointer.pointee.close($0.pointer) }
    }

    // MARK: Native chrome

    /// A view placed between the title bar and the page — the place for your
    /// own toolbar, tab strip or omnibox. It sits outside Chromium's view
    /// hierarchy, so focus, key equivalents and menus behave as in any
    /// AppKit window. Size it with Auto Layout or a fixed frame height.
    public var topAccessory: NSView? {
        get { accessoryController?.view }
        set {
            if let accessoryController {
                accessoryController.removeFromParent()
                self.accessoryController = nil
            }
            guard let newValue, let nsWindow else { return }
            let controller = NSTitlebarAccessoryViewController()
            controller.view = newValue
            controller.layoutAttribute = .bottom
            nsWindow.addTitlebarAccessoryViewController(controller)
            accessoryController = controller
        }
    }

    /// Space reserved around the page inside the window's content area, for
    /// native views you place alongside it (a sidebar, a status bar).
    public var contentInsets = NSEdgeInsets() {
        didSet { applyLayout() }
    }

    private func applyLayout() {
        guard let window = window?.pointer else { return }
        var settings = cef_box_layout_settings_t()
        settings.size = MemoryLayout<cef_box_layout_settings_t>.stride
        settings.inside_border_insets = cef_insets_t(
            top: Int32(contentInsets.top.rounded()), left: Int32(contentInsets.left.rounded()),
            bottom: Int32(contentInsets.bottom.rounded()), right: Int32(contentInsets.right.rounded()))
        settings.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.main_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.default_flex = 1
        // cef_window_t begins with its cef_panel_t base.
        window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
            cefRelease(panel.pointee.set_to_box_layout(panel, &settings))
            panel.pointee.layout(panel)
        }
    }

    // MARK: Delegate callbacks

    fileprivate func windowCreated(_ window: UnsafeMutablePointer<cef_window_t>) {
        if let browserView {
            // add_child_view consumes a reference to the view.
            cefAddRef(browserView.pointer)
            window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
                browserView.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) { view in
                    panel.pointee.add_child_view(panel, view)
                }
            }
        }
        self.window = CefRef(retaining: window)
        applyLayout()
        if configuration.frame == nil {
            var size = cef_size_t(width: 1200, height: 800)
            window.pointee.center_window(window, &size)
        }
        if let nsWindow {
            // Chromium disables native tabbing on its windows; opt back in
            // when asked to.
            nsWindow.tabbingMode = configuration.tabbingIdentifier == nil ? .disallowed : .preferred
            if let identifier = configuration.tabbingIdentifier {
                nsWindow.tabbingIdentifier = identifier
            }
        }
    }

    fileprivate func windowDestroyed() {
        accessoryController = nil
        window = nil
        browserView = nil
        isClosed = true
        Self.all.removeAll { $0 === self }
        onClose?()
    }
}

// MARK: - Views delegates

/// Owner of a `cef_browser_view_delegate_t`. Popups opened from the view get
/// a delegate of their own showing Chrome's location bar.
private final class BrowserViewDelegate: Sendable {
    let toolbar: CefBrowserWindow.Toolbar

    init(toolbar: CefBrowserWindow.Toolbar) {
        self.toolbar = toolbar
    }

    func makeDelegate() -> UnsafeMutablePointer<cef_browser_view_delegate_t> {
        let d = cefAllocate(cef_browser_view_delegate_t.self, owner: self)
        // The browser itself is tracked through the life span handler.
        d.pointee.on_browser_created = { _, view, browser in
            cefRelease(view)
            cefRelease(browser)
        }
        d.pointee.on_browser_destroyed = { _, view, browser in
            cefRelease(view)
            cefRelease(browser)
        }
        d.pointee.get_delegate_for_popup_browser_view = { _, view, _, client, _ in
            cefRelease(view)
            cefRelease(client)
            return BrowserViewDelegate(toolbar: .location).makeDelegate()
        }
        d.pointee.on_popup_browser_view_created = { _, view, popupView, _ in
            cefRelease(view)
            cefRelease(popupView)
            return 0  // let CEF give the popup a default window
        }
        d.pointee.get_chrome_toolbar_type = { s, view in
            cefRelease(view)
            switch cefOwner(BrowserViewDelegate.self, s)?.toolbar {
            case .chrome: return CEF_CTT_NORMAL
            case .location: return CEF_CTT_LOCATION
            case .none?, nil: return CEF_CTT_NONE
            }
        }
        d.pointee.get_browser_runtime_style = { _ in CEF_RUNTIME_STYLE_CHROME }
        return d
    }
}

/// Owner of a `cef_window_delegate_t`. Callbacks arrive on the UI thread.
private final class WindowDelegate: @unchecked Sendable {
    private weak var owner: CefBrowserWindow?

    @MainActor
    init(owner: CefBrowserWindow) {
        self.owner = owner
    }

    private static func with<S, R: Sendable>(
        _ delegateSelf: UnsafeMutablePointer<S>?,
        _ window: UnsafeMutablePointer<cef_window_t>?,
        default fallback: R,
        _ body: @MainActor (CefBrowserWindow) -> R
    ) -> R {
        defer { cefRelease(window) }
        guard let delegate = cefOwner(WindowDelegate.self, delegateSelf) else { return fallback }
        return MainActor.assumeIsolated {
            guard let owner = delegate.owner else { return fallback }
            return body(owner)
        }
    }

    func makeDelegate() -> UnsafeMutablePointer<cef_window_delegate_t> {
        let d = cefAllocate(cef_window_delegate_t.self, owner: self)
        d.pointee.on_window_created = { s, window in
            guard let window else { return }
            nonisolated(unsafe) let created = window
            WindowDelegate.with(s, window, default: ()) { $0.windowCreated(created) }
        }
        d.pointee.on_window_destroyed = { s, window in
            WindowDelegate.with(s, window, default: ()) { $0.windowDestroyed() }
        }
        d.pointee.can_close = { s, window in
            // Routed through the browser so `beforeunload` can object.
            WindowDelegate.with(s, window, default: 1) { $0.browser.tryClose() ? 1 : 0 }
        }
        d.pointee.is_frameless = { s, window in
            WindowDelegate.with(s, window, default: 0) { $0.configuration.isFrameless ? 1 : 0 }
        }
        d.pointee.with_standard_window_buttons = { s, window in
            WindowDelegate.with(s, window, default: 1) { $0.configuration.isFrameless ? 0 : 1 }
        }
        d.pointee.get_initial_bounds = { s, window in
            WindowDelegate.with(s, window, default: cef_rect_t()) {
                $0.configuration.frame.map { cef_rect_t(screenRect: $0) } ?? cef_rect_t()
            }
        }
        d.pointee.get_initial_show_state = { _, window in
            cefRelease(window)
            return CEF_SHOW_STATE_HIDDEN
        }
        d.pointee.get_window_runtime_style = { _ in CEF_RUNTIME_STYLE_CHROME }
        return d
    }
}
