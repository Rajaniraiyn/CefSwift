import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit

/// The hosts behind bookmarks, history, most-visited and autocomplete: one
/// renderer each, started on demand, closed when idle, restarted after a
/// crash; and bookmark reads and change events that need no host.
extension SelfTest {
    static func serviceHostChecks() async {
        let profile = CefProfile.default
        let idleTimeout = CefProfile.serviceIdleTimeout
        CefProfile.serviceIdleTimeout = .seconds(3)
        defer { CefProfile.serviceIdleTimeout = idleTimeout }

        // File reads need a saved Bookmarks file, which a new profile does
        // not have: make a change and wait for Chromium to save it, which
        // it does while the app shows a page.
        let saved = await withVisiblePage {
            if let made = try? await profile.bookmarks.addFolder("CefSwift Service Host Probe") {
                try? await profile.bookmarks.remove(made.id)
            }
            return await waitUntil(timeout: .seconds(10)) { !profile.bookmarks.hasUnsavedChanges }
        }
        if !saved { print("     Chromium did not save the Bookmarks file") }

        profile.stopServiceHosts()
        _ = await waitUntil { profile.runningServiceHosts.isEmpty }
        // Closed renderers take a moment to exit.
        _ = await waitUntil(timeout: .seconds(5)) { rendererCount() == 0 }
        let before = rendererCount()

        var hostsAfterReading: [String] = []
        await expect("service hosts: bookmark reads need no host while it is closed") {
            let tree = try await profile.bookmarks.tree()
            _ = try await profile.bookmarks.recent(limit: 3)
            hostsAfterReading = profile.runningServiceHosts
            return tree.contains { $0.permanentFolder == .bookmarksBar } && hostsAfterReading.isEmpty
        }
        if !hostsAfterReading.isEmpty { print("     hosts after reading: \(hostsAfterReading)") }

        // The deadline covers starting the host: a call shorter than the
        // start-up fails at its deadline instead of waiting for the host.
        var deadlineCall = Duration.zero
        var deadlineError = ""
        do {
            let start = ContinuousClock.now
            defer { deadlineCall = ContinuousClock.now - start }
            try await profile.pingHistoryService(timeout: .milliseconds(5))
        } catch {
            deadlineError = "\(error)"
        }
        check("service hosts: a call's deadline includes starting its host",
              deadlineError.contains("no answer") && deadlineCall < .milliseconds(500),
              detail: "\(deadlineCall), \(deadlineError.isEmpty ? "answered" : deadlineError)")
        _ = await waitUntil { profile.runningServiceHosts.isEmpty }

        var elapsed = Duration.zero
        await expect("service hosts: a call starts its host quickly") {
            let start = ContinuousClock.now
            _ = try await profile.history.search(limit: 1)
            elapsed = ContinuousClock.now - start
            // Usually 0.2 s; a Mac busy with a build has taken 2.2 s.
            return elapsed < .seconds(5)
        }
        print("     first history call: \(elapsed)")

        await expect("service hosts: calls across services run concurrently") {
            async let search = profile.bookmarks.search("CefSwift")
            async let visits = profile.history.search(limit: 5)
            async let tiles = profile.history.topSites()
            async let suggestions = profile.autocomplete.suggestions(for: "selftest")
            // An image is not `Sendable`, so its call stays on the main actor.
            let icon = Task { @MainActor in
                try await profile.history.favicon(for: URL(string: "selftest://edge/favicon.html")!) != nil
            }
            _ = try await (search, visits, tiles, suggestions)
            _ = try await icon.value
            return true
        }
        let hostBrowsers = CefRuntime.shared.openServiceBrowsers
        check("service hosts: no host attaches a DevTools session",
              !hostBrowsers.isEmpty && hostBrowsers.allSatisfy { !$0.devTools.isAttached && $0.devTools.sentMessageCount == 0 },
              detail: hostBrowsers.map { "\($0.url?.absoluteString ?? "?"): attached \($0.devTools.isAttached), " +
                  "\($0.devTools.sentMessageCount) sent" }.joined(separator: "; "))
        let running = profile.runningServiceHosts
        check("service hosts: one per WebUI host", running == ["bookmarks", "history", "most-visited", "omnibox"],
              detail: "\(running)")
        check("service hosts: one renderer each", await waitUntil(timeout: .seconds(5)) {
            rendererCount() == before + running.count
        }, detail: "\(rendererCount()) renderers, \(before) before")

        check("service hosts: close when idle", await waitUntil(timeout: .seconds(10)) {
            profile.runningServiceHosts.isEmpty
        }, detail: "\(profile.runningServiceHosts)")
        check("service hosts: their renderers exit", await waitUntil(timeout: .seconds(10)) { rendererCount() == before },
              detail: "\(rendererCount()) renderers, \(before) before")
        await expect("service hosts: start again on the next call") {
            try await !profile.autocomplete.suggestions(for: "selftest").isEmpty
                && profile.runningServiceHosts == ["omnibox"]
        }

        _ = try? await profile.history.search(limit: 1)
        await profile.crashServiceHost(named: "history")
        check("service hosts: a crashed host is dropped", await waitUntil(timeout: .seconds(10)) {
            !profile.runningServiceHosts.contains("history")
        }, detail: "\(profile.runningServiceHosts)")
        await expect("service hosts: the next call after a crash starts a new host") {
            _ = try await profile.history.search(limit: 1)
            return profile.runningServiceHosts.contains("history")
        }

        await bookmarkFileWatchCheck(profile)
        profile.stopServiceHosts()
    }

    /// A change made outside CefKit's service host — here from a page of
    /// the app's own that uses `chrome.bookmarks`, as Chrome's bookmark
    /// manager does — reaches `changes` through Chromium's Bookmarks file.
    private static func bookmarkFileWatchCheck(_ profile: CefProfile) async {
        profile.stopServiceHosts()
        _ = await waitUntil { profile.runningServiceHosts.isEmpty }
        var changes = 0
        let watcher = Task { for await _ in profile.bookmarks.changes { changes += 1 } }
        defer { watcher.cancel() }
        let manager = CefWindow(browser: CefBrowser(url: URL(string: "chrome://bookmarks/strings.m.js")!))
        _ = await loaded(manager.browser)
        try? await Task.sleep(for: .milliseconds(500))
        let created = try? await manager.browser.evaluateJavaScript(
            "chrome.bookmarks.create({ title: 'CefSwift Watched', url: 'https://selftest.invalid/watched' }).then(b => b.id)")
        check("bookmarks: a change made elsewhere arrives through the file, with no host",
              await waitUntil(timeout: .seconds(8)) { changes > 0 } && profile.runningServiceHosts.isEmpty,
              detail: "\(changes) changes, created \(String(describing: created)), \(profile.runningServiceHosts)")
        await expect("bookmarks: the file shows it") {
            try await profile.bookmarks.recent(limit: 1).first?.title == "CefSwift Watched"
        }
        if let id = created?.stringValue {
            _ = try? await manager.browser.evaluateJavaScript("chrome.bookmarks.remove('\(id)').then(() => true)")
        }
        manager.close()
        _ = await waitUntil { manager.isClosed }
    }

    /// The renderer processes this app has running.
    static func rendererCount() -> Int { rendererProcesses().count }
}
