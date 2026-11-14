import AppKit
import CefKit
import Foundation
import Observation

/// Chromium's own tabs, windows and tab groups for one ``CefProfile``:
/// the profile's ``CefChromeWindow``s, mirrored and driven through
/// Chromium.
///
/// It is the model a custom tab interface draws: Chromium stays the source
/// of truth, so what extensions do with `chrome.tabs` and what Chrome's own
/// commands do shows up here by itself, and every change made here is one
/// Chromium makes — moving a tab to another window keeps its page, history
/// and ``CefBrowser``.
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
/// The strip follows Chromium from the moment it is first used, for as long
/// as the runtime runs, and is kept by the profile meanwhile. Each change
/// is reported by Chromium and read again: `chrome.tabs` and
/// `chrome.windows` events, on Chromium's own `chrome://bookmarks` page,
/// which Chromium grants those extension APIs, and
/// `tab_strip_internals.mojom` (`chrome://tab-strip-internals`), which
/// reports groups' names, colours and collapsing; both from hidden service
/// hosts. Windows CefKit hosts (``CefWindow``, one tab each, which Chromium
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

    /// A tab or window Chromium can reopen, newest first.
    public struct ClosedItem: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case tab, window, group, other }
        public var kind: Kind
        public var title: String
        public var url: URL?
    }

    /// The profile's tabbed windows, in the order Chromium lists them.
    /// A window a new tab starts in on its way to another
    /// (``CefChromeWindow/openTab(_:at:isActive:configuration:delegate:)``)
    /// is not listed.
    public var windows: [CefChromeWindow] { allWindows.filter { !$0.isTransient } }

    /// Every window, transient ones included.
    private(set) var allWindows: [CefChromeWindow] = []

    /// What Chromium can reopen, newest first: tabs, windows and groups
    /// closed in this session.
    public private(set) var recentlyClosed: [ClosedItem] = []

    /// Why the last read failed — an internal page moved or changed in a
    /// Chromium update — or `nil`.
    public private(set) var lastError: String?

    /// Called once for each window as soon as its `NSWindow` is known:
    /// the windows the app opens and those Chromium opens itself (a tab
    /// dragged out, `chrome.windows.create` from an extension). Dress the
    /// window here: hide Chrome's tab strip and toolbar, give it a top bar.
    @ObservationIgnored public var onWindowOpened: ((CefChromeWindow) -> Void)?

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

    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var tabsSnapshot: TabsSnapshot?
    @ObservationIgnored private var internalsSnapshot: InternalsSnapshot?
    /// Group names and colours by group, as last read from the internal
    /// page: kept while a read of it does not line up with `chrome.tabs`.
    @ObservationIgnored private var visuals: [CefTabGroup.ID: InternalsSnapshot.Group] = [:]
    /// Callers waiting for the strip to show a read of at least a version.
    @ObservationIgnored private var readWaiters: [(version: Int, continuation: CheckedContinuation<Void, Never>)] = []
    @ObservationIgnored private var readSoon = false
    /// Windows being opened, which keep the strip following meanwhile.
    @ObservationIgnored var openings = 0
    @ObservationIgnored private var windowObserver: NSObjectProtocol?

    /// Starts following Chromium, if not yet: on first use, whenever the
    /// app opens a window, and when one of Chromium's windows becomes the
    /// main window. The strip stops once the profile has no windows left,
    /// so its hidden service hosts can close.
    func startFollowing() {
        if windowObserver == nil {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window, self.following == nil, CefWindow.owning(window) == nil,
                          "\(type(of: window.contentView ?? NSView()))" == "BridgedContentView"
                    else { return }
                    self.startFollowing()
                }
            }
        }
        guard following == nil, CefRuntime.shared.isRunning, !CefRuntime.shared.isTerminating else { return }
        following = Task { [self] in
            let internals = Task { await self.followInternals() }
            await followTabs()
            internals.cancel()
            following = nil
            let waiting = readWaiters
            readWaiters = []
            waiting.forEach { $0.continuation.resume() }
        }
    }

    /// Whether the strip should go on reading.
    private var isLive: Bool {
        !Task.isCancelled && CefRuntime.shared.isRunning && !CefRuntime.shared.isTerminating
    }

    private func followTabs() async {
        var version: Int?
        while isLive {
            do {
                let next = try await services.call(
                    Self.tabsModule, "(s, a, c) => s.read(a.since, c.signal)",
                    .object(version.map { ["since": .number(Double($0))] } ?? [:]),
                    as: TabsSnapshot.self, timeout: .seconds(40), isIdempotent: true)
                version = next.version
                tabsSnapshot = next
                lastError = nil
                rebuild()
                await bindBrowsers()
                let ready = readWaiters.filter { $0.version <= next.version }
                readWaiters.removeAll { $0.version <= next.version }
                ready.forEach { $0.continuation.resume() }
                if allWindows.isEmpty, pendingWindows.isEmpty, openings == 0, readWaiters.isEmpty { break }
                // Several events come together (a load sends a few): read
                // once they have.
                if readWaiters.isEmpty { try? await Task.sleep(for: .milliseconds(16)) }
            } catch {
                guard isLive else { break }
                lastError = "chrome.tabs: \(error)"
                version = nil
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func followInternals() async {
        var version: Int?
        // The internal page is not built for incognito profiles; the
        // default profile's lists every window.
        let services = internalsServices
        while isLive {
            do {
                let next = try await services.call(
                    Self.internalsModule, "(s, a, c) => s.read(a.since, c.signal)",
                    .object(version.map { ["since": .number(Double($0))] } ?? [:]),
                    as: InternalsSnapshot.self, timeout: .seconds(40), isIdempotent: true)
                version = next.version
                internalsSnapshot = next
                rebuild()
            } catch {
                guard isLive else { break }
                lastError = "tab-strip-internals: \(error)"
                version = nil
                try? await Task.sleep(for: .seconds(1))
            }
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
    func nextRead() async {
        startFollowing()
        // Chromium reports some changes to groups (their names, colours
        // and collapsing) to the internal page only when it reads again.
        _ = try? await internalsServices.call(Self.internalsModule, "s => s.bump()", as: Int.self)
        guard following != nil,
              let version = try? await services.call(Self.tabsModule, "s => s.bump()", as: Int.self),
              following != nil
        else { return }
        if let tabsSnapshot, tabsSnapshot.version >= version { return }
        await withCheckedContinuation { readWaiters.append((version, $0)) }
    }

    /// Reads again soon: after a change Chromium may not report, such as a
    /// tab muted through CEF.
    func scheduleRead() {
        guard !readSoon else { return }
        readSoon = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            readSoon = false
            await nextRead()
        }
    }

    /// Reads Chromium's tabs once more, and returns when the strip shows
    /// them.
    public func refresh() async {
        await nextRead()
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

        let closed = (internalsSnapshot?.closed ?? []).map { item in
            ClosedItem(kind: item.itemKind, title: item.title, url: URL(string: item.url))
        }
        if closed != recentlyClosed { recentlyClosed = closed }
    }

    private func update(_ tab: CefTab, from listed: TabsSnapshot.Tab, in window: CefChromeWindow,
                        internalWindow: InternalsSnapshot.Window?) {
        if tab.window !== window { tab.window = window }
        if tab.index != listed.index { tab.index = listed.index }
        let title = listed.title
        if tab.title != title { tab.title = title }
        let url = URL(string: listed.url)
        if tab.url != url { tab.url = url }
        if tab.isActive != listed.active { tab.isActive = listed.active }
        if tab.isSelected != listed.highlighted { tab.isSelected = listed.highlighted }
        if tab.isPinned != listed.pinned { tab.isPinned = listed.pinned }
        if tab.isDiscarded != listed.discarded { tab.isDiscarded = listed.discarded }
        if tab.isAudible != listed.audible { tab.isAudible = listed.audible }
        if tab.isMuted != listed.muted { tab.isMuted = listed.muted }
        if tab.isLoading != listed.loading { tab.isLoading = listed.loading }
        let opener = listed.opener >= 0 ? CefTab.ID(rawValue: listed.opener) : nil
        if tab.openerID != opener { tab.openerID = opener }
        let favicon = listed.favicon.isEmpty ? nil : URL(string: listed.favicon)
        if tab.faviconURL != favicon { tab.faviconURL = favicon }
        var alerts: [CefTab.Alert] = []
        if let internalWindow, listed.index < internalWindow.tabs.count, internalWindow.tabs[listed.index].url == listed.url {
            alerts = internalWindow.tabs[listed.index].alerts.map(CefTab.Alert.init(name:))
        }
        if listed.muted, !alerts.contains(.muted) { alerts.append(.muted) }
        if listed.audible, !listed.muted, !alerts.contains(.playingAudio) { alerts.insert(.playingAudio, at: 0) }
        if tab.alerts != alerts { tab.alerts = alerts }
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
        let hosted = Set(CefWindow.all.map { ObjectIdentifier($0.browser) })
        return CefRuntime.shared.browsers.filter { browser in
            browser.state == .live && browser.isChromeStyle && !hosted.contains(ObjectIdentifier(browser))
                && tabIDsByBrowser[ObjectIdentifier(browser)] == nil
                && (browser.configuration.profile ?? .default) === profile
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
                .object(["ids": .array(ids)]), as: [[Int]].self)
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
        guard let first = tabs.first else { throw Error.tabClosed }
        let id = try await run(
            """
            async (s, a) => {
              const w = await s.w.create({tabId: a.ids[0], focused: true});
              if (a.ids.length > 1) await s.t.move(a.ids.slice(1), {windowId: w.id, index: -1});
              return w.id;
            }
            """, ["ids": ids(tabs)], as: Int.self)
        _ = first
        guard let window = window(CefChromeWindow.ID(rawValue: id)) else { throw Error.chromium("Chromium did not open the window.") }
        return window
    }

    /// Moves `group` into a new window, grouped again there.
    func moveGroupToNewWindow(_ group: CefTabGroup) async throws -> CefChromeWindow {
        let tabs = group.tabs
        let title = group.title, color = group.color, isCollapsed = group.isCollapsed
        let window = try await moveToNewWindow(tabs)
        let regrouped = try await self.group(tabs.compactMap { self.tab($0.id) })
        if let regrouped {
            if !title.isEmpty || color != .grey { try? await editGroup(regrouped, title: title, color: color) }
            if isCollapsed { try? await regrouped.setCollapsed(true) }
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

    func toggleCollapsed(_ group: CefTabGroup) async throws {
        guard let window = group.window else { throw Error.tabClosed }
        try await ChromeTabStripAccessibility.toggleCollapsed(group, in: window)
        await nextRead()
    }

    func editGroup(_ group: CefTabGroup, title: String?, color: CefTabGroup.Color?) async throws {
        guard let window = group.window else { throw Error.tabClosed }
        try await ChromeTabStripAccessibility.edit(group, in: window, title: title, color: color)
        await nextRead()
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

    /// The windows Chromium lists now, read directly.
    func listedWindowIDs() async throws -> [(id: CefChromeWindow.ID, tabs: [String])] {
        let listed = try await services.call(
            Self.tabsModule, "async s => (await s.w.getAll({populate: true})).filter(w => w.type == 'normal').map(w => [String(w.id), ...w.tabs.map(t => t.url || t.pendingUrl || '')])",
            as: [[String]].self, isIdempotent: true)
        return listed.compactMap { row in
            guard let first = row.first, let id = Int(first) else { return nil }
            return (CefChromeWindow.ID(rawValue: id), Array(row.dropFirst()))
        }
    }

    /// Closes `window`'s tabs through CEF.
    func close(_ window: CefChromeWindow) {
        close(window.tabs)
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
            result = try await services.call(Self.tabsModule, function, arguments, as: type)
        } catch let error as CefError {
            throw Error.chromium("\(error)")
        }
        await nextRead()
        return result
    }

    // MARK: Plumbing

    /// `chrome.tabs` and `chrome.windows` on the bookmarks host: their
    /// state, and a version counted up at each event, so a read can wait
    /// for the next one.
    static let tabsModule = CefServiceHost.Module(
        name: "tabs", hosts: [.bookmarks],
        setup: """
            async emit => {
              const t = chrome.tabs, w = chrome.windows;
              if (!t || !w) throw new Error('chrome.tabs is not available on this page');
              let version = 0, waiters = [];
              const bump = () => { version++; for (const f of waiters.splice(0)) f(); return version; };
              for (const e of [t.onCreated, t.onUpdated, t.onMoved, t.onActivated, t.onHighlighted, t.onDetached,
                               t.onAttached, t.onRemoved, t.onReplaced, w.onCreated, w.onRemoved, w.onFocusChanged,
                               w.onBoundsChanged]) {
                try { e && e.addListener(bump); } catch (error) {}
              }
              const tab = x => ({id: x.id, index: x.index, url: x.url || x.pendingUrl || '', title: x.title || '',
                active: !!x.active, highlighted: !!x.highlighted, pinned: !!x.pinned, group: x.groupId ?? -1,
                audible: !!x.audible, muted: !!(x.mutedInfo && x.mutedInfo.muted), discarded: !!x.discarded,
                loading: x.status == 'loading', favicon: x.favIconUrl || '', opener: x.openerTabId ?? -1});
              const read = async (since, signal) => {
                if (since != null && since == version) {
                  await new Promise(resolve => {
                    waiters.push(resolve);
                    signal.addEventListener('abort', resolve);
                    setTimeout(resolve, 30000);
                  });
                }
                const seen = version;
                const windows = (await w.getAll({populate: true})).filter(x => x.type == 'normal').map(x => ({
                  id: x.id, focused: !!x.focused, incognito: !!x.incognito, state: x.state || '',
                  bounds: [x.left ?? 0, x.top ?? 0, x.width ?? 0, x.height ?? 0], tabs: (x.tabs || []).map(tab)}));
                return {version: seen, windows};
              };
              return {t, w, read, bump};
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
              let version = 0, waiters = [];
              const bump = () => { version++; for (const w of waiters.splice(0)) w(); return version; };
              router.onTabStripUpdated.addListener(bump);
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
              const closedItem = entry => {
                const found = {kind: 'other', title: '', url: ''};
                const visit = (value, key, depth) => {
                  if (depth > 6 || value == null) return;
                  if (typeof value == 'string') {
                    if (key == 'title' && !found.title) found.title = value;
                    if (key == 'url' && !found.url) found.url = value;
                    return;
                  }
                  if (typeof value != 'object') return;
                  if (value.data && Array.isArray(value.data) && key == 'title') { if (!found.title) found.title = text(value); return; }
                  if (key == 'url' && typeof value.url == 'string') { if (!found.url) found.url = value.url; return; }
                  for (const [k, v] of Object.entries(value)) {
                    if (depth == 0 && v != null && ['tab', 'window', 'group'].includes(k)) found.kind = k;
                    visit(v, k, depth + 1);
                  }
                };
                visit(entry, '', 0);
                return found;
              };
              const read = async (since, signal) => {
                if (since != null && since == version) {
                  await new Promise(resolve => {
                    waiters.push(resolve);
                    signal.addEventListener('abort', resolve);
                    setTimeout(resolve, 30000);
                  });
                }
                const seen = version;
                const {data} = await handler.getTabStripData();
                const windows = data.tabstripTree.windows.map(w => {
                  const out = {id: w.id.nodeId, tabs: [], groups: []};
                  if (w.tabstripModel.root) flatten(w.tabstripModel.root, out, null);
                  return out;
                });
                const closed = ((data.tabRestore && data.tabRestore.entries) || []).map(closedItem);
                return {version: seen, windows, closed};
              };
              return {read, bump};
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

    var version: Int
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
        var kind: String
        var title: String
        var url: String

        var itemKind: CefTabStrip.ClosedItem.Kind {
            switch kind {
            case "tab": .tab
            case "window": .window
            case "group": .group
            default: .other
            }
        }
    }

    var version: Int
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
