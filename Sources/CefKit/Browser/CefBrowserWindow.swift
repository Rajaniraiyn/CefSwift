import AppKit
import CCef
import Foundation
import Observation
import CefBase

/// A top-level window hosting one **Chrome-style** browser — the full Chrome
/// runtime, with `chrome://settings`, `chrome://extensions`, history,
/// downloads, password and autofill UI, extensions, and PDF/print preview.
///
/// Chromium only provides Chrome style in windows it creates itself, so this
/// type owns its `NSWindow` rather than living in a SwiftUI `WindowGroup`.
/// You still decide what the window looks like:
///
/// - ``Toolbar/none`` shows only the page; add your own chrome with
///   ``topAccessory`` (CefSwiftUI adds `setToolbar(leading:principal:trailing:)`
///   and `setTabAccessory(_:)` for SwiftUI views).
/// - ``Toolbar/chrome`` shows Chrome's own toolbar and omnibox.
///
/// ```swift
/// let window = CefBrowserWindow(browser: CefBrowser(url: home))
/// window.show()
/// ```
///
/// For a window drawn entirely by Chrome, tab strip included, use
/// ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)`` instead.
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
        /// How Chromium's interface is presented at first:
        /// ``CefBrowserWindow/chromiumUI`` starts as this, or with every
        /// surface ``CefChromiumSurface/Presentation/native`` when `nil`.
        /// A status bubble
        /// or zoom bubble hidden here is never created, as the browser
        /// starts with Chromium's own switched off (`cef_browser_settings_t`);
        /// hiding one later keeps Chromium's window invisible instead.
        public var chromiumUI: CefBrowserWindow.ChromiumUI?

        public init() {}
    }

    /// The browser shown in this window.
    public let browser: CefBrowser
    public let configuration: Configuration

    /// Whether the window has been closed and destroyed.
    public private(set) var isClosed = false

    /// Called after the window is destroyed.
    @ObservationIgnored public var onClose: (() -> Void)?

    /// Called when the page opens a popup window (`window.open` with
    /// features, sign-in flows). The popup arrives as a hidden
    /// `CefBrowserWindow` of its own, still connected to its opener — give
    /// it your toolbar, add it to a tab group, and show it.
    ///
    /// When `nil`, Chromium shows popups in a window of its own design.
    @ObservationIgnored public var onPopup: ((CefBrowserWindow) -> Void)?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Every open browser window, in creation order.
    public private(set) static var all: [CefBrowserWindow] = []

    /// How many windows Chromium has yet to destroy, hidden service windows
    /// included. Shutting down has to wait for this to reach zero.
    private(set) static var liveCount = 0

    @ObservationIgnored private var cefWindow: CefRef<cef_window_t>?
    @ObservationIgnored private var browserView: CefRef<cef_browser_view_t>?
    @ObservationIgnored private var accessoryController: NSTitlebarAccessoryViewController?

    /// Creates the window and its browser. `browser` must not have been
    /// hosted elsewhere. The window stays hidden until ``show()``.
    public init(browser: CefBrowser, configuration: Configuration = .init()) {
        self.browser = browser
        self.configuration = configuration
        Self.all.append(self)
        Self.liveCount += 1
        Self.installRuntimeHooks()

        let initialUI = configuration.chromiumUI ?? CefBrowserWindow.ChromiumUI()
        chromiumUI = initialUI
        let viewDelegate = BrowserViewDelegate(toolbar: configuration.toolbar, window: self)
        browserView = CefRef(adopting: browser.createBrowserView(
            delegate: viewDelegate.makeDelegate(),
            showsStatusBubble: initialUI[.statusBubble] != .hidden,
            showsZoomBubble: initialUI[.zoom] != .hidden))
        createWindow()
    }

    /// Wraps a popup's browser view, created by Chromium, in a window.
    fileprivate init(popupView: CefRef<cef_browser_view_t>, browser: CefBrowser, opener: CefBrowserWindow) {
        self.browser = browser
        var configuration = opener.configuration
        configuration.frame = nil
        self.configuration = configuration
        self.isPopup = true
        Self.all.append(self)
        Self.liveCount += 1
        Self.installRuntimeHooks()
        browserView = popupView
        createWindow()
    }

    @ObservationIgnored private var isPopup = false

    /// A hidden window hosting an internal-page service browser
    /// (``CefProfile/bookmarks`` and friends). Such windows are left out of
    /// ``all``.
    @ObservationIgnored var isService = false {
        didSet {
            guard isService else { return }
            Self.all.removeAll { $0 === self }
            keepOffScreen()
        }
    }

    @ObservationIgnored private var serviceWindowObserver: NSObjectProtocol?

    /// Keeps a service window from ever being seen. Chromium shows and
    /// activates its own windows on occasion — restoring a session,
    /// handling a relaunch, bringing the app forward — and would show this
    /// one with them; it is made transparent and taken off screen again as
    /// soon as it appears.
    private func keepOffScreen() {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.collectionBehavior.formUnion([.transient, .ignoresCycle])
        serviceWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.isVisible else { return }
                window.orderOut(nil)
            }
        }
    }

    /// Installs the overrides of Chromium's AppKit classes that surfaces and
    /// swipe navigation rely on, once.
    private static func installRuntimeHooks() {
        CefSurfaceTracker.install()
        CefHistorySwipeHooks.install()
    }

    /// The open window whose `NSWindow` is `window`.
    package static func owning(_ window: NSWindow) -> CefBrowserWindow? {
        all.first { $0.window === window }
    }

    private func createWindow() {
        // Creation is synchronous: windowCreated(_:) has run by the time
        // this returns.
        cefWindow = CefRef(adopting: cef_window_create_top_level(WindowDelegate(owner: self).makeDelegate()))
        if configuration.titleFollowsPage {
            mirrorPageTitle()
        }
    }

    /// Hands a popup's browser view to ``onPopup``. Returns whether the
    /// popup was taken; otherwise Chromium gives it a window.
    func adoptPopup(_ popupView: CefRef<cef_browser_view_t>) -> Bool {
        // The view must be in a window before this callback returns, so the
        // popup's browser is wrapped now even if Chromium has not announced
        // it yet. Popups share their opener's client.
        guard let onPopup, let client = browser.client,
              let raw = popupView.pointer.pointee.get_browser(popupView.pointer)
        else { return false }
        let popup = client.wrapper(adopting: raw)
        onPopup(CefBrowserWindow(popupView: popupView, browser: popup, opener: self))
        return true
    }

    private func mirrorPageTitle() {
        guard !isClosed else { return }
        let title = withObservationTracking {
            browser.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirrorPageTitle() }
        }
        window?.title = title.isEmpty ? (browser.url?.host() ?? "") : title
    }

    // MARK: Window

    /// The AppKit window. Chromium owns its lifetime — close it with
    /// ``close()`` — but ordering, frames, titles and tabbing are yours.
    public var window: NSWindow? {
        guard let window = cefWindow?.pointer, let handle = window.pointee.get_window_handle(window) else { return nil }
        return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue().window
    }

    public func show() {
        cefWindow.map { $0.pointer.pointee.show($0.pointer) }
    }

    public func hide() {
        cefWindow.map { $0.pointer.pointee.hide($0.pointer) }
    }

    /// Closes the window and its browser. The page's `beforeunload` handler
    /// may keep it open.
    public func close() {
        cefWindow.map { $0.pointer.pointee.close($0.pointer) }
    }

    // MARK: Native chrome

    /// A view placed between the title bar and the page — the place for your
    /// own toolbar, tab strip or omnibox. It sits outside Chromium's view
    /// hierarchy, so focus, key equivalents and menus behave as in any
    /// AppKit window. Size it with Auto Layout or a fixed frame height.
    public var topAccessory: NSView? {
        didSet {
            guard topAccessory !== oldValue else { return }
            accessoryController?.removeFromParent()
            accessoryController = nil
            guard let view = topAccessory else { return }
            withWindow { [weak self] window in
                guard let self, self.topAccessory === view else { return }
                let controller = NSTitlebarAccessoryViewController()
                controller.view = view
                controller.layoutAttribute = .bottom
                window.addTitlebarAccessoryViewController(controller)
                self.accessoryController = controller
            }
        }
    }

    @ObservationIgnored private var windowWaiters: [@MainActor (NSWindow) -> Void] = []

    /// Runs `body` with the AppKit ``window``: at once when it exists,
    /// otherwise as soon as Chromium has created it. Does nothing once the
    /// window has closed.
    ///
    /// Use it for setup that needs the `NSWindow`, such as a toolbar.
    public func withWindow(_ body: @escaping @MainActor (NSWindow) -> Void) {
        if let window {
            body(window)
        } else if isClosed {
            CefLog.error("CefBrowserWindow: the window has closed; its setup is ignored")
        } else {
            windowWaiters.append(body)
        }
    }

    /// Space reserved around the page inside the window's content area, for
    /// native views you place alongside it (a sidebar, a status bar).
    public var contentInsets = NSEdgeInsets() {
        didSet { applyLayout() }
    }

    /// Rounds the corners of the page area. Combined with ``contentInsets``
    /// this frames the page as an inset card — the window's background
    /// shows around it.
    public var contentCornerRadius: CGFloat = 0 {
        didSet { applyLayout() }
    }

    @ObservationIgnored private var contentFrame: ContentFrameView?

    /// Chromium draws the whole content area in one layer, so the frame is a
    /// native view laid over it that paints everything except the page.
    private func updateContentFrame() {
        let isFramed = contentCornerRadius > 0
            || contentInsets.top + contentInsets.left + contentInsets.bottom + contentInsets.right > 0
        guard isFramed, let contentView = window?.contentView else {
            contentFrame?.removeFromSuperview()
            contentFrame = nil
            return
        }
        let frame = contentFrame ?? ContentFrameView()
        if frame.superview !== contentView {
            frame.frame = contentView.bounds
            frame.autoresizingMask = [.width, .height]
            contentView.addSubview(frame, positioned: .above, relativeTo: nil)
            contentFrame = frame
        }
        frame.insets = contentInsets
        frame.cornerRadius = contentCornerRadius
    }

    private func applyLayout() {
        updateContentFrame()
        updatePageOverlay()
        guard let window = cefWindow?.pointer else { return }
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

    // MARK: Chromium's interface

    /// How Chromium's own interface is presented in this window: its
    /// bubbles, dialogs, find bar and status bubble
    /// (``CefChromiumSurface/Kind``). Each kind is drawn by Chromium where
    /// Chromium puts it, anchored under your controls, replaced by your own
    /// interface, or hidden.
    ///
    /// ```swift
    /// window.chromiumUI.anchor = .view(addressField, alignment: .trailing)
    /// window.chromiumUI[.statusBubble] = .hidden
    /// window.setCustomPresentation(for: .qrCode) { surface in showMyQRCode(for: surface.url) }
    /// ```
    ///
    /// Surfaces follow their anchor as the window moves or resizes, and when
    /// Chromium lays them out again. CefSwiftUI's
    /// `chromiumSurfaceAnchor(_:alignment:)` modifier sets anchors from
    /// SwiftUI views in your toolbar.
    public var chromiumUI = CefBrowserWindow.ChromiumUI() {
        didSet { applyChromiumUI() }
    }

    /// Decides a surface's presentation as it appears, taking precedence
    /// over ``chromiumUI``. Return `nil` to use ``chromiumUI``. The surface
    /// stays hidden while this runs.
    @ObservationIgnored public var presentationForSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)?

    /// Chromium's surfaces in this window, oldest first: those Chromium
    /// draws, and those you present yourself until they are dismissed.
    public internal(set) var chromiumSurfaces: [CefChromiumSurface] = []

    /// Called as each surface appears: after a native one is placed, and for
    /// a custom one after its presenter (or instead of one).
    @ObservationIgnored public var onChromiumSurface: ((CefChromiumSurface) -> Void)?

    /// Presents your own interface for a kind of surface, and sets the
    /// kind's presentation to ``CefChromiumSurface/Presentation/custom``.
    /// `present` receives the surface when Chromium would show it — from
    /// its command (``CefChromeCommand/find``, ``CefChromeCommand/createQRCode``,
    /// ``CefChromeCommand/castMedia``, ``CefChromeCommand/showSharingHub``),
    /// its shortcut, its menu item, or anything else — with Chromium's own
    /// interface kept off screen. Pass `nil` to go back to Chromium's.
    public func setCustomPresentation(
        for kind: CefChromiumSurface.Kind, _ present: (@MainActor (CefChromiumSurface) -> Void)?
    ) {
        customPresenters[kind] = present
        chromiumUI[kind] = present == nil ? .native : .custom
    }

    @ObservationIgnored var customPresenters: [CefChromiumSurface.Kind: @MainActor (CefChromiumSurface) -> Void] = [:]
    @ObservationIgnored var surfaceObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored var isPlacingSurface = false
    @ObservationIgnored var pendingSurfaces: [ObjectIdentifier: (window: NSWindow, alpha: CGFloat)] = [:]

    // MARK: Over the page

    /// A view of your own, laid over the page in place of the built-in
    /// swipe indicator (``CefBrowser/Configuration/navigationGestureIndicator``).
    /// It is sized to the page, never receives events, and stays installed;
    /// read ``CefBrowser/navigationGestureProgress`` to draw it.
    /// CefSwiftUI's `setNavigationGestureIndicator(_:)` sets it from a
    /// SwiftUI view.
    public var navigationGestureIndicatorView: NSView? {
        didSet {
            guard navigationGestureIndicatorView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            updatePageOverlay()
        }
    }

    /// A view of your own, laid over the page in place of Chromium's status
    /// bubble, the address of a hovered link at the page's lower edge.
    /// Setting it hides Chromium's (``CefChromiumSurface/Kind/statusBubble``).
    /// It is sized to the page, never receives events, and stays installed;
    /// read ``CefBrowser/statusText`` to draw it. CefSwiftUI's
    /// `setStatusBubble(_:)` sets it from a SwiftUI view.
    public var statusBubbleView: NSView? {
        didSet {
            guard statusBubbleView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if statusBubbleView != nil {
                chromiumUI[.statusBubble] = .hidden
            } else if case .hidden = chromiumUI[.statusBubble] {
                chromiumUI.presentations[.statusBubble] = nil
            }
            updatePageOverlay()
        }
    }

    @ObservationIgnored private var pageOverlay: PageOverlayView?
    @ObservationIgnored private var builtInIndicator: CefNavigationGestureIndicatorView?

    /// Lays the views over the page: the swipe indicator (the app's, or
    /// CefSwift's unless Chromium draws its own or none is wanted) and the
    /// app's status bubble.
    private func updatePageOverlay() {
        let configuration = browser.configuration
        let wantsBuiltIn = configuration.allowsBackForwardNavigationGestures
            && configuration.navigationGestureIndicator == .automatic
        let indicator: NSView?
        if let custom = navigationGestureIndicatorView {
            builtInIndicator?.removeFromSuperview()
            builtInIndicator = nil
            indicator = custom
        } else if wantsBuiltIn {
            let builtIn = builtInIndicator ?? CefNavigationGestureIndicatorView()
            builtIn.browser = browser
            builtInIndicator = builtIn
            indicator = builtIn
        } else {
            builtInIndicator?.removeFromSuperview()
            builtInIndicator = nil
            indicator = nil
        }
        let views = [statusBubbleView, indicator].compactMap { $0 }
        guard !views.isEmpty, let contentView = window?.contentView else {
            pageOverlay?.removeFromSuperview()
            pageOverlay = nil
            return
        }
        let overlay = pageOverlay ?? PageOverlayView()
        if overlay.superview !== contentView {
            overlay.frame = contentView.bounds
            overlay.autoresizingMask = [.width, .height]
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
            pageOverlay = overlay
        }
        overlay.insets = contentInsets
        overlay.cornerRadius = contentCornerRadius
        overlay.setViews(views)
    }

    // MARK: Delegate callbacks

    func windowCreated(_ window: UnsafeMutablePointer<cef_window_t>) {
        if let browserView {
            // add_child_view consumes a reference to the view.
            cefAddRef(browserView.pointer)
            window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
                browserView.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) { view in
                    panel.pointee.add_child_view(panel, view)
                }
            }
        }
        cefWindow = CefRef(retaining: window)
        applyLayout()
        if configuration.frame == nil, !isPopup {
            var size = cef_size_t(width: 1200, height: 800)
            window.pointee.center_window(window, &size)
        }
        if let nsWindow = self.window {
            // Chromium disables native tabbing on its windows; opt back in
            // when asked to.
            nsWindow.tabbingMode = configuration.tabbingIdentifier == nil ? .disallowed : .preferred
            if let identifier = configuration.tabbingIdentifier {
                nsWindow.tabbingIdentifier = identifier
            }
            observeFrame(of: nsWindow)
            updatePageOverlay()
            let waiters = windowWaiters
            windowWaiters = []
            waiters.forEach { $0(nsWindow) }
        }
    }

    func windowDestroyed() {
        serviceWindowObserver.map(NotificationCenter.default.removeObserver)
        serviceWindowObserver = nil
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        chromiumSurfaces.forEach(stopTracking)
        chromiumSurfaces = []
        accessoryController = nil
        windowWaiters = []
        cefWindow = nil
        browserView = nil
        isClosed = true
        Self.all.removeAll { $0 === self }
        Self.liveCount -= 1
        onClose?()
        CefRuntime.shared.continueTerminationIfReady()
    }
}
