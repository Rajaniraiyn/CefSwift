import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The browser's windows and tabs.
///
/// Every window is one of Chromium's own tabbed windows (`CefChromeWindow`)
/// and every tab one of Chromium's tabs, so extensions' `chrome.tabs`,
/// tab groups, recently closed tabs and moving tabs between windows behave
/// as in Chrome. Chrome's tab strip and toolbar are covered by the
/// browser's own: a `TabRail` and a toolbar of the features' items
/// (`BrowserWindow`). The controller keeps no list of tabs: it reads them
/// from the profiles' `CefTabStrip`, and is the delegate of every tab's
/// browser, passing the decisions features make on to them.
@MainActor
@Observable
final class BrowserController: CefBrowserDelegate {
    /// The browser's windows, in the order they opened.
    private(set) var windows: [BrowserWindow] = []

    /// The window in front.
    var keyWindow: BrowserWindow? {
        windows.first { $0.chrome.window === keyNSWindow && keyNSWindow != nil } ?? windows.last
    }

    /// The browser of the frontmost window's active tab.
    var current: CefBrowser? { keyWindow?.activeBrowser }

    /// The page of the frontmost tab, whichever engine shows it.
    var frontmostPage: (any TabPage)? {
        otherTabs.first { $0.window?.isKeyWindow == true }?.page ?? current
    }

    /// Every Chromium tab of every window.
    var allTabs: [CefTab] { windows.flatMap(\.chrome.tabs) }

    /// The browser's own start page, when a feature serves one
    /// (`StartPage`). New tabs open with it unless Settings say otherwise.
    var startPage: URL?

    /// Where new tabs open.
    var newTabPage: URL {
        let setting = UserDefaults.standard.string(forKey: Self.newTabPageKey).flatMap { URL(string: $0) }
        return setting ?? startPage ?? URL(string: "about:blank")!
    }

    static let newTabPageKey = "newTabPage"
    static let layoutKey = "tabsAtTheSide"

    /// Whether tabs are down the side of the window rather than across
    /// the top.
    var tabsAtTheSide = UserDefaults.standard.bool(forKey: BrowserController.layoutKey) {
        didSet {
            UserDefaults.standard.set(tabsAtTheSide, forKey: Self.layoutKey)
            applyLayout()
        }
    }

    /// Whether `url` is the start page, which the toolbar shows like a
    /// blank tab.
    func isStartPage(_ url: URL?) -> Bool {
        guard let url, let startPage else { return false }
        return url.scheme == startPage.scheme && url.host() == startPage.host()
    }

    /// Called whenever a tab's page finishes loading.
    @ObservationIgnored var onPageLoad: ((CefBrowser) -> Void)?

    @ObservationIgnored let features: any BrowserFeature

    /// Groups the rail shows collapsed although Chromium's are not:
    /// Chromium collapses groups only for extensions
    /// (`CefTabGroup.setCollapsed` throws), so the rail collapses them in
    /// its own view.
    private(set) var groupsCollapsedHere: Set<CefTabGroup.ID> = []

    /// Whether the rail shows `group` collapsed.
    func isCollapsed(_ group: CefTabGroup) -> Bool {
        group.isCollapsed || groupsCollapsedHere.contains(group.id)
    }

    /// Collapses or expands `group`: Chromium's, if it can, otherwise in
    /// the rail.
    func toggleCollapsed(_ group: CefTabGroup) {
        let collapse = !isCollapsed(group)
        Task {
            // As Chrome does, a group with the shown tab hands it to the
            // nearest tab outside it before collapsing.
            if collapse, group.tabs.contains(where: \.isActive), let window = group.window {
                let outside = window.tabs.filter { $0.group !== group }
                let after = outside.first { $0.index > (group.tabs.last?.index ?? 0) }
                let before = outside.last { $0.index < (group.tabs.first?.index ?? 0) }
                guard let next = after ?? before else { return }
                try? await next.select()
            }
            do {
                try await group.setCollapsed(collapse)
            } catch CefTabStrip.Error.unsupported {
                if collapse { groupsCollapsedHere.insert(group.id) } else { groupsCollapsedHere.remove(group.id) }
            } catch {}
        }
    }

    /// The tab being dragged within the app, if one is.
    @ObservationIgnored var draggedTab: CefTab.Transfer?

    private var keyNSWindow: NSWindow?
    /// The private session's profile, made with the first private window.
    @ObservationIgnored private var privateProfile: CefProfile?
    @ObservationIgnored private var dressedStrips: Set<ObjectIdentifier> = []

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
                guard let self, self.windows.contains(where: { $0.chrome.window === window }) else { return }
                self.keyNSWindow = window
            }
        }
    }

    /// Starts the features, then opens the tabs the launch options ask for.
    func start() {
        features.start(self)
        // Tabs Chromium makes itself (an extension's chrome.tabs.create,
        // a duplicate, a reopened tab) get the browser's decisions too.
        CefRuntime.shared.onBrowserCreated = { [weak self] browser in
            guard let self, browser.delegate == nil else { return }
            browser.delegate = self
        }
        dress(CefProfile.default.tabStrip)
        LaunchOptions().openTabs(in: self)
    }

    // MARK: Windows

    /// Has the browser dress every window of `strip`'s profile, those
    /// Chromium opens itself included.
    private func dress(_ strip: CefTabStrip) {
        guard dressedStrips.insert(ObjectIdentifier(strip)).inserted else { return }
        strip.layout = tabsAtTheSide ? .vertical(width: 232) : .horizontal
        // The rail's sound icons follow Chromium's events while the browser
        // is the active app (one hidden page, CefTabStrip.observesChromiumEvents);
        // in the background, the strip follows CEF's events alone.
        strip.observesChromiumEvents = NSApp.isActive
        for (name, isActive) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak strip] _ in
                MainActor.assumeIsolated { strip?.observesChromiumEvents = isActive }
            }
        }
        strip.onWindowOpened = { [weak self] chrome in
            guard let self, !self.windows.contains(where: { $0.chrome === chrome }) else { return }
            let window = BrowserWindow(chrome: chrome, controller: self)
            self.windows.append(window)
            chrome.onClose = { [weak self, weak window] in
                self?.windows.removeAll { $0 === window }
            }
            self.features.windowDidOpen(chrome)
        }
    }

    private func applyLayout() {
        for strip in [CefProfile.default.tabStrip] + (privateProfile.map { [$0.tabStrip] } ?? []) {
            strip.layout = tabsAtTheSide ? .vertical(width: 232) : .horizontal
        }
    }

    /// The configuration of a tab the browser opens.
    func tabConfiguration(for profile: CefProfile) -> CefBrowser.Configuration {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        configuration.allowsBackForwardNavigationGestures = true
        features.configure(&configuration)
        return configuration
    }

    /// Opens a new window showing `url` (by default the new tab page).
    @discardableResult
    func openWindow(url: URL? = nil, isPrivate: Bool = false) async -> CefChromeWindow? {
        let profile = isPrivate ? privateSession() : .default
        dress(profile.tabStrip)
        var frame: CGRect?
        if let key = keyWindow?.chrome.window?.frame {
            frame = key.offsetBy(dx: 24, dy: -24)
        }
        do {
            return try await CefChromeWindow.open(
                url: url ?? newTabPage, profile: profile, frame: frame,
                configuration: tabConfiguration(for: profile), delegate: self)
        } catch {
            NSLog("Browser: could not open a window: \(error)")
            return nil
        }
    }

    private func privateSession() -> CefProfile {
        if let privateProfile { return privateProfile }
        let made = CefProfile.incognito()
        privateProfile = made
        return made
    }

    // MARK: Tabs

    /// Opens `url` in a new tab of the frontmost window of the right
    /// profile, or of a new window.
    ///
    /// - Parameters:
    ///   - isPrivate: Open it in the private session.
    ///   - inBackground: Leave the current tab in front.
    ///   - source: The browser the tab is opened from: the tab shares its
    ///     profile and opens right after it.
    func openTab(url: URL? = nil, isPrivate: Bool = false, inBackground: Bool = false, sharingProfileOf source: CefBrowser? = nil) {
        Task { await openTabNow(url: url, isPrivate: isPrivate, inBackground: inBackground, sharingProfileOf: source) }
    }

    @discardableResult
    func openTabNow(
        url: URL? = nil, isPrivate: Bool = false, inBackground: Bool = false, sharingProfileOf source: CefBrowser? = nil
    ) async -> CefTab? {
        let profile = source?.configuration.profile ?? (isPrivate ? privateSession() : .default)
        let sourceTab = source.flatMap { profile.tabStrip.tab(for: $0) }
        let target = sourceTab?.window
            ?? (keyWindow?.chrome.profile === profile ? keyWindow?.chrome : nil)
            ?? windows.last { $0.chrome.profile === profile }?.chrome
        guard let target else {
            return await openWindow(url: url, isPrivate: profile.isIncognito)?.tabs.first
        }
        return await openTab(url: url, in: target, at: sourceTab.map { $0.index + 1 }, isActive: !inBackground)
    }

    /// The New Tab button: a tab at the end of `window`.
    func openTab(in window: CefChromeWindow, at index: Int? = nil, inGroup group: CefTabGroup? = nil) {
        Task {
            let tab = await openTab(url: nil, in: window, at: index, isActive: true)
            if let tab, let group { try? await group.add([tab]) }
        }
    }

    @discardableResult
    private func openTab(url: URL?, in window: CefChromeWindow, at index: Int?, isActive: Bool) async -> CefTab? {
        do {
            return try await window.openTab(
                url ?? newTabPage, at: index, isActive: isActive,
                configuration: tabConfiguration(for: window.profile), delegate: self)
        } catch {
            NSLog("Browser: could not open a tab: \(error)")
            return nil
        }
    }

    /// Shows a window that is not one of Chromium's: a page another engine
    /// shows (`WebKitTabs`). It is a window of its own beside the
    /// frontmost one — WebKit pages are not Chromium tabs, so the rail does
    /// not list them — and the menus that navigate reach `page` while it
    /// is key.
    func showTab(_ window: NSWindow, page: any TabPage) {
        otherTabs.append(OtherTab(window: window, page: page))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated { self?.otherTabs.removeAll { $0.window == nil || $0.window === window } }
        }
        window.tabbingMode = .disallowed
        if let frame = keyWindow?.chrome.window?.frame {
            window.setFrame(frame.offsetBy(dx: 24, dy: -24), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The tab showing `browser`.
    func tab(of browser: CefBrowser) -> CefTab? {
        (browser.configuration.profile ?? .default).tabStrip.tab(for: browser)
    }

    /// Opens `url` in the frontmost tab, as Safari's menus do.
    func openInFrontmostTab(_ url: URL) {
        if let current { current.load(url) } else { openTab(url: url) }
    }

    /// The browser of a tab showing `url`, if there is one.
    func tab(showing url: URL) -> CefBrowser? {
        allTabs.first { $0.url == url }?.browser
    }

    /// Brings the tab showing `url` to the front, if there is one.
    @discardableResult
    func switchToTab(showing url: URL) -> Bool {
        guard let match = allTabs.first(where: { $0.url == url }) else { return false }
        Task { try? await match.select() }
        return true
    }

    /// Puts the frontmost window's address field into editing.
    func focusAddressBar() {
        guard let window = keyWindow?.chrome, let nsWindow = window.window else { return }
        nsWindow.makeKeyAndOrderFront(nil)
        if let field = window.topBar?.firstSubview(of: NSTextField.self) { nsWindow.makeFirstResponder(field) }
    }

    // MARK: Commands from the rail and the menus

    /// A click on a tab: selects it; ⌘ adds it to the selection, ⇧ selects
    /// the run from the active tab to it.
    func click(_ tab: CefTab, modifiers: NSEvent.ModifierFlags) {
        guard let window = tab.window else { return }
        Task {
            if modifiers.contains(.command) {
                var selected = window.selectedTabs
                if let index = selected.firstIndex(where: { $0 === tab }) { selected.remove(at: index) } else { selected.append(tab) }
                let active = selected.first { $0.isActive } ?? selected.first
                if let active { try? await window.strip.select([active] + selected.filter { $0 !== active }) }
            } else if modifiers.contains(.shift), let active = window.activeTab {
                let range = min(active.index, tab.index)...max(active.index, tab.index)
                try? await window.strip.select([active] + window.tabs.filter { range.contains($0.index) && $0 !== active })
            } else {
                try? await tab.select()
            }
        }
    }

    /// The tabs a menu command on `tab` applies to: the selection, when
    /// `tab` is part of it.
    func targets(of tab: CefTab) -> [CefTab] {
        guard tab.isSelected, let selected = tab.window?.selectedTabs, selected.count > 1 else { return [tab] }
        return selected
    }

    /// Selects the tab `selection` picks in the frontmost window.
    func select(_ selection: TabRailLogic.Selection) {
        guard let window = keyWindow?.chrome else { return }
        let visible = window.tabs.filter { !($0.group.map(isCollapsed) ?? false) || $0.isActive }
        guard let index = TabRailLogic.index(for: selection, active: visible.firstIndex { $0.isActive }, count: visible.count)
        else { return }
        Task { try? await visible[index].select() }
    }

    /// Lands a dropped tab at `target` in `window`: a move within the
    /// window or from another of the profile's, or, from another profile,
    /// the page opened here and the tab closed there.
    func land(_ transfer: CefTab.Transfer, at target: TabRailLogic.DropTarget, in window: CefChromeWindow) async {
        let strip = window.strip
        if let tab = transfer.tab(in: strip) {
            let source = tab.window === window ? tab.index : nil
            let index = target.finalIndex(movingFrom: source)
            do {
                if tab.isPinned != target.isPinned { try await tab.pin(target.isPinned) }
                if tab.window !== window || tab.index != index { try await tab.move(to: index, in: window) }
                if let groupID = target.group, let group = window.groups.first(where: { $0.id.rawValue == groupID }) {
                    if tab.group !== group { try await group.add([tab]) }
                } else if tab.group != nil, !target.isPinned {
                    try await strip.ungroup([tab])
                }
            } catch {
                NSLog("Browser: could not move the tab: \(error)")
            }
        } else if let other = windows.lazy.compactMap({ $0.chrome.strip.tab(transfer.id) }).first, let url = other.url {
            await moveToProfile(other, url: url, window: window, index: target.insertionIndex)
        }
    }

    /// Moves a tab to another profile's window: Chromium cannot move a tab
    /// between profiles, so the page opens there, from its address, and
    /// the tab closes here. Its history and state stay behind.
    func moveToProfile(_ tab: CefTab, url: URL, window: CefChromeWindow, index: Int? = nil) async {
        if await openTab(url: url, in: window, at: index, isActive: true) != nil { tab.close() }
    }

    // MARK: Dragging tabs out

    @ObservationIgnored private var dragSource: TabDragSource?

    /// Starts an AppKit drag of `tab` from the current mouse event: onto
    /// any window's rail, into Finder as its address, or out of every
    /// window into a new one.
    func beginDrag(of tab: CefTab) {
        guard dragSource == nil, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              let nsWindow = event.window, let view = nsWindow.contentView?.superview?.hitTest(event.locationInWindow)
        else { return }
        let source = TabDragSource(tab: tab, controller: self)
        dragSource = source
        draggedTab = CefTab.Transfer(tab)
        let item = NSDraggingItem(pasteboardWriter: tab.pasteboardItem)
        let image = TabDragImage.make(for: tab)
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - 20, y: point.y - image.size.height / 2, width: image.size.width, height: image.size.height),
                              contents: image)
        view.beginDraggingSession(with: [item], event: event, source: source)
    }

    func dragEnded(_ tab: CefTab, at screenPoint: CGPoint, accepted: Bool) {
        dragSource = nil
        defer { draggedTab = nil }
        guard !accepted, draggedTab != nil else { return }
        // Dropped outside every rail: over another of the profile's
        // windows, into it; elsewhere, into a window of its own there.
        let over = windows.first { $0.chrome.window?.frame.contains(screenPoint) == true && $0.chrome.profile === tab.window?.profile }
        Task {
            if let over, over.chrome !== tab.window {
                try? await tab.move(to: -1, in: over.chrome)
                try? await tab.select()
            } else if over == nil, (tab.window?.tabs.count ?? 0) > 1 {
                guard let made = try? await tab.moveToNewWindow() else { return }
                for _ in 0..<50 where made.window == nil { try? await Task.sleep(for: .milliseconds(20)) }
                if let nsWindow = made.window {
                    nsWindow.setFrameTopLeftPoint(CGPoint(x: screenPoint.x - 120, y: screenPoint.y + 20))
                }
            }
        }
    }

    // MARK: Putting windows together

    /// The features' views for one place in a tab's toolbar.
    func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        func items(of features: some BrowserFeature) -> AnyView { AnyView(features.toolbarItems(placement, for: browser)) }
        return items(of: features).environment(self)
    }

    /// The features' views over a tab's page.
    func pageOverlay(for browser: CefBrowser) -> some View {
        func overlay(of features: some BrowserFeature) -> AnyView { AnyView(features.pageOverlay(for: browser)) }
        return overlay(of: features).environment(self)
    }

    // MARK: CefBrowserDelegate

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        onPageLoad?(browser)
    }

    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        features.decidePolicy(for: navigation, in: browser) ?? .allow
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
        // Popups (sign-in windows and the like) are Chromium's own popup
        // windows, which show the site's address.
        guard request.disposition != .newPopup, let url = request.targetURL else { return .allowNativePopup }
        // Open Link in Incognito Window opens a private tab.
        let isPrivate = request.disposition == .offTheRecord
        openTab(url: url, isPrivate: isPrivate, inBackground: request.disposition == .newBackgroundTab,
                sharingProfileOf: isPrivate ? nil : browser)
        return .handled
    }

    func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        switch command {
        case .newTab:
            if let window = tab(of: browser)?.window { openTab(in: window) } else { openTab() }
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

/// The AppKit side of dragging a tab: where the drag ended, and whether a
/// rail took it.
@MainActor
final class TabDragSource: NSObject, NSDraggingSource {
    let tab: CefTab
    weak var controller: BrowserController?

    init(tab: CefTab, controller: BrowserController) {
        self.tab = tab
        self.controller = controller
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            controller?.dragEnded(tab, at: screenPoint, accepted: !operation.isEmpty)
        }
    }
}

/// The image a dragged tab shows under the pointer.
@MainActor
enum TabDragImage {
    static func make(for tab: CefTab) -> NSImage {
        let renderer = ImageRenderer(content: HStack(spacing: 6) {
            if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe").frame(width: 16, height: 16)
            }
            Text(tab.displayTitle).font(.system(size: 12)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 30, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8)))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: CGSize(width: 200, height: 30))
    }
}
