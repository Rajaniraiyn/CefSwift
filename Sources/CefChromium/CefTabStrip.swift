import AppKit
import CefKit
import Foundation
import Observation

/// Chromium's own tabs, windows and tab groups for one ``CefProfile``: the
/// tab strips of the windows Chrome draws
/// (``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)``),
/// mirrored, and driven through Chromium.
///
/// It is the model a custom tab interface draws: Chromium stays the source
/// of truth, so what extensions do with `chrome.tabs` and what Chrome's own
/// commands do show up here by themselves, and every change made here is
/// one Chromium makes — moving a tab to another window keeps its page,
/// history and ``CefBrowser``.
///
/// ```swift
/// let strip = CefProfile.default.tabStrip
/// Task { await strip.follow() }            // keeps `windows` up to date
/// for window in strip.windows {
///     for tab in window.tabs { print(tab.title, tab.isPinned, tab.group as Any) }
/// }
/// try await strip.pin(tab)
/// try await strip.group([first, second])
/// try await strip.move(tab, to: 0, in: otherWindow)
/// ```
///
/// The mirror reads `chrome://tab-strip-internals`
/// (`tab_strip_internals.mojom`), which reports every window's tab strip
/// and each change to it; changes go through the documented `chrome.tabs`
/// and `chrome.windows` extension APIs, which Chromium grants its own
/// `chrome://bookmarks` page. Both are reached from hidden service hosts.
/// Windows CefKit hosts (``CefWindow``, one tab each, which Chromium counts
/// as popup windows) are left out. Group names, colours and collapsing are
/// read but cannot be changed: Chromium grants `chrome.tabGroups` to
/// extensions only.
@MainActor
@Observable
public final class CefTabStrip {
    /// One of Chromium's tabbed windows.
    public struct Window: Identifiable, Hashable, Sendable {
        /// Chromium's window identifier (`chrome.windows` ids).
        public struct ID: Hashable, Sendable, CustomStringConvertible {
            let rawValue: Int
            public var description: String { String(rawValue) }
        }

        public var id: ID
        /// The tabs, in the strip's order: pinned ones first.
        public var tabs: [Tab]
        /// The window's tab groups, in the strip's order.
        public var groups: [Group]

        /// The tab shown.
        public var activeTab: Tab? { tabs.first(where: \.isActive) }
    }

    /// A tab in one of Chromium's windows.
    public struct Tab: Identifiable, Hashable, Sendable {
        /// Identifies a tab for as long as it exists, across moves between
        /// windows.
        public struct ID: Hashable, Sendable, CustomStringConvertible {
            let rawValue: String
            public var description: String { rawValue }
        }

        /// What a tab can be doing that its tab shows, Chrome's tab alert
        /// states.
        public enum Alert: Hashable, Sendable {
            case playingAudio, muted, recording, capturing, bluetooth, usb, serial, hid, vr, pictureInPicture
            /// A state this version of CefChromium does not know.
            case other(String)
        }

        public var id: ID
        public var window: Window.ID
        /// The position in its window's strip.
        public var index: Int
        public var title: String
        public var url: URL?
        public var isActive: Bool
        public var isPinned: Bool
        /// The group the tab is in.
        public var group: Group.ID?
        public var alerts: [Alert]
    }

    /// A tab group.
    public struct Group: Identifiable, Hashable, Sendable {
        public struct ID: Hashable, Sendable, CustomStringConvertible {
            let rawValue: String
            public var description: String { rawValue }
        }

        /// Chrome's tab group colours.
        public enum Color: Int, CaseIterable, Sendable {
            case grey, blue, red, yellow, green, pink, purple, cyan, orange
        }

        public var id: ID
        public var title: String
        public var color: Color
        public var isCollapsed: Bool
        /// Its tabs, in order.
        public var tabs: [Tab.ID]
    }

    /// Chromium's tabbed windows of the profile, as last reported. Empty
    /// until the first ``refresh()`` or ``follow()``.
    public private(set) var windows: [Window] = []

    /// Why the last read failed — the internal page moved or changed in a
    /// Chromium update — or `nil`.
    public private(set) var lastError: String?

    private let profile: CefProfile

    init(profile: CefProfile) {
        self.profile = profile
    }

    private var services: CefServiceHosts { profile.serviceHosts }

    /// The tab with `id`, in any window.
    public func tab(_ id: Tab.ID) -> Tab? {
        for window in windows { if let tab = window.tabs.first(where: { $0.id == id }) { return tab } }
        return nil
    }

    /// The window with `id`.
    public func window(_ id: Window.ID) -> Window? {
        windows.first { $0.id == id }
    }

    // MARK: Reading

    /// Reads the tab strips once.
    public func refresh() async throws {
        apply(try await snapshot(after: nil))
    }

    /// Keeps ``windows`` up to date until the calling task is cancelled,
    /// reading again each time Chromium reports a change to a tab strip.
    /// A failed read is in ``lastError``; following carries on.
    public func follow() async {
        var version: Int?
        while !Task.isCancelled {
            do {
                let next = try await snapshot(after: version)
                version = next.version
                apply(next)
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = "\(error)"
                version = nil
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func snapshot(after version: Int?) async throws -> Snapshot {
        // The profile's tabbed windows first: the internal page reports
        // every profile's, and every window, CefKit's own included.
        let normal = try await services.call(
            Self.commands, "async s => (await s.w.getAll()).filter(w => w.type == 'normal').map(w => w.id)",
            as: [Int].self, isIdempotent: true)
        var arguments: [String: CefJSON] = [:]
        if let version { arguments["since"] = .number(Double(version)) }
        var snapshot = try await services.call(
            Self.internals, "(s, a, context) => s.read(a.since, context.signal)", .object(arguments),
            as: Snapshot.self, timeout: .seconds(40), isIdempotent: true)
        let kept = Set(normal)
        snapshot.windows = snapshot.windows.filter { Int($0.id).map(kept.contains) ?? false }
        return snapshot
    }

    private func apply(_ snapshot: Snapshot) {
        let windows = snapshot.windows.compactMap { $0.window }
        if windows != self.windows { self.windows = windows }
    }

    // MARK: Browsers

    /// The browser showing `tab`, matched by its window and address; `nil`
    /// while CefKit has not seen it.
    ///
    /// Chromium's tab identifiers are not visible to CEF, so a tab is
    /// matched with the browsers in its window by address, and tabs of the
    /// same address in creation order.
    public func browser(for tab: Tab) -> CefBrowser? {
        guard let window = window(tab.window) else { return nil }
        let nsWindow = nativeWindow(for: window)
        let hosted = Set(CefWindow.all.map { ObjectIdentifier($0.browser) })
        // A tab in the background has its page out of the window.
        let browsers = CefRuntime.shared.browsers
            .filter { browser in
                guard browser.state == .live, !hosted.contains(ObjectIdentifier(browser)) else { return false }
                let shown = browser.nativeView?.window
                return shown == nil || shown === nsWindow
            }
            .sorted { $0.identifier < $1.identifier }
        var unmatched = browsers
        var matches: [Tab.ID: CefBrowser] = [:]
        // Tabs by address, in creation order (tab identifiers count up).
        let tabs = window.tabs.sorted { (Int($0.id.rawValue) ?? 0) < (Int($1.id.rawValue) ?? 0) }
        for candidate in tabs {
            if let index = unmatched.firstIndex(where: { $0.url == candidate.url || $0.url?.absoluteString == candidate.url?.absoluteString }) {
                matches[candidate.id] = unmatched.remove(at: index)
            }
        }
        return matches[tab.id]
    }

    /// The tab `browser` shows, if it is one of Chromium's tabbed windows'.
    public func tab(for browser: CefBrowser) -> Tab? {
        for window in windows {
            for tab in window.tabs where self.browser(for: tab) === browser { return tab }
        }
        return nil
    }

    /// The `NSWindow` Chromium shows `window` in.
    public func nativeWindow(for window: Window) -> NSWindow? {
        for tab in window.tabs {
            for browser in CefRuntime.shared.browsers where browser.url == tab.url {
                if let nsWindow = browser.nativeView?.window, CefWindow.all.allSatisfy({ $0.window !== nsWindow }) {
                    return nsWindow
                }
            }
        }
        return nil
    }

    // MARK: Changing

    /// Shows `tab` in its window.
    public func select(_ tab: Tab) async throws {
        try await change(tab, "await s.t.update(tab.id, {active: true})")
    }

    /// Moves `tab` to `index` in `window`, by default its own. A move to
    /// another window is Chromium's: the tab keeps its page and history.
    public func move(_ tab: Tab, to index: Int, in window: Window.ID? = nil) async throws {
        try await change(
            tab, "await s.t.move(tab.id, {windowId: a.to, index: a.at})",
            ["to": .number(Double((window ?? tab.window).rawValue)), "at": .number(Double(index))])
    }

    /// Pins or unpins `tab`.
    public func pin(_ tab: Tab, _ isPinned: Bool = true) async throws {
        try await change(tab, "await s.t.update(tab.id, {pinned: a.pinned})", ["pinned": .bool(isPinned)])
    }

    /// Puts `tabs` in `group`, or in a new group of their first tab's
    /// window. Returns the group.
    @discardableResult
    public func group(_ tabs: [Tab], into group: Group.ID? = nil) async throws -> Group.ID? {
        guard let first = tabs.first else { return group }
        var arguments: [String: CefJSON] = [
            "tabs": .array(tabs.map { .object(["window": .number(Double($0.window.rawValue)), "index": .number(Double($0.index)),
                                               "url": .string($0.url?.absoluteString ?? "")]) }),
            "window": .number(Double(first.window.rawValue)),
        ]
        if let group, let member = windows.flatMap(\.tabs).first(where: { $0.group == group }) {
            arguments["member"] = .object(["window": .number(Double(member.window.rawValue)), "index": .number(Double(member.index)),
                                           "url": .string(member.url?.absoluteString ?? "")])
        }
        _ = try await services.call(Self.commands, """
            async (s, a) => {
              const ids = [];
              for (const t of a.tabs) ids.push((await s.tabAt(t)).id);
              const options = {tabIds: ids};
              if (a.member) options.groupId = (await s.tabAt(a.member)).groupId;
              else options.createProperties = {windowId: a.window};
              return await s.t.group(options);
            }
            """, .object(arguments), as: Int.self)
        try await refresh()
        return self.tab(first.id)?.group
    }

    /// Takes `tabs` out of their groups.
    public func ungroup(_ tabs: [Tab]) async throws {
        for tab in tabs { try await change(tab, "await s.t.ungroup(tab.id)", refresh: false) }
        try await refresh()
    }

    /// Opens a copy of `tab` beside it, with its history.
    public func duplicate(_ tab: Tab) async throws {
        try await change(tab, "await s.t.duplicate(tab.id)")
    }

    /// Moves `tab` to a new window of its own, keeping its page.
    public func moveToNewWindow(_ tab: Tab) async throws {
        try await change(tab, "await s.w.create({tabId: tab.id, focused: true})")
    }

    /// Opens `url` in a new tab of `window`, at `index` or the end.
    public func newTab(_ url: URL, in window: Window.ID, at index: Int? = nil, isActive: Bool = true) async throws {
        var properties: [String: CefJSON] = [
            "windowId": .number(Double(window.rawValue)), "url": .string(url.absoluteString), "active": .bool(isActive),
        ]
        if let index { properties["index"] = .number(Double(index)) }
        _ = try await services.call(Self.commands, "async (s, a) => (await s.t.create(a)).id", .object(properties), as: Int.self)
        try await refresh()
    }

    /// Closes `tab` as its close button would; its page's `beforeunload`
    /// handler may keep it open.
    ///
    /// The tab is closed through CEF (``CefBrowser/close(force:)``):
    /// closing it through `chrome.tabs` ended the browser process on CEF 156.
    public func close(_ tab: Tab) {
        browser(for: tab)?.close()
    }

    /// Opens the tab or window closed last in the profile again, with its
    /// history and group, as ⌘⇧T does in Chrome.
    public func reopenClosedTab(in window: Window) {
        guard let browser = window.tabs.lazy.compactMap({ self.browser(for: $0) }).first else { return }
        browser.execute(.restoreTab)
    }

    /// Runs `body` with `tab` as `chrome.tabs` sees it, then reads again.
    private func change(_ tab: Tab, _ body: String, _ arguments: [String: CefJSON] = [:], refresh: Bool = true) async throws {
        var arguments = arguments
        arguments["tab"] = .object(["window": .number(Double(tab.window.rawValue)), "index": .number(Double(tab.index)),
                                    "url": .string(tab.url?.absoluteString ?? "")])
        _ = try await services.call(
            Self.commands, "async (s, a) => { const tab = await s.tabAt(a.tab); \(body); return true; }",
            .object(arguments), as: Bool.self)
        if refresh { try await self.refresh() }
    }

    // MARK: Plumbing

    /// `chrome.tabs` and `chrome.windows` on the bookmarks host. A tab is
    /// named by its window, position and address, as the mirror last saw
    /// it; a tab that has moved since is refused rather than mistaken.
    static let commands = CefServiceHost.Module(
        name: "tabs", hosts: [.bookmarks],
        setup: """
            async emit => {
              const t = chrome.tabs, w = chrome.windows;
              if (!t || !w) throw new Error('chrome.tabs is not available on this page');
              const tabAt = async ({window, index, url}) => {
                const [tab] = await t.query({windowId: window, index});
                if (!tab) throw new Error('the tab is no longer there');
                if (url && tab.url !== url && tab.pendingUrl !== url) throw new Error('the tab has moved');
                return tab;
              };
              return {t, w, tabAt};
            }
            """)

    /// `tab_strip_internals.mojom`: the snapshot of every tab strip, and a
    /// version counted up at each change it reports, so a read can wait for
    /// the next one.
    static let internals = CefServiceHost.Module(
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
              router.onTabStripUpdated.addListener(() => { version++; for (const w of waiters.splice(0)) w(); });
              const text = s => typeof s == 'string' ? s : (s && s.data ? String.fromCharCode(...s.data) : '');
              const url = u => typeof u == 'string' ? u : (u && u.url) || '';
              const flatten = (node, out, group) => {
                const d = node.data, kind = Object.keys(d).find(k => d[k] != null), v = d[kind];
                if (kind == 'tab') {
                  out.tabs.push({id: v.id.nodeId, title: text(v.title), url: url(v.url), active: !!v.active,
                                 pinned: !!v.pinned, group, alerts: (v.alertStates || []).map(a => alertNames[a] || String(a))});
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
              const read = async (since, signal) => {
                if (since != null && since == version) {
                  await new Promise(resolve => {
                    waiters.push(resolve);
                    signal.addEventListener('abort', resolve);
                    setTimeout(resolve, 1500);
                  });
                }
                const seen = version;
                const {data} = await handler.getTabStripData();
                const windows = data.tabstripTree.windows.map(w => {
                  const out = {id: w.id.nodeId, tabs: [], groups: []};
                  if (w.tabstripModel.root) flatten(w.tabstripModel.root, out, null);
                  return out;
                });
                return {version: seen, windows};
              };
              return {read};
            }
            """)
}

/// What the internal page reports.
private struct Snapshot: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        struct Tab: Decodable, Sendable {
            var id: String
            var title: String
            var url: String
            var active: Bool
            var pinned: Bool
            var group: String?
            var alerts: [String]
        }

        struct Group: Decodable, Sendable {
            var id: String
            var title: String
            var color: Int
            var collapsed: Bool
        }

        var id: String
        var tabs: [Tab]
        var groups: [Group]

        var window: CefTabStrip.Window? {
            guard let number = Int(id) else { return nil }
            let windowID = CefTabStrip.Window.ID(rawValue: number)
            let tabs = tabs.enumerated().map { index, tab in
                CefTabStrip.Tab(
                    id: .init(rawValue: tab.id), window: windowID, index: index, title: tab.title,
                    url: URL(string: tab.url), isActive: tab.active, isPinned: tab.pinned,
                    group: tab.group.map(CefTabStrip.Group.ID.init(rawValue:)),
                    alerts: tab.alerts.map(CefTabStrip.Tab.Alert.init(name:)))
            }
            let groups = groups.map { group in
                CefTabStrip.Group(
                    id: .init(rawValue: group.id), title: group.title,
                    color: CefTabStrip.Group.Color(rawValue: group.color) ?? .grey, isCollapsed: group.collapsed,
                    tabs: tabs.filter { $0.group?.rawValue == group.id }.map(\.id))
            }
            return CefTabStrip.Window(id: windowID, tabs: tabs, groups: groups)
        }
    }

    var version: Int
    var windows: [Window]
}

extension CefTabStrip.Tab.Alert {
    /// From `tabs.mojom.TabAlertState`'s names.
    init(name: String) {
        switch name {
        case "kAudioPlaying": self = .playingAudio
        case "kAudioMuting": self = .muted
        case "kMediaRecording", "kAudioRecording", "kVideoRecording": self = .recording
        case "kTabCapturing", "kDesktopCapturing": self = .capturing
        case "kBluetoothConnected", "kBluetoothScanActive": self = .bluetooth
        case "kUsbConnected": self = .usb
        case "kSerialConnected": self = .serial
        case "kHidConnected": self = .hid
        case "kVrPresentingInHeadset": self = .vr
        case "kPipPlaying": self = .pictureInPicture
        default: self = .other(name)
        }
    }
}

extension CefServiceHost {
    /// `tab_strip_internals.mojom.PageHandlerFactory`.
    static let tabStripInternals = CefServiceHost(
        name: "tab-strip-internals", document: "chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js",
        isAvailableInIncognito: false)
}

extension CefProfile {
    /// Chromium's tabbed windows of this profile, their tabs and groups.
    /// Hold on to it while you show it: the profile keeps it only while it
    /// is in use.
    public var tabStrip: CefTabStrip {
        let stores = chromiumStores
        if let tabStrip = stores.tabStrip { return tabStrip }
        let made = CefTabStrip(profile: self)
        stores.tabStrip = made
        return made
    }
}
