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

        let viewDelegate = BrowserViewDelegate(toolbar: configuration.toolbar, window: self)
        browserView = CefRef(adopting: browser.createBrowserView(delegate: viewDelegate.makeDelegate()))
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

    /// Installs the overrides of Chromium's AppKit classes that bubbles and
    /// swipe navigation rely on, once.
    private static func installRuntimeHooks() {
        CefBubbleTracker.install()
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
    fileprivate func adoptPopup(_ popupView: CefRef<cef_browser_view_t>) -> Bool {
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
        updateGestureIndicator()
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

    // MARK: Chromium's bubbles

    /// Where Chromium's bubbles appear: the QR code generator, Cast, share,
    /// translate, password and bookmark bubbles, and other titled bubbles
    /// Chromium would attach to its toolbar. `nil` leaves them where Chromium
    /// puts them, which without Chrome's toolbar is the top right of the
    /// page.
    ///
    /// Bubbles follow the anchor as the window moves and resizes, and when
    /// Chromium lays them out again. CefSwiftUI's `chromiumBubbleAnchor()`
    /// modifier sets this from a SwiftUI view in your toolbar.
    ///
    /// ```swift
    /// window.bubbleAnchor = .view(addressField, alignment: .trailing)
    /// ```
    public var bubbleAnchor: CefBubbleAnchor? {
        didSet { placeBubbles() }
    }

    /// Anchors for particular kinds of bubble, which take precedence over
    /// ``bubbleAnchor``. The sign-in dialog and the find bar move only with
    /// an anchor here.
    public var bubbleAnchors: [CefChromiumBubble.Kind: CefBubbleAnchor] = [:] {
        didSet { placeBubbles() }
    }

    /// Chromium's bubbles attached to this window, oldest first.
    public private(set) var chromiumBubbles: [CefChromiumBubble] = []

    /// Called as each of Chromium's bubbles appears, after it is placed.
    @ObservationIgnored public var onChromiumBubble: ((CefChromiumBubble) -> Void)?

    @ObservationIgnored private var bubbleObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isPlacingBubble = false
    @ObservationIgnored private var announcedBubbles: Set<ObjectIdentifier> = []

    /// Chromium is about to attach `child` to this window.
    func childWindowWillAttach(_ child: NSWindow) {
        guard !chromiumBubbles.contains(where: { $0.window === child }),
              CefChromiumBubble.isBubbleWindow(child)
        else { return }
        let title = CefChromiumBubble.title(of: child)
        let bubble = CefChromiumBubble(
            window: child, kind: CefChromiumBubble.kind(forTitle: title), title: title, browserWindow: self)
        chromiumBubbles.append(bubble)
        let center = NotificationCenter.default
        let follow: @Sendable (Notification) -> Void = { [weak self, weak bubble] _ in
            MainActor.assumeIsolated {
                guard let self, let bubble, !self.isPlacingBubble else { return }
                self.place(bubble)
            }
        }
        bubbleObservers[bubble.id] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.didResizeNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.willCloseNotification, object: child, queue: nil) { [weak self, weak bubble] _ in
                MainActor.assumeIsolated {
                    guard let self, let bubble else { return }
                    self.stopTracking(bubble)
                    self.chromiumBubbles.removeAll { $0 === bubble }
                }
            },
        ]
        place(bubble)
    }

    /// Chromium has attached `child`, which is now on screen.
    func childWindowDidAttach(_ child: NSWindow) {
        guard let bubble = chromiumBubbles.first(where: { $0.window === child }),
              announcedBubbles.insert(bubble.id).inserted
        else { return }
        bubble.refreshKind()
        place(bubble)
        onChromiumBubble?(bubble)
    }

    /// Chromium has detached `child`, as it does when hiding a bubble.
    func childWindowDidDetach(_ child: NSWindow) {
        guard let bubble = chromiumBubbles.first(where: { $0.window === child }) else { return }
        stopTracking(bubble)
        chromiumBubbles.removeAll { $0 === bubble }
    }

    private func stopTracking(_ bubble: CefChromiumBubble) {
        bubbleObservers.removeValue(forKey: bubble.id)?.forEach(NotificationCenter.default.removeObserver)
        announcedBubbles.remove(bubble.id)
    }

    /// The anchor that applies to `bubble`, if any.
    private func anchor(for bubble: CefChromiumBubble) -> CefBubbleAnchor? {
        bubbleAnchors[bubble.kind] ?? (bubble.followsWindowAnchor ? bubbleAnchor : nil)
    }

    /// Moves `bubble` under its anchor.
    private func place(_ bubble: CefChromiumBubble) {
        bubble.refreshKind()
        guard let child = bubble.window, let parent = window, let anchor = anchor(for: bubble),
              let origin = anchor.origin(for: child.frame.size, in: parent)
        else { return }
        let current = child.frame.origin
        guard abs(current.x - origin.x) > 0.5 || abs(current.y - origin.y) > 0.5 else { return }
        isPlacingBubble = true
        child.setFrameOrigin(origin)
        isPlacingBubble = false
    }

    private func placeBubbles() {
        chromiumBubbles.forEach(place)
    }

    /// Keeps bubbles under their anchors as the window changes.
    private func observeFrame(of nsWindow: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBubbles() }
        }
        frameObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didMoveNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nsWindow, queue: nil, using: update),
        ]
    }

    // MARK: Swipe indicator

    /// A view of your own, laid over the page in place of the built-in
    /// swipe indicator (``CefBrowserOptions/navigationGestureIndicator``).
    /// It is sized to the page, never receives events, and stays installed;
    /// read ``CefBrowser/navigationGestureProgress`` to draw it.
    /// CefSwiftUI's `setNavigationGestureIndicator(_:)` sets it from a
    /// SwiftUI view.
    public var navigationGestureIndicatorView: NSView? {
        didSet {
            guard navigationGestureIndicatorView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            updateGestureIndicator()
        }
    }

    @ObservationIgnored private var gestureOverlay: GestureOverlayView?
    @ObservationIgnored private var builtInIndicator: CefNavigationGestureIndicatorView?

    /// The built-in indicator, when it is installed. For tests.
    package var installedGestureIndicator: CefNavigationGestureIndicatorView? { builtInIndicator }

    /// Lays the indicator over the page: the app's view, or CefSwift's
    /// unless Chromium draws its own or none is wanted.
    private func updateGestureIndicator() {
        let options = browser.options
        let wantsBuiltIn = options.allowsBackForwardNavigationGestures
            && options.navigationGestureIndicator == .automatic
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
        guard let indicator, let contentView = window?.contentView else {
            gestureOverlay?.removeFromSuperview()
            gestureOverlay = nil
            return
        }
        let overlay = gestureOverlay ?? GestureOverlayView()
        if overlay.superview !== contentView {
            overlay.frame = contentView.bounds
            overlay.autoresizingMask = [.width, .height]
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
            gestureOverlay = overlay
        }
        overlay.insets = contentInsets
        overlay.cornerRadius = contentCornerRadius
        overlay.setIndicator(indicator)
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
            updateGestureIndicator()
            let waiters = windowWaiters
            windowWaiters = []
            waiters.forEach { $0(nsWindow) }
        }
    }

    fileprivate func windowDestroyed() {
        serviceWindowObserver.map(NotificationCenter.default.removeObserver)
        serviceWindowObserver = nil
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        chromiumBubbles.forEach(stopTracking)
        chromiumBubbles = []
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

// MARK: - Content frame

/// Paints the window background everywhere except a rounded rectangle over
/// the page, and lets every event through to Chromium beneath it.
private final class ContentFrameView: NSView {
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    private let cutout = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        cutout.fillRule = .evenOdd
        layer?.mask = cutout
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        // AppKit's y axis points up, so the top inset comes off maxY.
        let page = CGRect(
            x: insets.left, y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom)
        let path = CGMutablePath()
        path.addRect(bounds)
        if page.width > 0, page.height > 0 {
            let radius = min(cornerRadius, page.width / 2, page.height / 2)
            path.addRoundedRect(in: page, cornerWidth: radius, cornerHeight: radius)
        }
        cutout.frame = bounds
        cutout.path = path
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds the swipe indicator over the page's rectangle, clipped to its
/// rounded corners, and lets every event through.
private final class GestureOverlayView: NSView {
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    private let clip = NSView()

    init() {
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setIndicator(_ indicator: NSView) {
        guard indicator.superview !== clip else { return }
        clip.subviews.forEach { $0.removeFromSuperview() }
        indicator.frame = clip.bounds
        indicator.autoresizingMask = [.width, .height]
        clip.addSubview(indicator)
    }

    override func layout() {
        super.layout()
        clip.frame = CGRect(
            x: insets.left, y: insets.bottom,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom))
        clip.layer?.cornerRadius = cornerRadius
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Views delegates

/// Owner of a `cef_browser_view_delegate_t`. Popups opened from the view get
/// a delegate of their own showing Chrome's location bar.
private final class BrowserViewDelegate: @unchecked Sendable {
    let toolbar: CefBrowserWindow.Toolbar
    /// The window whose page may open popups; UI thread only.
    private weak var window: CefBrowserWindow?

    init(toolbar: CefBrowserWindow.Toolbar, window: CefBrowserWindow?) {
        self.toolbar = toolbar
        self.window = window
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
        d.pointee.get_delegate_for_popup_browser_view = { s, view, _, client, isDevTools in
            cefRelease(view)
            cefRelease(client)
            // A popup the app will host keeps the opener's toolbar choice;
            // one Chromium hosts shows its location bar.
            guard isDevTools == 0, let owner = cefOwner(BrowserViewDelegate.self, s) else {
                return BrowserViewDelegate(toolbar: .location, window: nil).makeDelegate()
            }
            return MainActor.assumeIsolated {
                let hosted = owner.window?.onPopup != nil
                return CefRef(adopting: BrowserViewDelegate(
                    toolbar: hosted ? owner.toolbar : .location, window: nil).makeDelegate())
            }.detach()
        }
        d.pointee.on_popup_browser_view_created = { s, view, popupView, isDevTools in
            cefRelease(view)
            guard isDevTools == 0, let popupView = CefRef(adopting: popupView),
                  let owner = cefOwner(BrowserViewDelegate.self, s)
            else { return 0 }
            // Non-zero tells CEF the app is giving the popup a window.
            return MainActor.assumeIsolated { owner.window?.adoptPopup(popupView) == true ? 1 : 0 }
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
