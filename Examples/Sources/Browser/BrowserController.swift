import AppKit
import CefSwiftUI
import SwiftUI

/// Owns the browser's tabs. Each tab is one ``CefBrowserWindow``; macOS
/// groups them into a native tab bar.
@MainActor
@Observable
final class BrowserController: CefBrowserDelegate {
    static let defaultNewTabPage = BrowserPages.start.absoluteString
    static let tabbingIdentifier = "browser"

    private(set) var windows: [CefBrowserWindow] = []
    /// Tabs shown by WebKit (`SystemEngineTabs.swift`).
    private(set) var systemTabs: [SystemEngineTab] = []

    /// Chromium tabs the user moved out of WebKit, which keep streaming
    /// sites in Chromium.
    @ObservationIgnored private var keptInChromium: Set<ObjectIdentifier> = []

    /// The WebKit tab in front, if the frontmost tab is one.
    var currentSystemTab: SystemEngineTab? {
        systemTabs.first { $0.window.isKeyWindow }
    }

    /// The browser in the frontmost tab.
    var current: CefBrowser? { keyBrowser ?? windows.last?.browser }

    /// Tabs Memory Saver has put to sleep.
    var sleepingTabs: [CefBrowser] { windows.map(\.browser).filter(\.isDiscarded) }

    /// The browser whose window is key, tracked so that views and menus
    /// depending on the frontmost tab update when it changes.
    private var keyBrowser: CefBrowser?

    /// Where new tabs open: the start page unless the Settings say otherwise.
    private var newTabPage: URL {
        URL(string: UserDefaults.standard.string(forKey: "newTabPage") ?? Self.defaultNewTabPage)
            ?? BrowserPages.start
    }

    /// Bookmarks and history, shared by every tab, menu and the start page.
    let library = BrowserLibrary()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let match = self.windows.first(where: { $0.window === window }) else { return }
                self.keyBrowser = match.browser
            }
        }
    }

    @discardableResult
    func openTab(
        url: URL? = nil, isPrivate: Bool = false, inBackground: Bool = false, sharingProfileOf source: CefBrowser? = nil
    ) -> CefBrowser {
        var options = CefBrowserOptions()
        // Tabs opened from a private tab stay in its private session.
        let profile = source?.options.profile ?? (isPrivate ? .incognito() : .default)
        let isPrivate = profile !== CefProfile.default
        options.profile = profile
        if BrowserPasskeys.isEnabled {
            options.passkeys = .app(isPrivate ? BrowserPasskeys.shared.privateStore : BrowserPasskeys.shared)
        }
        options.userScripts = Self.internalPageStyles
        options.bridges = [library.startPageBridge]
        // Two-finger swipes go back and forward, with CefSwift's indicator.
        options.allowsBackForwardNavigationGestures = true
        options.contextMenu.showsInspectElement = true
        options.contextMenu.hiddenCommands = [.viewSource]
        options.contextMenu.items = [
            CefContextMenuItem("Open Link in New Tab", isVisible: { $0.linkURL != nil }) { [weak self] browser, target in
                self?.openTab(url: target.linkURL, inBackground: true, sharingProfileOf: browser)
            },
            CefContextMenuItem("Create QR Code for This Page", isVisible: { $0.linkURL == nil && !$0.isEditable }) { browser, _ in
                browser.execute(.createQRCode)
            },
        ]
        let browser = CefBrowser(url: url ?? newTabPage, options: options, delegate: self)

        var configuration = CefBrowserWindow.Configuration()
        configuration.tabbingIdentifier = Self.tabbingIdentifier
        // Titled by mirrorTabTitle(of:), which names blank tabs "New Tab".
        configuration.titleFollowsPage = false
        configuration.frame = windows.last?.window?.frame
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        window.setToolbar {
            NavigationButtons(browser: browser)
        } principal: {
            AddressBar(browser: browser, controller: self, isPrivate: isPrivate)
        } trailing: {
            TrailingButtons(browser: browser, controller: self)
        }
        window.setTabAccessory { TabIcon(browser: browser) }
        ChromiumPanels.configure(window)
        window.window?.contentMinSize = NSSize(width: 560, height: 320)
        // Frame the page as a rounded card inset from the window edges.
        window.contentInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        window.contentCornerRadius = 10
        PopupPresenter.hostPopups(of: window)
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
            if self?.keyBrowser === browser { self?.keyBrowser = nil }
        }
        windows.append(window)
        mirrorTabTitle(of: window)

        // Join the frontmost browser window's tab group.
        let group = NSApp.keyWindow?.tabbingIdentifier == Self.tabbingIdentifier
            ? NSApp.keyWindow : windows.dropLast().last { $0.window?.isVisible == true }?.window
        if let group, let new = window.window {
            group.addTabbedWindow(new, ordered: .above)
            if !inBackground { new.makeKeyAndOrderFront(nil) }
        } else {
            window.show()
        }
        return browser
    }

    /// Opens `url` in the frontmost tab, as Safari's menus do.
    func openInFrontmostTab(_ url: URL) {
        if let current { current.load(url) } else { openTab(url: url) }
    }

    /// The browser of a tab showing `url`, if there is one.
    func tab(showing url: URL) -> CefBrowser? {
        windows.first { $0.browser.url == url }?.browser
    }

    /// Brings the tab showing `url` to the front, if there is one.
    @discardableResult
    func switchToTab(showing url: URL) -> Bool {
        guard let match = windows.first(where: { $0.browser.url == url })?.window else { return false }
        match.makeKeyAndOrderFront(nil)
        return true
    }

    /// Keeps a tab's title in step with its page. Blank pages — a new tab,
    /// a link opened with `window.open()` — are titled "New Tab" rather than
    /// Chromium's "about:blank".
    private func mirrorTabTitle(of window: CefBrowserWindow) {
        guard !window.isClosed else { return }
        let title = withObservationTracking {
            Self.tabTitle(for: window.browser)
        } onChange: { [weak self, weak window] in
            Task { @MainActor in if let window { self?.mirrorTabTitle(of: window) } }
        }
        window.window?.title = title
    }

    static func tabTitle(for browser: CefBrowser) -> String {
        guard let url = browser.url, url.absoluteString != "about:blank" else { return "New Tab" }
        let title = browser.title
        guard !title.isEmpty, title != url.absoluteString else { return url.host() ?? url.absoluteString }
        return title
    }

    /// Trims Chromium's settings to what this browser supports. Its About
    /// entry is replaced by the app's own page; sign-in, sync, "default
    /// browser" and the updater do not exist in an embedded Chromium; and
    /// the Appearance options for Chrome's own toolbar, tab strip, bookmarks
    /// bar and side panel have nothing to act on under the SwiftUI toolbar.
    /// The rules apply inside each settings component's shadow root, so a
    /// selector cannot reach from a component into another's (write
    /// `#themeRow`, not `settings-appearance-page #themeRow`). Rows are
    /// matched by their id or by the preference they edit (`pref-key`),
    /// which are stabler than their position.
    private static let internalPageStyles: [CefUserScript] = [
        .styleSheet(
            """
            /* Sidebar: About (replaced by browser://about), You and Google, Default browser. */
            #about-menu, a[href="/people"], a[href="/syncSetup"], a[href="/defaultBrowser"],
            /* Their pages: Google sign-in and sync; making this the default browser. */
            settings-people-page-index, settings-default-browser-page,
            /* About page leftovers, should it be reached directly. */
            settings-about-page #updateStatusMessage, settings-about-page #relaunch,
            /* Appearance: Chrome themes and toolbar customization. */
            #themeRow, #toolbarRow,
            /* Home button, bookmarks bar, tab position, and their separators. */
            settings-toggle-button[pref-key="browser.show_home_button"],
            div.hr:has(+ settings-toggle-button[pref-key="browser.show_home_button"]),
            div.hr:has(+ .cr-row > #bookmarksBarVisibilityDropdown),
            .cr-row:has(> #bookmarksBarVisibilityDropdown), .cr-row:has(> #tabStripPosition),
            /* Tab strip buttons and tab groups. */
            #showEverythingMenuButton, #showTabSearchButton, #showSavedTabGroups, #autoPinNewTabGroups,
            /* Side panel position: its heading row and its list. */
            .cr-row:has(+ .list-frame #sidePanelPosition), .list-frame:has(#sidePanelPosition),
            /* Tab hover cards and split view belong to Chrome's tab strip. */
            div.hr:has(+ #hoverCardMemoryUsageToggle), #hoverCardMemoryUsageToggle, #splitViewDragAndDrop,
            /* The app turns the ⌘Q warning off at every launch. */
            settings-toggle-button[pref-key="browser.confirm_to_quit"]
            { display: none !important }
            """,
            matching: "chrome://settings/*"),
    ]

    /// Chromium sometimes opens a tab of its own — following a link from
    /// `chrome://settings` to the password manager, for instance. Show those
    /// as tabs here, in the same profile, instead of in Chrome's window.
    func adoptTabsOpenedByChromium() {
        CefRuntime.shared.onOpenBrowser = { [weak self] request in
            // A profile Chromium made itself, such as its own incognito
            // one, stays in Chromium's window.
            guard let self, request.profile != nil else { return .showInChromium }
            self.openTab(
                url: request.url, inBackground: !request.disposition.prefersForeground,
                sharingProfileOf: request.opener ?? request.browser)
            return .close
        }
    }

    /// Puts the frontmost tab's address field into editing.
    func focusAddressBar() {
        guard let window = (windows.first { $0.window?.isKeyWindow == true } ?? windows.last)?.window else { return }
        let field = window.toolbar?.items.lazy.compactMap { $0.view?.firstSubview(of: NSTextField.self) }.first
        window.makeKeyAndOrderFront(nil)
        if let field { window.makeFirstResponder(field) }
    }

    /// Waits until `browser` has loaded its first page.
    func waitUntilLoaded(_ browser: CefBrowser) async {
        try? await browser.ready()
        // The page is created on about:blank and then navigated.
        for _ in 0..<200 where browser.state == .live {
            let location = try? await browser.evaluateJavaScript(
                "document.readyState === 'complete' ? location.href : ''").stringValue
            if let location, !location.isEmpty, location != "about:blank" { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Called whenever a tab's page finishes loading.
    @ObservationIgnored var onPageLoad: ((CefBrowser) -> Void)?

    // MARK: CefBrowserDelegate

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        onPageLoad?(browser)
    }

    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        // Streaming services play in WebKit, which has FairPlay.
        if let url = navigation.url, SystemEngineTab.opensStreamingSitesAutomatically,
           !keptInChromium.contains(ObjectIdentifier(browser)), CefSystemBrowser.prefersSystemEngine(for: url) {
            openSystemTab(url: url, profile: browser.options.profile ?? .default, replacing: browser)
            return .cancel
        }
        // Show this app's pages in place of some of Chromium's.
        guard let replacement = BrowserPages.replacement(for: navigation.url) else { return .allow }
        browser.load(replacement)
        return .cancel
    }

    /// Opens `url` in a WebKit tab beside the frontmost tab, carrying the
    /// Chromium profile's cookies for the site over. With `replacing`, a
    /// Chromium tab that has shown nothing else yet closes, so the WebKit
    /// tab takes its place.
    func openSystemTab(url: URL, profile: CefProfile, replacing source: CefBrowser? = nil) {
        let tab = SystemEngineTab(url: url, profile: profile, controller: self)
        systemTabs.append(tab)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: tab.window, queue: .main
        ) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                tab?.browser.close()
                self?.systemTabs.removeAll { $0 === tab }
            }
        }
        let anchor = NSApp.keyWindow?.tabbingIdentifier == Self.tabbingIdentifier ? NSApp.keyWindow : nil
        if let anchor {
            tab.window.setFrame(anchor.frame, display: false)
            anchor.addTabbedWindow(tab.window, ordered: .above)
        } else {
            tab.window.center()
        }
        tab.window.makeKeyAndOrderFront(nil)
        if let source, !source.canGoBack, let window = windows.first(where: { $0.browser === source }) {
            window.close()
        }
        Task {
            await tab.browser.importCookies(from: profile, for: url)
            tab.browser.load(url)
        }
    }

    /// "Open in Chromium" from a WebKit tab: a Chromium tab that keeps the
    /// page in Chromium even if it is a streaming site.
    func openTabInChromium(url: URL, isPrivate: Bool) {
        // Chromium asks about the first navigation only once the browser
        // exists, after this returns.
        keptInChromium.insert(ObjectIdentifier(openTab(url: url, isPrivate: isPrivate)))
    }

    /// View > Open in WebKit: shows the frontmost Chromium tab's page in a
    /// WebKit tab instead.
    func openCurrentTabInSystemEngine() {
        guard let browser = current, let url = browser.url, url.scheme == "https" || url.scheme == "http",
              let window = windows.first(where: { $0.browser === browser })
        else { return }
        openSystemTab(url: url, profile: browser.options.profile ?? .default)
        window.close()
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        // Real popups (sign-in windows and the like) keep Chromium's handling
        // and arrive through the window's onPopup.
        guard request.disposition != .newPopup, let url = request.targetURL else { return .allowNativePopup }
        openTab(url: url, inBackground: request.disposition == .newBackgroundTab, sharingProfileOf: browser)
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
        let alert = NSAlert()
        alert.messageText = "Allow \(request.origin) to use \(request.kinds.summary)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for this website"
        guard let window = browser.hostWindow else { return .deny }
        let allowed = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        let remembers = alert.suppressionButton?.state == .on
        switch (allowed, remembers) {
        case (true, true): return .alwaysAllow
        case (true, false): return .allow
        case (false, true): return .alwaysDeny
        case (false, false): return .deny
        }
    }
}

/// Shows the popups a page opens (sign-in windows, `window.open` with
/// features) as panels layered over the window that opened them: at the
/// size the page asked for, centered over the page, moving with the window,
/// and closed along with it.
@MainActor
enum PopupPresenter {
    static func hostPopups(of window: CefBrowserWindow) {
        window.onPopup = { [weak window] popup in
            guard let window else { return }
            present(popup, over: window)
        }
    }

    private static func present(_ popup: CefBrowserWindow, over opener: CefBrowserWindow) {
        guard let parent = opener.window, let panel = popup.window else {
            popup.show()
            return
        }
        // Popups of popups are layered the same way.
        hostPopups(of: popup)
        panel.tabbingMode = .disallowed
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let available = parent.contentLayoutRect.size
        let requested = popup.browser.popupFeatures?.size ?? .zero
        let pageSize = CGSize(
            width: min(requested.width > 0 ? requested.width : 520, available.width - 48),
            height: min(requested.height > 0 ? requested.height : 640, available.height - 48))
        var frame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: pageSize))
        let page = parent.convertToScreen(parent.contentLayoutRect)
        frame.origin = CGPoint(x: page.midX - frame.width / 2, y: page.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        parent.addChildWindow(panel, ordered: .above)

        // Closing the opener closes its popups; a closed popup leaves its
        // parent's child windows.
        let closeWithOpener = opener.onClose
        opener.onClose = { [weak popup] in
            closeWithOpener?()
            popup?.close()
        }
        popup.onClose = { [weak parent, weak panel] in
            if let panel { parent?.removeChildWindow(panel) }
        }
        showSite(of: popup)
        popup.show()
    }

    /// Keeps the site a popup shows in its title bar, as browsers must: a
    /// sign-in popup's page could claim to be anyone.
    private static func showSite(of popup: CefBrowserWindow) {
        guard !popup.isClosed else { return }
        let host = withObservationTracking {
            popup.browser.url?.host()
        } onChange: { [weak popup] in
            Task { @MainActor in popup.map(showSite(of:)) }
        }
        popup.window?.subtitle = host ?? ""
    }
}

extension NSView {
    func firstSubview<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

extension CefPermissionKind {
    var summary: String {
        let names: [(CefPermissionKind, String)] = [
            (.camera, "the camera"), (.microphone, "the microphone"), (.geolocation, "your location"),
            (.notifications, "notifications"), (.clipboard, "the clipboard"),
        ]
        let matched = names.filter { contains($0.0) }.map(\.1)
        return matched.isEmpty ? "additional features" : matched.formatted(.list(type: .and))
    }
}
