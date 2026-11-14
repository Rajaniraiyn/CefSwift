import AppKit
import CefKit
import Foundation
import Observation

/// Chromium's own tabs, windows and tab groups for one ``CefProfile``:
/// the profile's ``CefChromeWindow``s, mirrored and driven through
/// Chromium.
///
/// It is the model a custom tab interface draws: Chromium stays the source
/// of truth, so what Chrome's own commands and shortcuts do, and what
/// extensions do with `chrome.tabs`, shows up here, and every change made
/// here is one Chromium makes — moving a tab to another window keeps its
/// page, history and ``CefBrowser``.
///
/// ```swift
/// let strip = CefProfile.default.tabStrip
/// for window in strip.windows {
///     for tab in window.tabs { print(tab.title, tab.isPinned, tab.group?.title ?? "-") }
/// }
/// try await strip.group([first, second])
/// try await first.move(to: 0, in: otherWindow)
/// ```
///
/// ## Following Chromium
///
/// The strip follows the events CEF and AppKit already deliver for every
/// tab — a browser created or closed, a page's title, address, icon and
/// loading, the page a window shows, every Chrome command — and reads
/// Chromium's tab model only when one of them reports a change to its
/// structure: a new tab or window, a tab command (⌘⇧T, ⌃Tab, moving and
/// pinning), or a change made through the strip. Each read is one call to
/// a hidden service host — `chrome.tabs` and `chrome.windows` on Chromium's
/// own `chrome://bookmarks` page, which Chromium grants those extension
/// APIs, and, for groups' names and colours and what Chromium can reopen,
/// `tab_strip_internals.mojom` (`chrome://tab-strip-internals`) — which
/// closes a few seconds after the last one. While nothing changes, no host
/// runs.
///
/// What CEF does not report — sound starting or stopping in a tab, and an
/// extension moving, pinning or grouping tabs — shows at the next read, or
/// at once while ``observesChromiumEvents`` is on.
///
/// Windows CefKit hosts (``CefWindow``, one tab each, which Chromium
/// counts as popup windows) and Chromium's popup windows are left out.
///
/// ## Tabs and browsers
///
/// Each tab is matched with the ``CefBrowser`` showing it exactly, never
/// by a guess: a tab the app opens is known from its creation; otherwise
/// a window's active tab is the browser whose page is in that window, and
/// a tab in the background is the one browser with its address. When
/// several background tabs share an address, CefChromium mutes one of
/// their browsers for a moment through CEF and asks Chromium which tab
/// became muted (`chrome.tabs`' `mutedInfo`); a tab playing sound is never
/// used for that while another can be. A match, once made, lasts as long
/// as the tab.
@MainActor
@Observable
public final class CefTabStrip {
    /// Why a command failed.
    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// The tab, group or window closed before the command ran.
        case tabClosed
        /// The tab has no browser CefChromium knows of yet.
        case noBrowser
        /// Chromium refused the change, with its message.
        case chromium(String)
        /// Chromium offers no way to make this change from outside an
        /// extension, or the way CefChromium uses changed in this version.
        case unsupported(String)

        public var description: String {
            switch self {
            case .tabClosed: "The tab is no longer open."
            case .noBrowser: "The tab's browser is not known yet."
            case .chromium(let message): message
            case .unsupported(let message): message
            }
        }
    }

    /// A tab, window or group Chromium can reopen (Chromium's
    /// `TabRestoreService` entries), newest first.
    public struct ClosedItem: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable { case tab, window, group, other }
        /// Chromium's identifier for the entry, for
        /// ``CefTabStrip/reopen(_:)``. It is valid while the entry is listed.
        public var id: Int
        public var kind: Kind
        /// The tab's title; for a window or group, its active or first
        /// tab's, or the group's name.
        public var title: String
        public var url: URL?
        /// How many tabs reopening it brings back.
        public var tabCount: Int
        /// When it closed.
        public var closedAt: Date?
        /// For a tab, the window it was in (which may have closed since)
        /// and its place there: where ``CefTabStrip/reopen(_:)`` puts it back.
        public var windowID: CefChromeWindow.ID?
        public var index: Int?

        public init(id: Int, kind: Kind, title: String, url: URL?, tabCount: Int = 1, closedAt: Date? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.url = url
            self.tabCount = tabCount
            self.closedAt = closedAt
        }
    }

    /// The profile's tabbed windows, in the order Chromium lists them.
    /// A window a new tab starts in on its way to another
    /// (``CefChromeWindow/openTab(_:at:isActive:configuration:delegate:)``)
    /// is not listed.
    public var windows: [CefChromeWindow] { allWindows.filter { !$0.isTransient } }

    /// Every window, transient ones included.
    private(set) var allWindows: [CefChromeWindow] = []

    /// What Chromium can reopen, newest first: tabs, windows and groups
    /// closed in this session, as of the last read of them. Closing tabs
    /// does not read them by itself; ``refreshRecentlyClosed()`` does,
    /// before a menu of them opens.
    public private(set) var recentlyClosed: [ClosedItem] = []

    /// Why the last read failed — an internal page moved or changed in a
    /// Chromium update — or `nil`.
    public private(set) var lastError: String?

    /// What the previous run of the app left for this profile — how it
    /// ended and the windows it had open — until
    /// ``restorePreviousSession(configuration:delegate:)`` or
    /// ``discardPreviousSession()``; `nil` on a first launch, for an
    /// incognito profile, and when the previous run closed every window
    /// before quitting. CefChromium saves the profile's windows (their
    /// tabs' addresses, a small file in the profile's directory) as they
    /// change, and marks a quit; Chromium restores nothing by itself in
    /// CEF.
    public internal(set) var previousSession: PreviousSession?
    @ObservationIgnored var isSavingSoon = false

    /// Called once for each window as soon as its `NSWindow` is known:
    /// the windows the app opens and those Chromium opens itself (a tab
    /// dragged out, `chrome.windows.create` from an extension, a window
    /// reopened or restored). Dress the window here: hide Chrome's tab
    /// strip and toolbar, give it a top bar.
    @ObservationIgnored public var onWindowOpened: ((CefChromeWindow) -> Void)?

    /// Whether the strip also listens to Chromium's own tab events, so that
    /// what CEF does not report shows at once: sound starting and stopping
    /// in any tab, and an extension moving, pinning or grouping tabs.
    ///
    /// Off by default, and then no service host runs while nothing changes.
    /// On, one hidden host stays open meanwhile (the `chrome://bookmarks`
    /// page, one renderer process, about 30 MB), listening to
    /// `chrome.tabs`' events and `chrome.windows`' `onCreated` and
    /// `onRemoved`. (Not `chrome.windows.onFocusChanged`: with a listener
    /// to it on a WebUI page, CEF 156 crashes when an incognito window
    /// opens.)
    public var observesChromiumEvents = false {
        didSet {
            guard observesChromiumEvents != oldValue else { return }
            updateListening()
        }
    }

    public let profile: CefProfile

    init(profile: CefProfile) {
        self.profile = profile
    }

    // MARK: Looking up

    /// The tab with `id`, in any window.
    public func tab(_ id: CefTab.ID) -> CefTab? { tabsByID[id] }

    /// The window with `id`.
    public func window(_ id: CefChromeWindow.ID) -> CefChromeWindow? {
        allWindows.first { $0.id == id }
    }

    /// The tab `browser` shows, if it is one of the profile's Chromium tabs.
    public func tab(for browser: CefBrowser) -> CefTab? {
        tabIDsByBrowser[ObjectIdentifier(browser)].flatMap { tabsByID[$0] }
    }

    /// The window shown in `nsWindow`.
    public func window(for nsWindow: NSWindow) -> CefChromeWindow? {
        allWindows.first { $0.window === nsWindow }
    }

    @ObservationIgnored private var tabsByID: [CefTab.ID: CefTab] = [:]
    @ObservationIgnored private var groupsByID: [CefTabGroup.ID: CefTabGroup] = [:]
    @ObservationIgnored private var tabIDsByBrowser: [ObjectIdentifier: CefTab.ID] = [:]

    // MARK: Following

    @ObservationIgnored private var tabsSnapshot: TabsSnapshot?
    @ObservationIgnored private var internalsSnapshot: InternalsSnapshot?
    /// Group names and colours by group, as last read from the internal
    /// page: kept while a read of it does not line up with `chrome.tabs`.
    @ObservationIgnored private var visuals: [CefTabGroup.ID: InternalsSnapshot.Group] = [:]

    /// Reads asked for, and the reads done: a caller waiting for a read
    /// waits for the count it asked to be done.
    @ObservationIgnored private var readsRequested = 0
    @ObservationIgnored private var readsDone = 0
    @ObservationIgnored private var readWaiters: [(request: Int, continuation: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Whether the next read also reads the internal page: for groups'
    /// names and colours, and what Chromium can reopen.
    @ObservationIgnored private var readsInternalsNext = false
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var isObservingEvents = false
    @ObservationIgnored private var browserIDs = Set<ObjectIdentifier>()

    /// How long a service host the strip used stays open after its last
    /// call: reads come in bursts (a tab opening reads two or three times),
    /// and nothing is kept on the host between them.
    static let hostIdle: Duration = .seconds(3)

    /// Starts following CEF's and AppKit's events for the profile's tabs,
    /// once, and reads Chromium's tabs.
    func startFollowing() {
        guard CefRuntime.shared.isRunning, !CefRuntime.shared.isTerminating else { return }
        if !isObservingEvents {
            isObservingEvents = true
            Self.installCommandObserver()
            followBrowsers()
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    // One of Chromium's windows the strip does not know yet.
                    guard let self, let window, CefWindow.owning(window) == nil, self.window(for: window) == nil,
                          "\(type(of: window.contentView ?? NSView()))" == "BridgedContentView"
                    else { return }
                    self.setNeedsRead()
                }
            }
            setNeedsRead(internals: true)
            loadPreviousSession()
            followSessionChanges()
        }
        updateListening()
    }

    /// Whether the strip should go on reading.
    private var isLive: Bool {
        CefRuntime.shared.isRunning && !CefRuntime.shared.isTerminating
    }

    /// Asks for a read of Chromium's tabs, soon; reads asked for together
    /// are one.
    func setNeedsRead(internals: Bool = false) {
        readsRequested += 1
        if internals { readsInternalsNext = true }
        guard reading == nil else { return }
        reading = Task { [weak self] in
            await self?.readWhileRequested()
        }
    }

    private func readWhileRequested() async {
        while readsDone < readsRequested, isLive {
            // Events come together (a tab opening sends several): read once
            // they have.
            try? await Task.sleep(for: .milliseconds(16))
            let request = readsRequested
            let withInternals = readsInternalsNext || (!groupsByID.isEmpty && readsDone == 0)
            readsInternalsNext = false
            await readOnce(withInternals: withInternals)
            readsDone = request
            let ready = readWaiters.filter { $0.request <= request }
            readWaiters.removeAll { $0.request <= request }
            ready.forEach { $0.continuation.resume() }
        }
        reading = nil
        if !isLive {
            readsDone = readsRequested
            let waiting = readWaiters
            readWaiters = []
            waiting.forEach { $0.continuation.resume() }
        }
    }

    private func readOnce(withInternals: Bool) async {
        do {
            let next = try await services.call(
                Self.tabsModule, "s => s.read()", as: TabsSnapshot.self, timeout: .seconds(15), isIdempotent: true,
                keepsHostFor: Self.hostIdle)
            tabsSnapshot = next
            lastError = nil
        } catch {
            guard isLive else { return }
            lastError = "chrome.tabs: \(error)"
            return
        }
        let groupsBefore = Set(groupsByID.keys)
        rebuild()
        // A new group: read its name and colour from the internal page too.
        if withInternals || !Set(groupsByID.keys).subtracting(groupsBefore).isEmpty {
            await readInternals()
            rebuild()
        }
        await bindBrowsers()
    }

    private func readInternals() async {
        do {
            internalsSnapshot = try await internalsServices.call(
                Self.internalsModule, "s => s.read()", as: InternalsSnapshot.self, timeout: .seconds(15),
                isIdempotent: true, keepsHostFor: Self.hostIdle)
            updateRecentlyClosed()
        } catch {
            guard isLive else { return }
            lastError = "tab-strip-internals: \(error)"
        }
    }

    private var services: CefServiceHosts { profile.serviceHosts }
    /// The internal page is not built for incognito profiles; the default
    /// profile's lists every window.
    private var internalsServices: CefServiceHosts {
        profile.isIncognito ? CefProfile.default.serviceHosts : profile.serviceHosts
    }

    /// Asks Chromium's tabs to be read again, and returns when the strip
    /// shows a read made after this call: everything Chromium had done
    /// before it is then in the strip.
    func nextRead(internals: Bool = false) async {
        startFollowing()
        guard isLive else { return }
        setNeedsRead(internals: internals)
        let request = readsRequested
        await withCheckedContinuation { readWaiters.append((request, $0)) }
    }

    /// Reads again soon: after a change Chromium may not report, such as a
    /// tab muted through CEF.
    func scheduleRead() {
        setNeedsRead()
    }

    /// Reads Chromium's tabs once more, with groups' names and colours and
    /// what Chromium can reopen, and returns when the strip shows them.
    public func refresh() async {
        await nextRead(internals: true)
    }

    /// Reads what Chromium can reopen into ``recentlyClosed``, and returns
    /// it. Call it as a menu of recently closed tabs opens.
    @discardableResult
    public func refreshRecentlyClosed() async -> [ClosedItem] {
        startFollowing()
        await readInternals()
        return recentlyClosed
    }

    // MARK: Events

    /// Follows the runtime's browsers: a new Chrome-style browser of the
    /// profile is a new tab (or window) to read; a closed one, a tab gone.
    private func followBrowsers() {
        let browsers = withObservationTracking {
            CefRuntime.shared.browsers
        } onChange: { [weak self] in
            Task { @MainActor in self?.followBrowsers() }
        }
        let current = Set(browsers.map(ObjectIdentifier.init))
        let added = browsers.filter { !browserIDs.contains(ObjectIdentifier($0)) }
        let removed = browserIDs.subtracting(current)
        browserIDs = current
        let candidates = added.filter(isCandidate)
        if !candidates.isEmpty { setNeedsRead() }
        candidates.forEach(matchWhenCommitted)
        var closedTabs = false
        for id in removed {
            if let tabID = tabIDsByBrowser[id], let tab = tabsByID[tabID] {
                removeLocally(tab)
                closedTabs = true
            }
        }
        // Chromium can reopen what closed: read its list once the closing
        // is over.
        if closedTabs, !isReadingClosedSoon {
            isReadingClosedSoon = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.isReadingClosedSoon = false
                await self?.readInternals()
            }
        }
    }

    @ObservationIgnored private var isReadingClosedSoon = false

    /// Matches a new browser with its tab once its page has an address
    /// (and so can be told from the window's other browsers), if it is not
    /// matched by then.
    private func matchWhenCommitted(_ browser: CefBrowser) {
        guard browser.state != .closed, tabIDsByBrowser[ObjectIdentifier(browser)] == nil else { return }
        let url = withObservationTracking {
            browser.url
        } onChange: { [weak self, weak browser] in
            Task { @MainActor in
                guard let self, let browser else { return }
                if self.tabIDsByBrowser[ObjectIdentifier(browser)] == nil { await self.bindBrowsers() }
                self.matchWhenCommitted(browser)
            }
        }
        _ = url
    }

    /// Whether `browser` can be one of the profile's Chromium tabs.
    private func isCandidate(_ browser: CefBrowser) -> Bool {
        browser.isChromeStyle && CefWindow.hosting(browser) == nil
            && (browser.configuration.profile ?? .default) === profile
    }

    /// A tab's browser closed: the tab is gone from Chromium's strip. It
    /// leaves the mirror at once; a later read confirms it.
    private func removeLocally(_ tab: CefTab) {
        guard let window = tab.window else { return }
        let remaining = window.tabs.filter { $0 !== tab }
        if let browser = tab.browser { tabIDsByBrowser[ObjectIdentifier(browser)] = nil }
        tabsByID[tab.id] = nil
        knownBindings[tab.id] = nil
        tab.browser = nil
        tab.window = nil
        if let group = tab.group {
            group.tabs.removeAll { $0 === tab }
            if group.tabs.isEmpty {
                groupsByID[group.id] = nil
                group.window = nil
            }
        }
        tab.group = nil
        for (index, other) in remaining.enumerated() where other.index != index { other.index = index }
        if remaining.isEmpty {
            allWindows.removeAll { $0 === window }
            window.didClose()
        } else {
            window.update(tabs: remaining, groups: window.groups.filter { !$0.tabs.isEmpty },
                          isFocused: window.isFocused, bounds: nil, state: nil)
        }
    }

    /// The page `window` shows changed (Chromium switched tabs: a
    /// shortcut, a closed tab's neighbour, a command): its tab becomes the
    /// active one, at once when its browser is known.
    func windowDidShowPage(_ page: NSView, in window: CefChromeWindow) {
        // Chromium adds a new background tab's page shown for a moment
        // before hiding it: look again once it has.
        DispatchQueue.main.async { [weak self, weak page, weak window] in
            MainActor.assumeIsolated {
                guard let self, let page, let window, !page.isHiddenOrHasHiddenAncestor,
                      let content = window.window?.contentView, ChromeWindowHost.page(in: content) === page
                else { return }
                self.activate(page, in: window)
            }
        }
    }

    private func activate(_ page: NSView, in window: CefChromeWindow) {
        guard let shown = window.tabs.first(where: { tab in
            guard let view = tab.browser?.nativeView else { return false }
            return view === page || view.isDescendant(of: page)
        }) else {
            if !window.tabs.isEmpty { setNeedsRead() }
            return
        }
        guard !shown.isActive else { return }
        for tab in window.tabs where tab !== shown {
            if tab.isActive { tab.isActive = false }
            if tab.isSelected { tab.isSelected = false }
        }
        shown.isActive = true
        shown.isSelected = true
        window.surfaceController?.shownBrowserDidChange()
    }

    /// Reads after Chrome commands that change tabs and windows, from any
    /// of the runtime's Chromium windows: Chromium runs them after the
    /// observer returns.
    private static func installCommandObserver() {
        guard !isObservingCommands else { return }
        isObservingCommands = true
        CefBrowser.addChromeCommandInterceptor { browser, command in
            // IDC_* window and tab commands (chrome_command_ids.h, 34000–34999).
            guard (34_000..<35_000).contains(command.rawValue) else { return false }
            let profile = browser.configuration.profile ?? .default
            if let strip = profile.chromiumStores.tabStrip {
                DispatchQueue.main.async { MainActor.assumeIsolated { strip.setNeedsRead(internals: command == .restoreTab) } }
            }
            return false
        }
    }

    private static var isObservingCommands = false

    /// Listens to Chromium's tab events while ``observesChromiumEvents``
    /// is on and the profile has windows; each wakes a read.
    private func updateListening() {
        let wanted = observesChromiumEvents && isLive && isObservingEvents
        if !wanted {
            listening?.cancel()
            listening = nil
            return
        }
        guard listening == nil else { return }
        // What changed while the strip was not listening.
        setNeedsRead()
        listening = Task { [weak self] in
            var version: Int?
            while !Task.isCancelled, let self, self.isLive, self.observesChromiumEvents {
                do {
                    var arguments: [String: CefJSON] = [:]
                    if let version { arguments["since"] = .number(Double(version)) }
                    let next = try await self.services.call(
                        Self.tabsModule, "(s, a, c) => s.wait(a.since, c.signal)", .object(arguments),
                        as: Int.self, timeout: .seconds(3600), isIdempotent: true, keepsHostFor: Self.hostIdle)
                    if version != nil, next != version { self.setNeedsRead() }
                    version = next
                } catch {
                    guard !Task.isCancelled, self.isLive else { break }
                    self.lastError = "chrome.tabs events: \(error)"
                    version = nil
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    // MARK: Building the model

    private func rebuild() {
        guard let tabsSnapshot else { return }
        let profileIsIncognito = profile.isIncognito
        let listed = tabsSnapshot.windows.filter { $0.incognito == profileIsIncognito }
        let internalWindows = Dictionary(
            (internalsSnapshot?.windows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var seenTabs = Set<CefTab.ID>()
        var seenGroups = Set<CefTabGroup.ID>()
        var nextWindows: [CefChromeWindow] = []
        for listedWindow in listed {
            let windowID = CefChromeWindow.ID(rawValue: listedWindow.id)
            let window = self.window(windowID) ?? pendingWindows.first { $0.id == windowID } ?? {
                let made = CefChromeWindow(id: windowID, strip: self)
                // A new window of one tab while the app is opening a tab
                // in a window of its own.
                made.isTransient = !transientBrowsers.isEmpty && listedWindow.tabs.count == 1
                return made
            }()
            pendingWindows.removeAll { $0 === window }
            if window.isTransient, !listedWindow.tabs.isEmpty, transientBrowsers.isEmpty
                || listedWindow.tabs.count > 1
                || tabsByID[CefTab.ID(rawValue: listedWindow.tabs[0].id)]?.browser.map({ !transientBrowsers.contains(ObjectIdentifier($0)) }) == true {
                window.isTransient = false
                window.announceIfNeeded()
            }
            // Group names and colours, where the internal page lines up
            // with chrome.tabs.
            if let internalWindow = internalWindows[String(listedWindow.id)], internalWindow.tabs.count == listedWindow.tabs.count,
               zip(internalWindow.tabs, listedWindow.tabs).allSatisfy({ $0.url.isEmpty || $1.url.isEmpty || $0.url == $1.url }) {
                let internalGroups = Dictionary(internalWindow.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (internalTab, tab) in zip(internalWindow.tabs, listedWindow.tabs) where tab.group >= 0 {
                    if let groupID = internalTab.group, let visual = internalGroups[groupID] {
                        visuals[CefTabGroup.ID(rawValue: tab.group)] = visual
                    }
                }
            }
            var tabs: [CefTab] = []
            var groups: [CefTabGroup] = []
            for listedTab in listedWindow.tabs.sorted(by: { $0.index < $1.index }) {
                let tabID = CefTab.ID(rawValue: listedTab.id)
                seenTabs.insert(tabID)
                let tab = tabsByID[tabID] ?? CefTab(id: tabID, strip: self)
                tabsByID[tabID] = tab
                update(tab, from: listedTab, in: window, internalWindow: internalWindows[String(listedWindow.id)])
                var group: CefTabGroup?
                if listedTab.group >= 0 {
                    let groupID = CefTabGroup.ID(rawValue: listedTab.group)
                    seenGroups.insert(groupID)
                    let made = groupsByID[groupID] ?? CefTabGroup(id: groupID, strip: self)
                    groupsByID[groupID] = made
                    if !groups.contains(where: { $0 === made }) {
                        groups.append(made)
                        made.pendingTabs = []
                    }
                    made.pendingTabs.append(tab)
                    group = made
                }
                if tab.group !== group { tab.group = group }
                tabs.append(tab)
            }
            for group in groups {
                if group.window !== window { group.window = window }
                if group.tabs.map(\.id) != group.pendingTabs.map(\.id) { group.tabs = group.pendingTabs }
                if let visual = visuals[group.id] {
                    if group.title != visual.title { group.title = visual.title }
                    let color = CefTabGroup.Color(rawValue: visual.color) ?? .grey
                    if group.color != color { group.color = color }
                    if group.isCollapsed != visual.collapsed { group.isCollapsed = visual.collapsed }
                }
            }
            window.update(tabs: tabs, groups: groups, isFocused: listedWindow.focused,
                          bounds: listedWindow.bounds, state: listedWindow.state)
            nextWindows.append(window)
        }
        // What went away.
        for (id, tab) in tabsByID where !seenTabs.contains(id) {
            tabsByID[id] = nil
            if let browser = tab.browser { tabIDsByBrowser[ObjectIdentifier(browser)] = nil }
            tab.browser = nil
            tab.window = nil
            tab.group = nil
        }
        for (id, group) in groupsByID where !seenGroups.contains(id) {
            groupsByID[id] = nil
            group.tabs = []
            group.window = nil
        }
        let closedWindows = allWindows.filter { window in !nextWindows.contains { $0 === window } }
        if nextWindows.map(ObjectIdentifier.init) != allWindows.map(ObjectIdentifier.init) { allWindows = nextWindows }
        for window in closedWindows { window.didClose() }
    }

    private func updateRecentlyClosed() {
        let closed = (internalsSnapshot?.closed ?? []).compactMap { item -> ClosedItem? in
            let url = URL(string: item.url)
            // A hidden service host's page, closed as the app quit.
            if let url, CefServiceHosts.isServicePage(url) { return nil }
            var made = ClosedItem(id: item.id, kind: item.itemKind, title: item.title, url: url,
                                  tabCount: max(item.tabs, item.itemKind == .tab ? 1 : 0),
                                  closedAt: item.time > 0 ? Date(timeIntervalSince1970: item.time / 1_000_000 - 11_644_473_600) : nil)
            if item.itemKind == .tab {
                made.windowID = item.window >= 0 ? CefChromeWindow.ID(rawValue: item.window) : nil
                made.index = item.index >= 0 ? item.index : nil
            }
            return made
        }
        if closed != recentlyClosed { recentlyClosed = closed }
    }

    private func update(_ tab: CefTab, from listed: TabsSnapshot.Tab, in window: CefChromeWindow,
                        internalWindow: InternalsSnapshot.Window?) {
        if tab.window !== window { tab.window = window }
        if tab.index != listed.index { tab.index = listed.index }
        if tab.reportedTitle != listed.title { tab.reportedTitle = listed.title }
        let url = URL(string: listed.url)
        if tab.reportedURL != url { tab.reportedURL = url }
        if tab.isActive != listed.active { tab.isActive = listed.active }
        if tab.isSelected != listed.highlighted { tab.isSelected = listed.highlighted }
        if tab.isPinned != listed.pinned { tab.isPinned = listed.pinned }
        if tab.reportedDiscarded != listed.discarded { tab.reportedDiscarded = listed.discarded }
        if tab.reportedAudible != listed.audible { tab.reportedAudible = listed.audible }
        if tab.reportedLoading != listed.loading { tab.reportedLoading = listed.loading }
        let opener = listed.opener >= 0 ? CefTab.ID(rawValue: listed.opener) : nil
        if tab.openerID != opener { tab.openerID = opener }
        let favicon = listed.favicon.isEmpty ? nil : URL(string: listed.favicon)
        if tab.faviconURL != favicon { tab.faviconURL = favicon }
        var alerts: [CefTab.Alert] = []
        if let internalWindow, listed.index < internalWindow.tabs.count, internalWindow.tabs[listed.index].url == listed.url {
            alerts = internalWindow.tabs[listed.index].alerts.map(CefTab.Alert.init(name:))
        }
        // Sound comes from chrome.tabs, and muting from CEF (CefTab.alerts).
        alerts.removeAll { $0 == .playingAudio || $0 == .muted }
        if tab.otherAlerts != alerts { tab.otherAlerts = alerts }
    }

    /// Browsers the app made in a window of their own on their way to
    /// another window (``CefChromeWindow/openTab(_:at:isActive:configuration:delegate:)``).
    @ObservationIgnored var transientBrowsers = Set<ObjectIdentifier>()

    /// Windows the app opened that Chromium has not listed yet.
    @ObservationIgnored var pendingWindows: [CefChromeWindow] = []

    // MARK: Matching tabs with browsers

    @ObservationIgnored private var isBinding = false
    @ObservationIgnored private var bindAgain = false

    /// Binds `browser` to the tab `id`: the app opened that tab with that
    /// browser.
    func bind(_ browser: CefBrowser, to id: CefTab.ID) {
        if let old = tabsByID[id]?.browser { tabIDsByBrowser[ObjectIdentifier(old)] = nil }
        tabIDsByBrowser[ObjectIdentifier(browser)] = id
        knownBindings[id] = browser
        tabsByID[id]?.browser = browser
    }

    /// Bindings made before the tab was listed.
    @ObservationIgnored private var knownBindings: [CefTab.ID: CefBrowser] = [:]

    /// Browsers of this profile that can be one of its Chromium tabs and
    /// are not yet matched: live, Chrome style, not in a ``CefWindow``.
    private var unboundBrowsers: [CefBrowser] {
        CefRuntime.shared.browsers.filter { browser in
            browser.state == .live && isCandidate(browser) && tabIDsByBrowser[ObjectIdentifier(browser)] == nil
        }
    }

    /// Matches every tab without a browser that can be matched exactly.
    private func bindBrowsers() async {
        guard !isBinding else { bindAgain = true; return }
        isBinding = true
        defer { isBinding = false }
        repeat {
            bindAgain = false
            await bindOnce()
        } while bindAgain && isLive
    }

    private func bindOnce() async {
        // Browsers that closed.
        for (id, tab) in tabsByID {
            if let browser = tab.browser, browser.state == .closed {
                tabIDsByBrowser[ObjectIdentifier(browser)] = nil
                tab.browser = nil
            }
            if tab.browser == nil, let known = knownBindings[id], known.state != .closed {
                tab.browser = known
                tabIDsByBrowser[ObjectIdentifier(known)] = id
            }
        }
        knownBindings = knownBindings.filter { tabsByID[$0.key] == nil && $0.value.state != .closed }

        var candidates = unboundBrowsers
        for window in allWindows where window.window == nil {
            if let nsWindow = window.activeTab?.browser?.nativeView?.window, CefWindow.owning(nsWindow) == nil {
                window.attach(to: nsWindow)
            }
        }
        guard !candidates.isEmpty else { return }
        func take(_ browser: CefBrowser, for tab: CefTab) {
            tab.browser = browser
            tabIDsByBrowser[ObjectIdentifier(browser)] = tab.id
            candidates.removeAll { $0 === browser }
        }

        // A browser's page is in its tab's window, shown for the active
        // tab and hidden for the others.
        func nsWindow(of browser: CefBrowser) -> NSWindow? {
            guard let window = browser.nativeView?.window, CefWindow.owning(window) == nil else { return nil }
            return window
        }
        func isShown(_ browser: CefBrowser) -> Bool {
            browser.nativeView.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
        }
        let windows = allWindows
        // Each window's active tab: the browser shown in its NSWindow, or,
        // for a window whose NSWindow is not known yet, the one browser
        // with its address shown in an NSWindow no other window has.
        for window in windows {
            guard let active = window.activeTab, active.browser == nil else { continue }
            let shown = candidates.filter { browser in
                guard isShown(browser), let nsWindow = nsWindow(of: browser) else { return false }
                if let known = window.window { return known === nsWindow }
                return !windows.contains { $0 !== window && $0.window === nsWindow } && Self.sameAddress(browser.url, active.url)
            }
            if shown.count == 1 { take(shown[0], for: active) }
        }
        for window in windows where window.window == nil {
            if let browser = window.activeTab?.browser, let nsWindow = nsWindow(of: browser) { window.attach(to: nsWindow) }
        }

        // Background tabs: among the browsers in their window, the one with
        // their address; when several share one, by muting.
        for window in windows {
            guard let known = window.window else { continue }
            let unbound = window.tabs.filter { $0.browser == nil }
            guard !unbound.isEmpty else { continue }
            for (address, sharing) in Dictionary(grouping: unbound, by: { $0.url?.absoluteString ?? "" }) where !address.isEmpty {
                var tabs = sharing
                var browsers = candidates.filter { nsWindow(of: $0) === known && $0.url?.absoluteString == address }
                guard !browsers.isEmpty, tabs.count >= browsers.count else { continue }
                while let browser = browsers.first, !tabs.isEmpty, isLive {
                    if tabs.count == 1, browsers.count == 1 {
                        take(browser, for: tabs[0])
                        break
                    }
                    guard let match = await tabMuted(by: browser, among: tabs) else { break }
                    take(browser, for: match)
                    tabs.removeAll { $0 === match }
                    browsers.removeFirst()
                }
            }
        }
    }

    /// Which of `tabs` `browser` shows: mutes it (or unmutes it) through
    /// CEF, asks Chromium which tab's muting changed, and puts it back.
    private func tabMuted(by browser: CefBrowser, among tabs: [CefTab]) async -> CefTab? {
        let ids: [CefJSON] = tabs.map { .number(Double($0.id.rawValue)) }
        let read: () async -> [Int: Bool]? = { [services] in
            guard let pairs = try? await services.call(
                Self.tabsModule, "async (s, a) => Promise.all(a.ids.map(async id => [id, (await s.t.get(id)).mutedInfo?.muted ? 1 : 0]))",
                .object(["ids": .array(ids)]), as: [[Int]].self, keepsHostFor: Self.hostIdle)
            else { return nil }
            // Booleans arrive as numbers in an array of integers.
            return Dictionary(pairs.compactMap { $0.count == 2 ? ($0[0], $0[1] != 0) : nil }, uniquingKeysWith: { a, _ in a })
        }
        guard let before = await read() else { return nil }
        let wasMuted = browser.isAudioMuted
        browser.isAudioMuted = !wasMuted
        defer { browser.isAudioMuted = wasMuted }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(10))
            guard let after = await read() else { return nil }
            let changed = tabs.filter { before[$0.id.rawValue] != after[$0.id.rawValue] }
            if changed.count == 1 { return changed[0] }
            if changed.count > 1 { return nil }
        }
        return nil
    }

    static func sameAddress(_ a: URL?, _ b: URL?) -> Bool {
        a?.absoluteString == b?.absoluteString
    }

    // MARK: Commands

    /// Shows `tab`, and brings its window to the front.
    public func select(_ tab: CefTab) async throws {
        try await run("async (s, a) => { const t = await s.t.update(a.id, {active: true}); await s.w.update(t.windowId, {focused: true}); return true; }",
                      ["id": .number(Double(tab.id.rawValue))])
        tab.window?.window?.makeKeyAndOrderFront(nil)
    }

    /// Selects `tabs` of one window together, as ⌘-clicking them in Chrome
    /// does; the first becomes the active tab.
    public func select(_ tabs: [CefTab]) async throws {
        guard let first = tabs.first, let window = first.window else { return }
        let indices = tabs.filter { $0.window === window }.map(\.index)
        try await run("async (s, a) => { await s.t.highlight({windowId: a.window, tabs: a.indices}); return true; }",
                      ["window": .number(Double(window.id.rawValue)), "indices": .array(indices.map { .number(Double($0)) })])
    }

    /// Closes `tabs` through CEF, as their close buttons would (a page's
    /// `beforeunload` handler may keep its tab open).
    ///
    /// Not through `chrome.tabs.remove`, which ended the browser process
    /// when called from a WebUI page on CEF 156.
    public func close(_ tabs: [CefTab]) {
        for tab in tabs { tab.browser?.close() }
    }

    /// Pins or unpins `tabs`.
    public func pin(_ tabs: [CefTab], _ isPinned: Bool = true) async throws {
        try await run("async (s, a) => { for (const id of a.ids) await s.t.update(id, {pinned: a.pinned}); return true; }",
                      ["ids": ids(tabs), "pinned": .bool(isPinned)])
    }

    /// Moves `tabs`, in order, to `index` of `window` (`-1` for the end).
    /// A move to another window keeps each tab's page and browser.
    public func move(_ tabs: [CefTab], to index: Int, in window: CefChromeWindow?) async throws {
        guard let window = window ?? tabs.first?.window else { throw Error.tabClosed }
        try await run("async (s, a) => { await s.t.move(a.ids, {windowId: a.window, index: a.index}); return true; }",
                      ["ids": ids(tabs), "window": .number(Double(window.id.rawValue)), "index": .number(Double(index))])
    }

    /// Puts `tabs` in `group`, or in a new group in the first tab's window,
    /// and returns the group.
    @discardableResult
    public func group(_ tabs: [CefTab], into group: CefTabGroup? = nil) async throws -> CefTabGroup? {
        guard let first = tabs.first, let window = first.window else { return group }
        var arguments: [String: CefJSON] = ["ids": ids(tabs), "window": .number(Double(window.id.rawValue))]
        if let group { arguments["group"] = .number(Double(group.id.rawValue)) }
        let id = try await run(
            """
            async (s, a) => a.group != null ? await s.t.group({tabIds: a.ids, groupId: a.group})
              : await s.t.group({tabIds: a.ids, createProperties: {windowId: a.window}})
            """, arguments, as: Int.self)
        return groupsByID[CefTabGroup.ID(rawValue: id)]
    }

    /// Takes `tabs` out of their groups.
    public func ungroup(_ tabs: [CefTab]) async throws {
        try await run("async (s, a) => { await s.t.ungroup(a.ids); return true; }", ["ids": ids(tabs)])
    }

    /// Opens a copy of `tab` beside it.
    @discardableResult
    public func duplicate(_ tab: CefTab) async throws -> CefTab {
        let id = try await run("async (s, a) => (await s.t.duplicate(a.id)).id", ["id": .number(Double(tab.id.rawValue))], as: Int.self)
        guard let made = tabsByID[CefTab.ID(rawValue: id)] else { throw Error.chromium("Chromium did not duplicate the tab.") }
        return made
    }

    /// Moves `tabs` into a new window, the first one by Chromium's
    /// `chrome.windows.create` and the others after it.
    @discardableResult
    public func moveToNewWindow(_ tabs: [CefTab]) async throws -> CefChromeWindow {
        guard !tabs.isEmpty else { throw Error.tabClosed }
        let id = try await run(
            """
            async (s, a) => {
              const w = await s.w.create({tabId: a.ids[0], focused: true});
              if (a.ids.length > 1) await s.t.move(a.ids.slice(1), {windowId: w.id, index: -1});
              return w.id;
            }
            """, ["ids": ids(tabs)], as: Int.self)
        guard let window = window(CefChromeWindow.ID(rawValue: id)) else { throw Error.chromium("Chromium did not open the window.") }
        return window
    }

    /// Moves `group` into a new window, grouped again there.
    func moveGroupToNewWindow(_ group: CefTabGroup) async throws -> CefChromeWindow {
        let tabs = group.tabs
        let title = group.title, color = group.color
        let window = try await moveToNewWindow(tabs)
        let regrouped = try await self.group(tabs.compactMap { self.tab($0.id) })
        if let regrouped {
            if !title.isEmpty || color != .grey { try? await editGroup(regrouped, title: title, color: color) }
        }
        return window
    }

    /// Opens the tab, window or group closed last, as ⌘⇧T does in Chrome,
    /// in `window` (by default the frontmost of the profile's).
    public func reopenClosed(in window: CefChromeWindow? = nil) {
        let target = window ?? windows.first { $0.isFocused } ?? windows.first
        guard let browser = target?.activeTab?.browser ?? target?.tabs.lazy.compactMap(\.browser).first else { return }
        browser.execute(.restoreTab)
    }

    func editGroup(_ group: CefTabGroup, title: String?, color: CefTabGroup.Color?) async throws {
        guard let window = group.window else { throw Error.tabClosed }
        try await ChromeTabStripAccessibility.edit(group, in: window, title: title, color: color)
        await nextRead(internals: true)
    }

    /// Opens `url` in a new tab Chromium makes, in `window` at `index` (by
    /// default after the active tab... at the end).
    func chromiumTab(_ url: URL, in window: CefChromeWindow, at index: Int?, isActive: Bool) async throws -> CefTab {
        var properties: [String: CefJSON] = [
            "windowId": .number(Double(window.id.rawValue)), "url": .string(url.absoluteString), "active": .bool(isActive),
        ]
        if let index { properties["index"] = .number(Double(index)) }
        let id = try await run("async (s, a) => (await s.t.create(a)).id", .object(properties), as: Int.self)
        guard let tab = tabsByID[CefTab.ID(rawValue: id)] else { throw Error.chromium("Chromium did not open the tab.") }
        return tab
    }

    /// Moves the one tab of the window `from` (a window opened for a
    /// browser the app made) into `window` at `index`, and returns it.
    func adoptSingleTab(of from: CefChromeWindow.ID, into window: CefChromeWindow, at index: Int?, isActive: Bool) async throws -> CefTab.ID {
        let id = try await run(
            """
            async (s, a) => {
              const [tab, ...more] = await s.t.query({windowId: a.from});
              if (!tab || more.length) throw new Error('the new window has ' + (more.length + (tab ? 1 : 0)) + ' tabs');
              await s.t.move(tab.id, {windowId: a.to, index: a.index});
              if (a.active) await s.t.update(tab.id, {active: true});
              return tab.id;
            }
            """,
            ["from": .number(Double(from.rawValue)), "to": .number(Double(window.id.rawValue)),
             "index": .number(Double(index ?? -1)), "active": .bool(isActive)], as: Int.self)
        return CefTab.ID(rawValue: id)
    }

    /// Closes `window` as Chrome's Close Window does (`IDC_CLOSE_WINDOW`),
    /// so Chromium keeps it as one entry with all its tabs, which
    /// ``reopen(_:)`` and ⌘⇧T bring back whole; through CEF, tab by tab,
    /// when none of its browsers is known.
    func close(_ window: CefChromeWindow) {
        if let browser = window.activeTab?.browser ?? window.tabs.lazy.compactMap(\.browser).first {
            browser.execute(.closeWindow)
        } else {
            close(window.tabs)
        }
    }

    func focus(_ window: CefChromeWindow) async throws {
        try await run("async (s, a) => { await s.w.update(a.id, {focused: true}); return true; }", ["id": .number(Double(window.id.rawValue))])
    }

    private func ids(_ tabs: [CefTab]) -> CefJSON {
        .array(tabs.map { .number(Double($0.id.rawValue)) })
    }

    /// Runs a change on the `chrome.tabs` host, then waits until the strip
    /// shows its outcome.
    @discardableResult
    private func run<Result: Decodable & Sendable>(
        _ function: String, _ arguments: [String: CefJSON], as type: Result.Type = Bool.self
    ) async throws -> Result {
        try await run(function, .object(arguments), as: type)
    }

    @discardableResult
    private func run<Result: Decodable & Sendable>(
        _ function: String, _ arguments: CefJSON, as type: Result.Type = Bool.self
    ) async throws -> Result {
        startFollowing()
        let result: Result
        do {
            result = try await services.call(Self.tabsModule, function, arguments, as: type, keepsHostFor: Self.hostIdle)
        } catch let error as CefError {
            throw Error.chromium("\(error)")
        }
        await nextRead()
        return result
    }

    // MARK: Plumbing

    /// `chrome.tabs` and `chrome.windows` on the bookmarks host: their
    /// state, and, for ``observesChromiumEvents``, a version counted up at
    /// each of their events.
    static let tabsModule = CefServiceHost.Module(
        name: "tabs", hosts: [.bookmarks],
        setup: """
            async emit => {
              const t = chrome.tabs, w = chrome.windows;
              if (!t || !w) throw new Error('chrome.tabs is not available on this page');
              const tab = x => ({id: x.id, index: x.index, url: x.url || x.pendingUrl || '', title: x.title || '',
                active: !!x.active, highlighted: !!x.highlighted, pinned: !!x.pinned, group: x.groupId ?? -1,
                audible: !!x.audible, muted: !!(x.mutedInfo && x.mutedInfo.muted), discarded: !!x.discarded,
                loading: x.status == 'loading', favicon: x.favIconUrl || '', opener: x.openerTabId ?? -1});
              const read = async () => {
                const windows = (await w.getAll({populate: true})).filter(x => x.type == 'normal').map(x => ({
                  id: x.id, focused: !!x.focused, incognito: !!x.incognito, state: x.state || '',
                  bounds: [x.left ?? 0, x.top ?? 0, x.width ?? 0, x.height ?? 0], tabs: (x.tabs || []).map(tab)}));
                return {windows};
              };
              // Events, added on the first wait and kept with the page. Not
              // chrome.windows.onFocusChanged: with a listener to it on this
              // WebUI page, Chromium (CEF 156) crashes when an incognito
              // window opens. A tab's title, icon and loading come from CEF.
              let version = 0, waiters = [], listening = false;
              const bump = () => { version++; for (const f of waiters.splice(0)) f(); };
              const changed = (id, info) => { if (Object.keys(info).some(k => !['title', 'favIconUrl', 'status'].includes(k))) bump(); };
              const listen = () => {
                if (listening) return;
                listening = true;
                t.onUpdated.addListener(changed);
                for (const e of [t.onCreated, t.onMoved, t.onActivated, t.onHighlighted, t.onDetached, t.onAttached,
                                 t.onRemoved, t.onReplaced, w.onCreated, w.onRemoved]) e.addListener(bump);
              };
              const wait = async (since, signal) => {
                listen();
                if (since != null && since == version) {
                  await new Promise(resolve => { waiters.push(resolve); signal.addEventListener('abort', resolve); });
                }
                return version;
              };
              return {t, w, read, wait};
            }
            """)

    /// `tab_strip_internals.mojom`: groups' names, colours and collapsing,
    /// tabs' alert states, and what Chromium can reopen.
    static let internalsModule = CefServiceHost.Module(
        name: "tab-strip", hosts: [.tabStripInternals],
        setup: """
            async emit => {
              const path = 'chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js';
              const m = await import(path);
              let alertNames = [];
              try {
                const source = await (await fetch(path)).text();
                const tabs = source.match(/from '([^']*tabs\\.mojom-webui\\.js)'/);
                if (tabs) {
                  const t = await import(new URL(tabs[1], path).href);
                  if (t.TabAlertState) for (const [k, v] of Object.entries(t.TabAlertState)) if (typeof v == 'number') alertNames[v] = k;
                }
              } catch (e) {}
              const handler = new m.PageHandlerRemote();
              const router = new m.PageCallbackRouter();
              m.PageHandlerFactory.getRemote().createPageHandler(
                router.$.bindNewPipeAndPassRemote(), handler.$.bindNewPipeAndPassReceiver());
              const text = s => typeof s == 'string' ? s : (s && s.data ? String.fromCharCode(...s.data) : '');
              const url = u => typeof u == 'string' ? u : (u && u.url) || '';
              const flatten = (node, out, group) => {
                const d = node.data, kind = Object.keys(d).find(k => d[k] != null), v = d[kind];
                if (kind == 'tab') {
                  out.tabs.push({url: url(v.url), group, alerts: (v.alertStates || []).map(a => alertNames[a] || String(a))});
                  return;
                }
                let inner = group;
                if (kind == 'tabGroupCollection') {
                  const visual = v.visualData || {};
                  inner = v.id.nodeId;
                  out.groups.push({id: inner, title: text(visual.title), color: visual.color ?? 0, collapsed: !!visual.isCollapsed});
                }
                for (const child of node.children || []) flatten(child, out, inner);
              };
              // A TabRestoreService entry: {tab: …}, {window: {tabs: […]}} or
              // {group: {tabs: […], visualData}}, each with an id and a time.
              const closedItem = entry => {
                const kind = ['tab', 'window', 'group'].find(k => entry[k] != null) || 'other';
                const v = entry[kind] || {};
                const tabs = Array.isArray(v.tabs) ? v.tabs.map(x => x.tab || x) : [];
                const first = kind == 'tab' ? v : (tabs[v.selectedTabIndex ?? 0] || tabs[0] || {});
                const groupTitle = kind == 'group' ? text((v.visualData || v.groupVisualData || {}).title) : '';
                const time = (v.restoreEntry && v.restoreEntry.timestamp && Number(v.restoreEntry.timestamp.internalValue)) || 0;
                return {id: Number((v.id && v.id.nodeId) ?? -1), kind, title: groupTitle || text(first.title), url: url(first.url),
                        tabs: kind == 'tab' ? 1 : tabs.length, time,
                        window: Number((v.browserId && v.browserId.id) ?? -1), index: v.tabstripIndex ?? -1};
              };
              const read = async () => {
                const {data} = await handler.getTabStripData();
                const windows = data.tabstripTree.windows.map(w => {
                  const out = {id: w.id.nodeId, tabs: [], groups: []};
                  if (w.tabstripModel.root) flatten(w.tabstripModel.root, out, null);
                  return out;
                });
                const closed = ((data.tabRestore && data.tabRestore.entries) || []).map(closedItem);
                return {windows, closed};
              };
              return {read};
            }
            """)
}

/// What `chrome.tabs` and `chrome.windows` report.
struct TabsSnapshot: Decodable, Sendable {
    struct Tab: Decodable, Sendable {
        var id: Int
        var index: Int
        var url: String
        var title: String
        var active: Bool
        var highlighted: Bool
        var pinned: Bool
        var group: Int
        var audible: Bool
        var muted: Bool
        var discarded: Bool
        var loading: Bool
        var favicon: String
        var opener: Int
    }

    struct Window: Decodable, Sendable {
        var id: Int
        var focused: Bool
        var incognito: Bool
        var state: String
        var bounds: [Double]
        var tabs: [Tab]
    }

    var windows: [Window]
}

/// What the internal page reports.
struct InternalsSnapshot: Decodable, Sendable {
    struct Tab: Decodable, Sendable {
        var url: String
        var group: String?
        var alerts: [String]
    }

    struct Group: Decodable, Sendable {
        var id: String
        var title: String
        var color: Int
        var collapsed: Bool
    }

    struct Window: Decodable, Sendable {
        var id: String
        var tabs: [Tab]
        var groups: [Group]
    }

    struct Closed: Decodable, Sendable {
        var id: Int
        var kind: String
        var title: String
        var url: String
        var tabs: Int
        var time: Double
        var window: Int
        var index: Int

        var itemKind: CefTabStrip.ClosedItem.Kind {
            switch kind {
            case "tab": .tab
            case "window": .window
            case "group": .group
            default: .other
            }
        }
    }

    var windows: [Window]
    var closed: [Closed]
}

extension CefServiceHost {
    /// `tab_strip_internals.mojom.PageHandlerFactory`.
    static let tabStripInternals = CefServiceHost(
        name: "tab-strip-internals", document: "chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js",
        isAvailableInIncognito: false)
}

extension CefProfile {
    /// Chromium's tabbed windows of this profile, their tabs and groups.
    /// It follows Chromium from first use, and the profile keeps it while
    /// the runtime runs.
    public var tabStrip: CefTabStrip {
        let stores = chromiumStores
        if let tabStrip = stores.tabStrip { return tabStrip }
        let made = CefTabStrip(profile: self)
        stores.tabStrip = made
        made.startFollowing()
        return made
    }
}
