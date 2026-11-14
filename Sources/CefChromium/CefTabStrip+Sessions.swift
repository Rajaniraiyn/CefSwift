import AppKit
import CefKit
import Foundation
import Observation

// Reopening what closed, and the previous session.
//
// Measured on CEF 156 (SelfTest probe `tabResearch`, experiments
// `restore`, `session1`/`session2`, `crash1`/`crash2`):
// - CEF runs no session restore at startup, whatever
//   `session.restore_on_startup` says, after a clean quit or a crash; it
//   shows no "Restore pages?" bubble; after a crash Chromium's tab restore
//   service lists nothing from the previous session.
// - Chromium's tab restore service is saved with the profile and read at
//   the next launch: a window closed as a window (IDC_CLOSE_WINDOW) is one
//   entry with its tabs, groups and each tab's history; a tab closed through
//   CEF is a tab entry. CefKit's quit closes every browser, so without
//   CefChromium the windows open at quit come back as loose tabs.
// - `tab_search.mojom`'s OpenRecentlyClosedEntry reopens a given entry, in
//   the window of the page that asks: a window entry as a new window, a tab
//   entry as a new tab there. Only IDC_RESTORE_TAB (the newest entry) puts
//   a tab back in its own window, at its index.

extension CefTabStrip {
    /// What the app's previous run of this profile left: how it ended, and
    /// the windows it had open then.
    public struct PreviousSession: Sendable, Hashable {
        /// How the previous run ended.
        public enum Exit: Sendable, Hashable {
            /// The app quit: its windows were closed as windows, which
            /// Chromium keeps with each tab's history.
            case clean
            /// The app ended without quitting (a crash, a kill): only the
            /// tabs' addresses, as CefChromium last saved them, are left.
            case crashed
        }

        /// A tab of the previous session.
        public struct Tab: Sendable, Hashable, Codable {
            public var url: URL
            public var title: String
            public var isPinned: Bool
        }

        public var exit: Exit
        /// When the previous run ended, or last saved its windows.
        public var endedAt: Date
        /// The windows open at the end, each with its tabs in order.
        public var windows: [[Tab]]

        /// Whether ``CefTabStrip/restorePreviousSession()`` brings back each
        /// tab's history (back and forward), groups and pinning, as
        /// Chromium closed them; otherwise each tab reopens at its address.
        public var keepsHistory: Bool { exit == .clean }
    }

    /// Reopens `item`: a window with its tabs, groups and history, a group,
    /// or a tab in its own window at its place (or, when that window has
    /// closed, in the frontmost one), with its history. Its page is a new
    /// ``CefBrowser``. Returns the window it reopened in.
    @discardableResult
    public func reopen(_ item: ClosedItem) async throws -> CefChromeWindow? {
        startFollowing()
        if item.kind == .tab, item.id == recentlyClosed.first?.id || recentlyClosed.isEmpty,
           let target = item.windowID.flatMap(window) ?? windows.first(where: \.isFocused) ?? windows.first,
           let browser = target.activeTab?.browser {
            // The newest entry: Chromium's ⌘⇧T, which puts it back exactly.
            let before = Set(allWindows.flatMap(\.tabs).map(\.id))
            browser.execute(.restoreTab)
            await nextRead(internals: true)
            return allWindows.first { $0.tabs.contains { !before.contains($0.id) } } ?? target
        }
        return try await reopenThroughTabSearch(item)
    }

    /// Asks Chromium's tab search for `item`, from a page in a window of
    /// its own kept off screen: a window entry opens a window, a tab entry
    /// a tab in that window, which then moves to where it was.
    private func reopenThroughTabSearch(_ item: ClosedItem) async throws -> CefChromeWindow? {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        let frame = CGRect(x: -20_000, y: -20_000, width: 800, height: 600)
        let (holder, browser, hider) = try await openWindow(
            url: Self.tabSearchDocument, frame: frame, configuration: configuration, delegate: nil, isTransient: true)
        defer {
            hider?.stop()
            transientBrowsers.remove(ObjectIdentifier(browser))
            browser.close(force: true)
        }
        _ = try? await browser.waitUntilLoaded(timeout: .seconds(10))
        let windowsBefore = Set(allWindows.map(\.id))
        do {
            _ = try await browser.evaluateJavaScript("""
                (async () => {
                  const m = await import('chrome://tab-search.top-chrome/tab_search.js');
                  m.TabSearchApiProxyImpl.getInstance().openRecentlyClosedEntry(\(item.id), false, \(item.kind == .tab), 0);
                  return true;
                })()
                """)
        } catch {
            throw Error.unsupported("Chromium's tab search page did not take the request: \(error)")
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            await nextRead(internals: true)
            // The holder's own tab shows `browser`; the reopened one is the other.
            if item.kind == .tab, let tab = holder.tabs.first(where: { $0.browser !== browser }) {
                let target = item.windowID.flatMap(window) ?? windows.first(where: \.isFocused) ?? windows.first
                guard let target else {
                    return try await moveToNewWindow([tab])
                }
                let index = min(item.index ?? -1, target.tabs.count)
                try await move([tab], to: index, in: target)
                try? await select(tab)
                return target
            }
            if item.kind != .tab, let made = allWindows.first(where: { !windowsBefore.contains($0.id) && $0 !== holder }) {
                return made
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Error.chromium("Chromium did not reopen the entry.")
    }

    /// The document of the page that asks tab search to reopen an entry.
    static let tabSearchDocument = URL(string: "chrome://tab-search.top-chrome/")!

    /// Opens the previous session's windows again: after a clean quit,
    /// Chromium's own records of them (each tab's history, groups and
    /// pinned tabs, as ``reopen(_:)``); after a crash, a window per window
    /// with its tabs' addresses and pinning. They reach
    /// ``onWindowOpened`` as they open. ``previousSession`` is `nil`
    /// afterwards.
    @discardableResult
    public func restorePreviousSession(
        configuration: CefBrowser.Configuration = .init(), delegate: CefBrowserDelegate? = nil
    ) async throws -> [CefChromeWindow] {
        guard let session = previousSession else { return [] }
        previousSession = nil
        var restored: [CefChromeWindow] = []
        if session.exit == .clean {
            let closed = await refreshRecentlyClosed()
            // The windows closed as the app quit: the newest window entries,
            // closed at the end of the previous run.
            let atQuit = closed.filter { $0.kind == .window && ($0.closedAt.map { $0 >= session.endedAt.addingTimeInterval(-5) } ?? false) }
            if atQuit.count == session.windows.count {
                for item in atQuit.reversed() {
                    if let window = try await reopen(item) { restored.append(window) }
                }
                return restored
            }
        }
        // By address: a crash, or Chromium's records were cleared.
        for tabs in session.windows where !tabs.isEmpty {
            var configuration = configuration
            configuration.profile = profile
            let window = try await CefChromeWindow.open(
                url: tabs[0].url, profile: profile, configuration: configuration, delegate: delegate)
            for tab in tabs.dropFirst() {
                try await window.openTab(tab.url, isActive: false, configuration: configuration, delegate: delegate)
            }
            let pinned = window.tabs.enumerated().filter { $0.offset < tabs.count && tabs[$0.offset].isPinned }.map(\.element)
            if !pinned.isEmpty { try? await pin(pinned) }
            restored.append(window)
        }
        return restored
    }

    /// Forgets the previous session, as when the app chooses not to restore
    /// it. Chromium's records of the windows stay in ``recentlyClosed``.
    public func discardPreviousSession() {
        previousSession = nil
    }

    // MARK: Saving the session

    /// Where CefChromium keeps the profile's windows between runs: a small
    /// file in the profile's directory. `nil` for an incognito profile.
    var sessionFile: URL? {
        profile.isIncognito ? nil : profile.storageDirectory?.appendingPathComponent("CefSwift Windows.json")
    }

    struct SessionRecord: Codable {
        var isRunning: Bool
        var savedAt: Date
        var windows: [[PreviousSession.Tab]]
        /// The run that saved it: a strip made again in the same run (a
        /// profile loaded anew) does not take its own run for the previous.
        var processID: Int32
    }

    /// Reads what the previous run left, then marks this run as running.
    func loadPreviousSession() {
        guard let file = sessionFile else { return }
        if let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
           !record.windows.isEmpty, record.processID != getpid() {
            previousSession = PreviousSession(
                exit: record.isRunning ? .crashed : .clean, endedAt: record.savedAt, windows: record.windows)
        }
        saveSession(isRunning: true)
        CefRuntime.shared.whenQuitStarts { [weak self] in self?.quitStarts() }
    }

    /// The windows now, and a save whenever they change: tabs, their
    /// order, pinning and addresses.
    func followSessionChanges() {
        let windows = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSave() }
        }
        _ = windows
    }

    private func snapshot() -> [[PreviousSession.Tab]] {
        windows.map { window in
            window.tabs.compactMap { tab in
                tab.url.map { PreviousSession.Tab(url: $0, title: tab.title, isPinned: tab.isPinned) }
            }
        }.filter { !$0.isEmpty }
    }

    private func scheduleSave() {
        guard !isSavingSoon, !CefRuntime.shared.isTerminating else { return }
        isSavingSoon = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.isSavingSoon = false
            self.saveSession(isRunning: true)
            self.followSessionChanges()
        }
    }

    func saveSession(isRunning: Bool, windows: [[PreviousSession.Tab]]? = nil) {
        guard let file = sessionFile else { return }
        let record = SessionRecord(isRunning: isRunning, savedAt: .now, windows: windows ?? snapshot(), processID: getpid())
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The app quits: each window closes as a window, which Chromium
    /// records with its tabs' history, and the session is saved as ended
    /// cleanly. Closing them one tab at a time (as CefKit's quit would)
    /// would leave Chromium loose tabs.
    private func quitStarts() {
        let open = snapshot()
        for window in windows {
            window.activeTab?.browser?.execute(.closeWindow)
        }
        saveSession(isRunning: false, windows: open)
    }
}
