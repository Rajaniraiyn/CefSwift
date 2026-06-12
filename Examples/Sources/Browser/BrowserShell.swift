import AppKit
import CefKit
import CefSwiftUI
import Observation
import SwiftUI

/// One browser tab. In the inverted-ownership shell a single Chrome-runtime
/// browser backs the window; each tab remembers its own address and last-seen
/// title/favicon, and selecting a tab navigates the shared browser to it.
@Observable
@MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    var url: URL
    var title: String = ""
    var faviconURL: URL?

    init(url: URL) { self.url = url }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url.host() ?? "New Tab"
    }
}

/// The Arc-style browser shell, built on the inverted-ownership hosting mode.
///
/// Owns one ``CefChromeWindow`` (a real Chrome-runtime window, Chrome's own
/// toolbar hidden) whose native SwiftUI chrome — tab strip + omnibox — is
/// hosted as an overlay on top, with web content inset below it. Because it is
/// the full Chrome runtime, `chrome://history`, `chrome://extensions`,
/// `chrome://settings`, `chrome://downloads` and `chrome://flags` all render
/// here (they're blank in Alloy-style embedded views).
///
/// Acts as the window's `CefBrowserDelegate`, mirroring navigation state into
/// `@Observable` properties the overlay binds to.
@Observable
@MainActor
final class BrowserShell {
    static let homeURL = URL(string: "https://duckduckgo.com")!

    /// Height of the native chrome strip (toolbar). The browser view is inset
    /// by this much so content sits below the toolbar, not under it.
    static let chromeHeight: CGFloat = 96

    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: BrowserTab.ID?

    // Mirrored navigation state (from the shared browser).
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var currentURL: URL?

    /// Bumped to ask the omnibox to take focus (⌘L).
    private(set) var omniboxFocusToken = 0

    private(set) var window: CefChromeWindow?
    private var browser: CefBrowser? { window?.browser }
    /// Guards the feedback loop when mirroring the browser's address back out.
    private var applyingBrowserURL = false

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    init() {}

    // MARK: Window lifecycle

    /// Opens the chrome window, installs the SwiftUI overlay, and seeds the
    /// first tab. Call once the CEF runtime is up.
    func openWindow(initialURL: URL = BrowserShell.homeURL, bounds: CGRect? = nil) {
        guard window == nil else { return }
        let first = BrowserTab(url: initialURL)
        tabs = [first]
        selectedTabID = first.id

        let win = CefChromeWindow.open(
            url: initialURL,
            initialBounds: bounds ?? CGRect(x: 160, y: 160, width: 1180, height: 800),
            delegate: self
        ) { [weak self] window in
            guard let self else { return }
            window.setContentInsets(
                NSEdgeInsets(top: Self.chromeHeight, left: 0, bottom: 0, right: 0))
            window.setOverlay { ChromeOverlay(shell: self) }
        }
        self.window = win
        win.onClose = { [weak self] in self?.window = nil }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: URL = BrowserShell.homeURL) -> BrowserTab {
        let tab = BrowserTab(url: url)
        tabs.append(tab)
        select(tab)
        return tab
    }

    func select(_ tab: BrowserTab) {
        selectedTabID = tab.id
        navigate(to: tab.url)
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == tab.id {
            select(tabs[min(index, tabs.count - 1)])
        }
    }

    func closeSelectedTab() { if let selectedTab { close(selectedTab) } }

    // MARK: Navigation

    /// Navigates the shared browser and records the address on the active tab.
    func navigate(to url: URL) {
        selectedTab?.url = url
        browser?.load(url)
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }
    func stopLoading() { browser?.stopLoading() }
    func showDevTools() { browser?.showDevTools() }
    func requestOmniboxFocus() { omniboxFocusToken += 1 }

    /// Opens a chrome:// (or any) page in a new tab of this window.
    func openChromePage(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        newTab(url: url)
    }
}

// MARK: - CefBrowserDelegate

extension BrowserShell: CefBrowserDelegate {
    func browser(_ b: CefBrowser, didChangeTitle title: String) {
        selectedTab?.title = title
    }

    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        currentURL = url
        if let url { selectedTab?.url = url }
    }

    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isLoading { estimatedProgress = 1 }
    }

    func browser(_ b: CefBrowser, didChangeProgress progress: Double) {
        estimatedProgress = progress
    }

    func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
        selectedTab?.faviconURL = urls.first
    }

    func browser(_ b: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision {
        // Popups become new tabs in this window.
        if let url { newTab(url: url) }
        return .block
    }

    func browserDidClose(_ b: CefBrowser) {
        window = nil
    }
}
