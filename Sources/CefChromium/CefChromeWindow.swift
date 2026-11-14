import AppKit
import CefKit
import Foundation
import Observation

/// One of Chromium's own tabbed windows (a Chromium `Browser` of type
/// `normal`, with a real `TabStripModel`): the window that holds a
/// collection of ``CefTab``s, shows its active tab's page, and leaves the
/// rest of the window to the app.
///
/// ```swift
/// let window = try await CefChromeWindow.open(url: home)
/// window.showsChromeUI = false              // the app draws tabs and toolbar
/// window.setTopBar { MyTabBar(window: window) }
/// try await window.openTab(URL(string: "https://swift.org")!)
/// ```
///
/// Chromium draws these windows itself; CefChromium covers the top of the
/// window, where Chrome's tab strip and toolbar are, with the app's own
/// ``topBar`` (and, with tabs at the side, its ``sidebar``) when
/// ``showsChromeUI`` is off. Chrome's covered controls are then out of the
/// app's way: they get no clicks, no keyboard focus and no accessibility
/// presence. The page, Chrome's side panel, find bar and bubbles stay
/// Chromium's.
///
/// Use it for windows of several tabs that are Chromium's own: what
/// extensions do with `chrome.tabs` and `chrome.tabGroups`, Chrome's tab
/// commands, recently closed tabs and moving tabs between windows (which
/// keeps each tab's ``CefBrowser``) then all work. For one page in a window
/// of the app's design, use ``CefWindow``: a CEF Views window, which
/// Chromium counts as a popup window of one tab. For a page inside the
/// app's own views, use `CefWebView`: those pages are not Chromium tabs.
///
/// The profile's ``CefTabStrip`` lists every such window, including those
/// Chromium opens on its own, such as a window `chrome.windows.create`
/// opens; ``CefTabStrip/onWindowOpened`` sees each.
@MainActor
@Observable
public final class CefChromeWindow: Identifiable {
    /// Chromium's window identifier (`chrome.windows` ids).
    public struct ID: Hashable, Sendable, CustomStringConvertible, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public var description: String { String(rawValue) }
    }

    public nonisolated let id: ID
    /// The profile's tab strip, which lists the window.
    public let strip: CefTabStrip
    /// The profile the window's tabs belong to.
    public var profile: CefProfile { strip.profile }

    /// The window's tabs, in the strip's order: pinned ones first.
    public private(set) var tabs: [CefTab] = []
    /// The window's tab groups, in the strip's order.
    public private(set) var groups: [CefTabGroup] = []
    /// Whether the window is Chromium's focused one.
    public private(set) var isFocused = false
    /// Whether the window is closed. A closed window has no tabs.
    public private(set) var isClosed = false
    /// The window's bounds as Chromium reports them (`chrome.windows`
    /// coordinates: points from the top left of the main screen).
    public private(set) var bounds = CGRect.zero

    /// The tab shown.
    public var activeTab: CefTab? { tabs.first(where: \.isActive) }
    /// The tabs selected together, the active one among them.
    public var selectedTabs: [CefTab] { tabs.filter(\.isSelected) }

    /// The AppKit window Chromium shows the window in. Chromium owns its
    /// lifetime: close it with ``close()``. `nil` until known, which is
    /// as soon as the window's active tab is matched with its browser.
    public private(set) var window: NSWindow?

    /// Called once the window has closed.
    @ObservationIgnored public var onClose: (() -> Void)?

    init(id: ID, strip: CefTabStrip) {
        self.id = id
        self.strip = strip
    }

    // MARK: Opening

    /// Opens a new window of `profile` showing `url`, and returns it once
    /// Chromium lists it.
    ///
    /// The first tab's browser is made with `configuration` and
    /// `delegate`, as ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)``
    /// makes one; it is held weakly, like ``CefBrowser/delegate``.
    public static func open(
        url: URL, profile: CefProfile = .default, frame: CGRect? = nil,
        configuration: CefBrowser.Configuration = .init(), delegate: CefBrowserDelegate? = nil
    ) async throws -> CefChromeWindow {
        let strip = profile.tabStrip
        var configuration = configuration
        configuration.profile = profile
        return try await strip.openWindow(
            url: url, frame: frame, configuration: configuration, delegate: delegate, isTransient: false).window
    }

    /// Opens `url` in a new tab of this window, at `index` (by default the
    /// end), and returns the tab.
    ///
    /// The tab's browser is made with `configuration` and `delegate`, so
    /// its bridges, user scripts and attachments are there from the first
    /// page: Chromium only adds tabs to its windows itself, so the browser
    /// starts in a window of its own, kept off screen, and Chromium then
    /// moves its tab here, which keeps the browser.
    @discardableResult
    public func openTab(
        _ url: URL, at index: Int? = nil, isActive: Bool = true,
        configuration: CefBrowser.Configuration = .init(), delegate: CefBrowserDelegate? = nil
    ) async throws -> CefTab {
        guard !isClosed else { throw CefTabStrip.Error.tabClosed }
        var configuration = configuration
        configuration.profile = profile
        let frame = CGRect(x: -20_000, y: -20_000, width: max(bounds.width, 800), height: max(bounds.height, 600))
        let (holder, browser, hider) = try await strip.openWindow(
            url: url, frame: frame, configuration: configuration, delegate: delegate, isTransient: true)
        defer {
            hider?.stop()
            strip.transientBrowsers.remove(ObjectIdentifier(browser))
        }
        let id = try await strip.adoptSingleTab(of: holder.id, into: self, at: index, isActive: isActive)
        strip.bind(browser, to: id)
        await strip.nextRead()
        if isActive { window?.makeKeyAndOrderFront(nil) }
        guard let tab = strip.tab(id) else { throw CefTabStrip.Error.tabClosed }
        return tab
    }

    /// Opens `url` in a new tab Chromium makes itself, as
    /// `chrome.tabs.create` does: its browser has CefKit's default
    /// configuration (no bridges, user scripts or attachments) and reaches
    /// the app through ``CefRuntime/onBrowserCreated``.
    @discardableResult
    public func openChromiumTab(_ url: URL, at index: Int? = nil, isActive: Bool = true) async throws -> CefTab {
        try await strip.chromiumTab(url, in: self, at: index, isActive: isActive)
    }

    /// Closes every tab, and so the window. Pages' `beforeunload` handlers
    /// may keep their tabs open.
    public func close() {
        strip.close(self)
    }

    /// Brings the window to the front.
    public func focus() async throws {
        window?.makeKeyAndOrderFront(nil)
        try await strip.focus(self)
    }

    /// Reopens the tab, window or group closed last, as ⌘⇧T does.
    public func reopenClosedTab() {
        strip.reopenClosed(in: self)
    }

    // MARK: The app's regions

    /// Whether Chrome's own tab strip and toolbar show. When `false`, the
    /// app's ``topBar`` and ``sidebar`` cover them, and Chrome's covered
    /// controls take no clicks, keyboard focus or accessibility focus.
    ///
    /// Chromium lays out its window itself, so the covered area is the
    /// height Chrome's tab strip and toolbar take (and, with tabs at the
    /// side, the width of its vertical tab strip, ``CefTabStrip/layout``);
    /// ``topBarHeight`` and ``sidebarWidth`` report it, and the page is in
    /// ``contentFrame``.
    public var showsChromeUI = true {
        didSet { host?.update() }
    }

    /// The app's view over the top of the window, where Chrome's tab strip
    /// and toolbar are. Shown while ``showsChromeUI`` is off. The window
    /// buttons stay above it.
    public var topBar: NSView? {
        didSet { if topBar !== oldValue { oldValue?.removeFromSuperview(); host?.update() } }
    }

    /// The app's view along the leading edge, over Chrome's vertical tab
    /// strip, while ``CefTabStrip/layout`` puts tabs at the side.
    public var sidebar: NSView? {
        didSet { if sidebar !== oldValue { oldValue?.removeFromSuperview(); host?.update() } }
    }

    /// A view laid over the active tab's page, passing every event through
    /// to it, as ``CefWindow/pageOverlay``.
    public var pageOverlay: NSView? {
        didSet { if pageOverlay !== oldValue { oldValue?.removeFromSuperview(); host?.update() } }
    }

    /// Where the active tab's page is, in the window's content view, in
    /// points from its top left. It follows resizing, full screen,
    /// Chrome's bookmarks bar, infobars and side panel.
    public internal(set) var contentFrame = CGRect.zero
    /// The height of the area at the top the app's ``topBar`` covers.
    public internal(set) var topBarHeight: CGFloat = 0
    /// The width of the area at the leading edge the app's ``sidebar``
    /// covers: zero unless tabs are at the side.
    public internal(set) var sidebarWidth: CGFloat = 0

    @ObservationIgnored var host: ChromeWindowHost?
    @ObservationIgnored private var announced = false
    @ObservationIgnored var isTransient = false

    // MARK: Updates from the strip

    func update(tabs: [CefTab], groups: [CefTabGroup], isFocused: Bool, bounds: [Double]?, state: String?) {
        if self.tabs.map(\.id) != tabs.map(\.id) { self.tabs = tabs }
        if self.groups.map(\.id) != groups.map(\.id) { self.groups = groups }
        if self.isFocused != isFocused { self.isFocused = isFocused }
        if let bounds, bounds.count == 4 {
            let rect = CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3])
            if self.bounds != rect { self.bounds = rect }
        }
        host?.update()
    }

    /// The window's `NSWindow` is known.
    func attach(to nsWindow: NSWindow) {
        guard window == nil, !isClosed else { return }
        window = nsWindow
        host = ChromeWindowHost(window: self, nsWindow: nsWindow)
        host?.update()
        announceIfNeeded()
    }

    /// Hands the window to ``CefTabStrip/onWindowOpened``, once, when it
    /// is known and not a transient one.
    func announceIfNeeded() {
        guard !announced, !isTransient, window != nil, !isClosed else { return }
        announced = true
        strip.onWindowOpened?(self)
    }

    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        host?.tearDown()
        host = nil
        tabs = []
        groups = []
        onClose?()
    }
}

extension CefTabStrip {
    /// Where Chrome's windows put their tabs; a profile preference.
    public enum Layout: Hashable, Sendable {
        /// Across the top, Chrome's default.
        case horizontal
        /// Down the leading edge, in a strip `width` points wide: Chrome's
        /// vertical tabs (`vertical_tabs.enabled`).
        case vertical(width: CGFloat)
    }

    /// Where the profile's windows put their tabs. The app's
    /// ``CefChromeWindow/sidebar`` covers Chrome's vertical tab strip, and
    /// takes its width.
    public var layout: Layout {
        get {
            let preferences = profile.preferences
            guard preferences.value(named: "vertical_tabs.enabled")?.boolValue == true else { return .horizontal }
            let width = preferences.value(named: "vertical_tabs.uncollapsed_width")?.doubleValue ?? 240
            return .vertical(width: CGFloat(width))
        }
        set {
            let preferences = profile.preferences
            switch newValue {
            case .horizontal:
                try? preferences.setValue(.bool(false), named: "vertical_tabs.enabled")
            case .vertical(let width):
                try? preferences.setValue(.number(Double(width)), named: "vertical_tabs.uncollapsed_width")
                try? preferences.setValue(.bool(false), named: "vertical_tabs.collapsed_state")
                try? preferences.setValue(.bool(true), named: "vertical_tabs.enabled")
            }
            for window in windows { window.host?.update() }
        }
    }

    /// Opens a window for a browser the app makes, and returns it once
    /// Chromium lists it, with the browser matched with its one tab.
    func openWindow(
        url: URL, frame: CGRect?, configuration: CefBrowser.Configuration, delegate: CefBrowserDelegate?, isTransient: Bool
    ) async throws -> (window: CefChromeWindow, browser: CefBrowser, hider: ChromeWindowHider?) {
        startFollowing()
        let browser = CefRuntime.shared.openChromeWindow(url: url, frame: frame, configuration: configuration, delegate: delegate)
        let hider = isTransient ? ChromeWindowHider(browser: browser) : nil
        if isTransient { transientBrowsers.insert(ObjectIdentifier(browser)) }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            guard browser.state != .closed else { throw Error.chromium("Chromium closed the new window's browser.") }
            // The window of one tab in the new browser's NSWindow, which no
            // other window has: Chromium lists it once the browser exists.
            if let nsWindow = browser.nativeView?.window {
                let known = allWindows.first { $0.window === nsWindow }
                let new = known.map { [$0] } ?? allWindows.filter { window in
                    window.window == nil && window.tabs.count == 1
                        && (window.tabs[0].browser === browser || window.tabs[0].browser == nil)
                }
                if new.count == 1, let window = new.first, window.tabs.count == 1 {
                    bind(browser, to: window.tabs[0].id)
                    window.isTransient = isTransient
                    window.attach(to: nsWindow)
                    return (window, browser, hider)
                }
            }
            await nextRead()
            try await Task.sleep(for: .milliseconds(30))
        }
        hider?.stop()
        browser.close(force: true)
        throw Error.chromium("Chromium did not open the window.")
    }
}

/// Keeps the window Chromium makes for one browser off screen and unseen,
/// until ``stop()``: the window a new tab starts in before Chromium moves
/// it to the window it belongs in.
@MainActor
final class ChromeWindowHider {
    private weak var browser: CefBrowser?
    private var observer: NSObjectProtocol?
    private let alreadyVisible: Set<ObjectIdentifier>

    init(browser: CefBrowser) {
        self.browser = browser
        alreadyVisible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        guard let window = browser?.nativeView?.window, !alreadyVisible.contains(ObjectIdentifier(window)) else { return }
        if window.alphaValue > 0 { window.alphaValue = 0 }
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        if window.isVisible { window.orderOut(nil) }
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }
}
