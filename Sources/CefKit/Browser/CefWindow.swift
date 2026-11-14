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
/// let window = CefWindow(browser: CefBrowser(url: home))
/// window.show()
/// ```
///
/// For a window drawn entirely by Chrome, tab strip included, use
/// ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)`` instead.
///
/// Each window holds one browser: CEF refuses a second Chrome-style
/// browser view in a window, and Chromium counts every `CefWindow` as a
/// popup window of one tab. To present several as tabs, give the windows
/// the same ``Configuration/tabbingIdentifier`` and macOS groups them under
/// a native tab bar; or keep one window per tab and show the selected one.
/// Tabs that are Chromium's own, which `chrome.tabs` and tab groups see,
/// live in the windows ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)``
/// opens; CefChromium's `CefChromeWindow` hosts them with the app's own
/// tab interface over Chrome's. Use `CefWindow` for one page in a window.
@MainActor
@Observable
public final class CefWindow: Identifiable {

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
        /// Keeps the window title in sync with the page, as ``title``
        /// makes it.
        public var titleFollowsPage = true
        /// The window title for the browser's page while
        /// ``titleFollowsPage`` is on: by default the page's title, or its
        /// host while it has none. The window shows the result again
        /// whenever the observable state the closure reads changes.
        ///
        /// ```swift
        /// windowConfiguration.title = { browser in
        ///     browser.title.isEmpty ? "New Tab" : browser.title
        /// }
        /// ```
        public var title: @MainActor (CefBrowser) -> String = { browser in
            browser.title.isEmpty ? (browser.url?.host() ?? "") : browser.title
        }
        /// Windows sharing an identifier are grouped as native macOS tabs.
        /// `nil` keeps the window out of tab groups.
        public var tabbingIdentifier: String?
        /// Whether the browser starts with Chromium's status bubble and
        /// zoom bubble (`cef_browser_settings_t`'s `chrome_status_bubble`
        /// and `chrome_zoom_bubble`). CefChromium's `chromiumSurfacePolicy` sets them.
        package var showsChromiumStatusBubble = true
        package var showsChromiumZoomBubble = true

        /// What modules built on CefKit keep in a configuration, by type.
        /// They apply to the window created with it, not to its popups.
        package var moduleValues: [ObjectIdentifier: Any] = [:]

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
    /// `CefWindow` of its own, still connected to its opener — give
    /// it your toolbar, add it to a tab group, and show it.
    ///
    /// When `nil`, Chromium shows popups in a window of its own design.
    /// When an attachment of the opener must prepare before the first
    /// document, the popup is one CefKit created instead, not connected to
    /// its opener's page; see
    /// ``CefBrowserAttachment/preparesBeforeFirstDocument``.
    @ObservationIgnored public var onPopup: ((CefWindow) -> Void)?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Every open window, in creation order.
    public private(set) static var all: [CefWindow] = []

    /// How many windows Chromium has yet to destroy, hidden service windows
    /// included. Shutting down has to wait for this to reach zero.
    private(set) static var liveCount = 0

    @ObservationIgnored private var cefWindow: CefRef<cef_window_t>?
    @ObservationIgnored private var browserView: CefRef<cef_browser_view_t>?
    @ObservationIgnored private var accessoryController: NSTitlebarAccessoryViewController?

    /// Creates the window and its browser. `browser` must not have been
    /// hosted elsewhere. The window stays hidden until ``show()``.
    ///
    /// On a profile Chromium is still loading (``CefProfile/ready()``), the
    /// window opens at once and its browser joins it once the profile is
    /// loaded. On one Chromium cannot load, the browser closes, and the
    /// window with it.
    public init(browser: CefBrowser, configuration: Configuration = .init()) {
        self.browser = browser
        self.configuration = configuration
        Self.all.append(self)
        Self.liveCount += 1
        Self.installRuntimeHooks()

        if browser.profileAllowsCreation(for: self, { [weak self] _ in self?.addBrowserViewWhenProfileIsReady() }) {
            browserView = makeBrowserView()
        } else {
            browser.isChromeStyle = true
        }
        createWindow()
        if browser.state == .closed { close() }
    }

    /// A new Chrome-style view for ``browser``.
    private func makeBrowserView() -> CefRef<cef_browser_view_t>? {
        let viewDelegate = BrowserViewDelegate(toolbar: configuration.toolbar, window: self)
        return CefRef(adopting: browser.createBrowserView(
            delegate: viewDelegate.makeDelegate(),
            showsStatusBubble: configuration.showsChromiumStatusBubble,
            showsZoomBubble: configuration.showsChromiumZoomBubble))
    }

    /// The browser's profile has finished loading since the window opened:
    /// Chromium creates the browser now that its view joins the window.
    private func addBrowserViewWhenProfileIsReady() {
        guard !isClosed, browserView == nil, let window = cefWindow?.pointer else { return }
        guard browser.profileAllowsCreation(for: self, { [weak self] _ in self?.addBrowserViewWhenProfileIsReady() }) else {
            if browser.state == .closed { close() }
            return
        }
        browserView = makeBrowserView()
        addBrowserView(to: window)
        applyLayout()
    }

    private func addBrowserView(to window: UnsafeMutablePointer<cef_window_t>) {
        guard let browserView else { return }
        // add_child_view consumes a reference to the view.
        cefAddRef(browserView.pointer)
        window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
            browserView.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) { view in
                panel.pointee.add_child_view(panel, view)
            }
        }
    }

    /// Wraps a popup's browser view, created by Chromium, in a window.
    fileprivate init(popupView: CefRef<cef_browser_view_t>, browser: CefBrowser, opener: CefWindow) {
        self.browser = browser
        var configuration = opener.configuration
        configuration.frame = nil
        configuration.moduleValues = [:]
        self.configuration = configuration
        self.isPopup = true
        Self.all.append(self)
        Self.liveCount += 1
        Self.installRuntimeHooks()
        browserView = popupView
        createWindow()
    }

    @ObservationIgnored private var isPopup = false

    /// A hidden window hosting an internal-page service browser (native
    /// tab discarding, CefChromium's bookmarks and history). Such windows
    /// are left out of ``all``.
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

    /// Installs the overrides of Chromium's AppKit classes that swipe
    /// navigation relies on, once.
    private static func installRuntimeHooks() {
        CefHistorySwipeHooks.install()
    }

    /// The open window whose `NSWindow` is `window`.
    package static func owning(_ window: NSWindow) -> CefWindow? {
        all.first { $0.window === window }
    }

    /// The window showing `browser`, if it is shown in a ``CefWindow``.
    static func hosting(_ browser: CefBrowser) -> CefWindow? {
        all.first { $0.browser === browser }
    }

    // MARK: Module state

    /// What a module built on CefKit keeps for this window: one object per
    /// type, made by `make` on first use and kept as long as the window.
    /// Hold the window weakly from it. An object that is a
    /// ``CefWindowParticipant`` is told when the window closes.
    package func moduleState<State: AnyObject>(_ type: State.Type = State.self, make: () -> State) -> State {
        let key = ObjectIdentifier(type)
        if let state = moduleStates[key] as? State { return state }
        let state = make()
        moduleStates[key] = state
        return state
    }

    /// The object of `type` a module keeps for this window, if it made one.
    package func existingModuleState<State: AnyObject>(_ type: State.Type) -> State? {
        moduleStates[ObjectIdentifier(type)] as? State
    }

    @ObservationIgnored private var moduleStates: [ObjectIdentifier: AnyObject] = [:]

    /// Decides Chrome commands before Chromium runs them, for every browser
    /// window: from Chrome's shortcuts, menus and UI, and from
    /// ``CefBrowser/execute(_:disposition:)``. An interceptor returns
    /// whether it handled the command, which Chromium then does not run.
    /// Interceptors run in the order they were added, after the browser's
    /// delegate.
    package static func addChromeCommandInterceptor(
        _ interceptor: @escaping @MainActor (CefWindow, CefChromeCommand) -> Bool
    ) {
        commandInterceptors.append(interceptor)
    }

    private static var commandInterceptors: [@MainActor (CefWindow, CefChromeCommand) -> Bool] = []

    /// Whether an interceptor handled `command`.
    func intercept(_ command: CefChromeCommand) -> Bool {
        Self.commandInterceptors.contains { $0(self, command) }
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
        onPopup(CefWindow(popupView: popupView, browser: popup, opener: self))
        return true
    }

    private func mirrorPageTitle() {
        guard !isClosed else { return }
        let title = withObservationTracking {
            configuration.title(browser)
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirrorPageTitle() }
        }
        window?.title = title
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
            CefLog.error("CefWindow: the window has closed; its setup is ignored")
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

    func applyLayout() {
        updateContentFrame()
        updatePageOverlay()
        guard let window = cefWindow?.pointer else { return }
        var settings = cef_box_layout_settings_t()
        settings.size = MemoryLayout<cef_box_layout_settings_t>.stride
        settings.inside_border_insets = cef_insets_t(
            top: Int32(saturating: contentInsets.top), left: Int32(saturating: contentInsets.left),
            bottom: Int32(saturating: contentInsets.bottom), right: Int32(saturating: contentInsets.right))
        settings.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.main_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
        settings.default_flex = 1
        // cef_window_t begins with its cef_panel_t base.
        window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
            addChromeToolbar(to: panel)
            let layout = panel.pointee.set_to_box_layout(panel, &settings)
            if let layout, let toolbar = chromeToolbarView {
                // The toolbar keeps its height; the page takes the rest.
                cefAddRef(toolbar.pointer)
                layout.pointee.set_flex_for_view(layout, toolbar.pointer, 0)
            }
            cefRelease(layout)
            panel.pointee.layout(panel)
        }
    }

    /// Chrome's toolbar (``Toolbar/chrome``, ``Toolbar/location``), which
    /// CEF creates with the browser view but leaves to the window to place:
    /// once the view is in the window, above it. Chromium's extension
    /// actions, `chrome.action.openPopup()` and its toolbar bubbles need it.
    @ObservationIgnored private var chromeToolbarView: CefRef<cef_view_t>?

    /// Whether Chrome's toolbar is in the window. For tests.
    @_spi(Testing) public var hasChromeToolbar: Bool { chromeToolbarView != nil }

    /// The toolbar view's state, for tests.
    @_spi(Testing) public var chromeToolbarDescription: String {
        guard let view = chromeToolbarView?.pointer, let window = cefWindow?.pointer else { return "none" }
        let bounds = view.pointee.get_bounds(view)
        let preferred = view.pointee.get_preferred_size(view)
        let children = window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { $0.pointee.get_child_view_count($0) }
        return "visible \(view.pointee.is_visible(view)) drawn \(view.pointee.is_drawn(view)) attached \(view.pointee.is_attached(view)) "
            + "bounds \(bounds.width)x\(bounds.height) preferred \(preferred.width)x\(preferred.height) window children \(children)"
    }

    private func addChromeToolbar(to panel: UnsafeMutablePointer<cef_panel_t>) {
        guard chromeToolbarView == nil, let browserView else { return }
        guard let view = CefRef(adopting: browserView.pointer.pointee.get_chrome_toolbar(browserView.pointer)) else { return }
        chromeToolbarView = view
        // add_child_view_at consumes a reference to the view.
        cefAddRef(view.pointer)
        panel.pointee.add_child_view_at(panel, view.pointer, 0)
        // CEF makes it hidden.
        view.pointer.pointee.set_visible(view.pointer, 1)
    }

    // MARK: Over the page

    /// A view of your own laid over the page: a swipe indicator drawn from
    /// ``CefBrowser/navigationGestureProgress``, a status bubble drawn from
    /// ``CefBrowser/statusText``, a banner. It is sized to the page, inside
    /// ``contentInsets`` and clipped to ``contentCornerRadius``, and never
    /// receives events, so the page beneath takes every click and scroll.
    /// It stays installed until you replace it; to show several views, put
    /// them in one. CefSwiftUI's `setPageOverlay(_:)` sets it from a
    /// SwiftUI view.
    public var pageOverlay: NSView? {
        didSet {
            guard pageOverlay !== oldValue else { return }
            oldValue?.removeFromSuperview()
            updatePageOverlay()
        }
    }

    @ObservationIgnored private var pageOverlayContainer: PageOverlayView?

    /// Lays ``pageOverlay`` over the page.
    private func updatePageOverlay() {
        guard let pageOverlay, let contentView = window?.contentView else {
            pageOverlayContainer?.removeFromSuperview()
            pageOverlayContainer = nil
            return
        }
        let container = pageOverlayContainer ?? PageOverlayView()
        if container.superview !== contentView {
            container.frame = contentView.bounds
            container.autoresizingMask = [.width, .height]
            contentView.addSubview(container, positioned: .above, relativeTo: nil)
            pageOverlayContainer = container
        }
        container.insets = contentInsets
        container.cornerRadius = contentCornerRadius
        container.setView(pageOverlay)
    }

    // MARK: Delegate callbacks

    /// Paints the browser's canvas (``CefBrowser/Configuration/backgroundColor``)
    /// behind its page. A Chrome-style page leaves its canvas transparent,
    /// and what shows there is the web contents view's background, the
    /// theme's `kColorWebContentsBackground`: white in a light appearance,
    /// dark gray in a dark one, so unstyled pages turned dark with the app.
    /// Chromium resets theme colors when the theme changes, before
    /// `on_theme_colors_changed`, which applies this again.
    func applyCanvasColor(to window: UnsafeMutablePointer<cef_window_t>, notifying: Bool) {
        window.pointee.set_theme_color(
            window, Int32(CEF_ColorWebContentsBackground.rawValue), browser.canvasColor.opaqueCefColor)
        if notifying { window.pointee.theme_changed(window) }
    }

    /// Adds a Chrome-style view for `browser` beside the window's own, for
    /// SelfTest's check that CEF still allows one Chrome-style browser per
    /// window: CEF 156 leaves the second view empty and never creates its
    /// browser ("Cannot add multiple Chrome style BrowserViews").
    @_spi(Testing) public func addBrowserViewForTesting(_ browser: CefBrowser) {
        guard let window = cefWindow?.pointer,
              let view = CefRef(adopting: browser.createBrowserView(
                  delegate: BrowserViewDelegate(toolbar: .none, window: nil).makeDelegate(),
                  showsStatusBubble: true, showsZoomBubble: true))
        else { return }
        extraViewsForTesting.append(view)
        cefAddRef(view.pointer)
        window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
            view.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) { panel.pointee.add_child_view(panel, $0) }
            panel.pointee.layout(panel)
        }
    }

    @ObservationIgnored private var extraViewsForTesting: [CefRef<cef_browser_view_t>] = []

    /// The color Chromium paints behind the page, from the window's theme.
    @_spi(Testing) public var webContentsBackgroundColor: UInt32? {
        browserView.map { view in
            view.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) {
                $0.pointee.get_theme_color($0, Int32(CEF_ColorWebContentsBackground.rawValue))
            }
        }
    }

    func windowCreated(_ window: UnsafeMutablePointer<cef_window_t>) {
        applyCanvasColor(to: window, notifying: true)
        addBrowserView(to: window)
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
            updatePageOverlay()
            let waiters = windowWaiters
            windowWaiters = []
            waiters.forEach { $0(nsWindow) }
        }
    }

    func windowDestroyed() {
        serviceWindowObserver.map(NotificationCenter.default.removeObserver)
        serviceWindowObserver = nil
        for state in moduleStates.values {
            (state as? CefWindowParticipant)?.windowDidClose(self)
        }
        accessoryController = nil
        windowWaiters = []
        cefWindow = nil
        chromeToolbarView = nil
        browserView = nil
        extraViewsForTesting = []
        isClosed = true
        // Closed before its profile loaded: the browser never came.
        if browser.state == .pending { browser.close() }
        Self.all.removeAll { $0 === self }
        Self.liveCount -= 1
        onClose?()
        CefRuntime.shared.continueTerminationIfReady()
    }
}

/// An object a module keeps for a ``CefWindow``
/// (``CefWindow/moduleState(_:make:)``) that has to know when the
/// window closes.
@MainActor
package protocol CefWindowParticipant: AnyObject {
    /// The window has been destroyed; drop what it held.
    func windowDidClose(_ window: CefWindow)
}
