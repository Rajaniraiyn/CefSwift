import AppKit
import CefSwiftUI
import SwiftUI

/// The browser's tabs, and the window each is shown in.
///
/// Each tab is a Chrome-style ``CefWindow`` (so `chrome://settings`,
/// `chrome://extensions`, history, downloads and PDF viewing all work) with
/// a SwiftUI toolbar on top. Windows share a tabbing identifier, so macOS
/// presents them as native tabs. The controller puts each window together
/// from the browser's features and is the delegate of every tab's browser,
/// passing the decisions features make on to them.
@MainActor
@Observable
final class BrowserController: CefBrowserDelegate {
    static let tabbingIdentifier = "browser"

    /// The Chromium tabs, in the order they opened.
    private(set) var tabs: [CefWindow] = []

    /// The browser in the frontmost tab.
    var current: CefBrowser? { keyBrowser ?? tabs.last?.browser }

    /// The page of the frontmost tab, whichever engine shows it.
    var frontmostPage: (any TabPage)? {
        otherTabs.first { $0.window?.isKeyWindow == true }?.page ?? current
    }

    /// The browser's own start page, when a feature serves one
    /// (`StartPage`). New tabs open with it unless Settings say otherwise.
    var startPage: URL?

    /// Where new tabs open.
    var newTabPage: URL {
        let setting = UserDefaults.standard.string(forKey: Self.newTabPageKey).flatMap { URL(string: $0) }
        return setting ?? startPage ?? URL(string: "about:blank")!
    }

    static let newTabPageKey = "newTabPage"

    /// Whether `url` is the start page, which the toolbar shows like a
    /// blank tab.
    func isStartPage(_ url: URL?) -> Bool {
        guard let url, let startPage else { return false }
        return url.scheme == startPage.scheme && url.host() == startPage.host()
    }

    /// Called whenever a tab's page finishes loading.
    @ObservationIgnored var onPageLoad: ((CefBrowser) -> Void)?

    @ObservationIgnored let features: any BrowserFeature

    /// The browser whose window is key, tracked so that views and menus
    /// depending on the frontmost tab update when it changes.
    private var keyBrowser: CefBrowser?

    /// Tabs shown by another engine (`WebKitTabs`), so the menus reach them.
    @ObservationIgnored private var otherTabs: [OtherTab] = []

    private struct OtherTab {
        weak var window: NSWindow?
        let page: any TabPage
    }

    init(features: some BrowserFeature) {
        self.features = features
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let match = self.tabs.first(where: { $0.window === window }) else { return }
                self.keyBrowser = match.browser
            }
        }
    }

    /// Starts the features, then opens the tabs the launch options ask for.
    func start() {
        features.start(self)
        LaunchOptions().openTabs(in: self)
    }

    // MARK: Tabs

    @discardableResult
    func openTab(
        url: URL? = nil, isPrivate: Bool = false, inBackground: Bool = false, sharingProfileOf source: CefBrowser? = nil
    ) -> CefBrowser {
        var configuration = CefBrowser.Configuration()
        // Tabs opened from a private tab stay in its private session.
        configuration.profile = source?.configuration.profile ?? (isPrivate ? .incognito() : .default)
        configuration.allowsBackForwardNavigationGestures = true
        features.configure(&configuration)
        let browser = CefBrowser(url: url ?? newTabPage, configuration: configuration, delegate: self)

        var windowConfiguration = CefWindow.Configuration()
        windowConfiguration.tabbingIdentifier = Self.tabbingIdentifier
        windowConfiguration.title = Self.tabTitle(for:)
        windowConfiguration.frame = tabs.last?.window?.frame
        let window = CefWindow(browser: browser, configuration: windowConfiguration)
        window.setToolbar {
            NavigationButtons(browser: browser)
        } principal: {
            toolbarItems(.principal, for: browser)
        } trailing: {
            HStack(spacing: 2) {
                toolbarItems(.trailing, for: browser)
                Button("New Tab", systemImage: "plus") { [weak self] in self?.openTab() }
            }
            .buttonStyle(ToolbarIconButtonStyle())
        }
        window.setTabAccessory { TabIcon(browser: browser).environment(self) }
        window.window?.contentMinSize = NSSize(width: 560, height: 320)
        // Frame the page as a rounded card inset from the window edges.
        window.contentInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        window.contentCornerRadius = 10
        windowDidOpen(window)
        window.onClose = { [weak self, weak window] in
            self?.tabs.removeAll { $0 === window }
            if self?.keyBrowser === browser { self?.keyBrowser = nil }
        }
        tabs.append(window)

        if let group = tabGroup(excluding: window.window), let new = window.window {
            group.addTabbedWindow(new, ordered: .above)
            if !inBackground { new.makeKeyAndOrderFront(nil) }
        } else {
            window.show()
        }
        return browser
    }

    /// Shows a window that is not one of Chromium's as a tab beside the
    /// frontmost one: a tab whose page another engine shows. The menus that
    /// navigate reach `page` while the window is key.
    func showTab(_ window: NSWindow, page: any TabPage) {
        otherTabs.append(OtherTab(window: window, page: page))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated { self?.otherTabs.removeAll { $0.window == nil || $0.window === window } }
        }
        window.tabbingIdentifier = Self.tabbingIdentifier
        if let group = tabGroup(excluding: window) {
            window.setFrame(group.frame, display: false)
            group.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The window of the tab group new tabs join: the key window if it is a
    /// tab, otherwise the last visible tab.
    private func tabGroup(excluding new: NSWindow?) -> NSWindow? {
        if let key = NSApp.keyWindow, key !== new, key.tabbingIdentifier == Self.tabbingIdentifier { return key }
        return tabs.lazy.compactMap(\.window).last { $0 !== new && $0.isVisible }
    }

    /// The window showing `browser`, if it is a tab.
    func window(of browser: CefBrowser) -> CefWindow? {
        tabs.first { $0.browser === browser }
    }

    /// Opens `url` in the frontmost tab, as Safari's menus do.
    func openInFrontmostTab(_ url: URL) {
        if let current { current.load(url) } else { openTab(url: url) }
    }

    /// The browser of a tab showing `url`, if there is one.
    func tab(showing url: URL) -> CefBrowser? {
        tabs.first { $0.browser.url == url }?.browser
    }

    /// Brings the tab showing `url` to the front, if there is one.
    @discardableResult
    func switchToTab(showing url: URL) -> Bool {
        guard let match = tabs.first(where: { $0.browser.url == url })?.window else { return false }
        match.makeKeyAndOrderFront(nil)
        return true
    }

    /// Puts the frontmost tab's address field (the toolbar's first text
    /// field) into editing.
    func focusAddressBar() {
        guard let window = (tabs.first { $0.window?.isKeyWindow == true } ?? tabs.last)?.window else { return }
        let field = window.toolbar?.items.lazy.compactMap { $0.view?.firstSubview(of: NSTextField.self) }.first
        window.makeKeyAndOrderFront(nil)
        if let field { window.makeFirstResponder(field) }
    }

    /// A tab's title. Blank pages — a new tab, a link opened with
    /// `window.open()` — are titled "New Tab" rather than Chromium's
    /// "about:blank".
    static func tabTitle(for browser: CefBrowser) -> String {
        guard let url = browser.url, url.absoluteString != "about:blank" else { return "New Tab" }
        let title = browser.title
        guard !title.isEmpty, title != url.absoluteString else { return url.host() ?? url.absoluteString }
        return title
    }

    // MARK: Putting windows together

    /// Gives a tab's or popup's window what the features add to it.
    func windowDidOpen(_ window: CefWindow) {
        let browser = window.browser
        func overlay(of features: some BrowserFeature) -> AnyView { AnyView(features.pageOverlay(for: browser)) }
        window.setPageOverlay {
            ZStack { overlay(of: features) }
                .environment(self)
        }
        PopupPresenter.hostPopups(of: window, controller: self)
        features.windowDidOpen(window)
    }

    /// The features' views for one place in a tab's toolbar.
    func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        func items(of features: some BrowserFeature) -> AnyView { AnyView(features.toolbarItems(placement, for: browser)) }
        return items(of: features).environment(self)
    }

    // MARK: CefBrowserDelegate

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        onPageLoad?(browser)
    }

    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        features.decidePolicy(for: navigation, in: browser) ?? .allow
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
        // Real popups (sign-in windows and the like) keep Chromium's handling
        // and arrive through the window's onPopup.
        guard request.disposition != .newPopup, let url = request.targetURL else { return .allowNativePopup }
        // Open Link in Incognito Window, from the context menu, opens a
        // private tab.
        let isPrivate = request.disposition == .offTheRecord
        openTab(url: url, isPrivate: isPrivate, inBackground: request.disposition == .newBackgroundTab,
                sharingProfileOf: isPrivate ? nil : browser)
        return .handled
    }

    func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        switch command {
        case .newTab:
            openTab()
            return true
        case .focusLocation:
            focusAddressBar()
            return true
        default:
            return false
        }
    }

    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        await features.decidePermission(for: request, in: browser) ?? .deny
    }
}

/// What the menus need of a tab's page, whichever engine shows it.
@MainActor
protocol TabPage: AnyObject {
    var url: URL? { get }
    func goBack()
    func goForward()
    func reload(ignoringCache: Bool)
}

extension CefBrowser: TabPage {}

extension CefBrowser {
    /// Whether the browser keeps to a profile of its own, such as a private
    /// tab's, rather than the default one.
    var isPrivate: Bool { configuration.profile.map { $0 !== CefProfile.default } ?? false }
}

extension NSView {
    func firstSubview<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
