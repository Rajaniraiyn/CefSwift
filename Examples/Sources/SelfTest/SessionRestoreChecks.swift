import AppKit
import CefChromium
import CefKit

/// Reopening what closed (`CefTabStrip.reopen`), and the previous session
/// after a clean quit and after a crash (`previousSession`,
/// `restorePreviousSession`), the last two in two launches of a probe.
extension SelfTest {
    static let sessionProbePhaseKey = "CEFSWIFT_SELFTEST_SESSION_PHASE"

    static func sessionRestoreChecks() async {
        let strip = CefProfile.default.tabStrip
        func url(_ name: String) -> URL { URL(string: "chrome://version/?\(name)")! }
        func names(_ window: CefChromeWindow?) -> [String] { window?.tabs.map { $0.url?.query ?? "-" } ?? [] }
        check("session: no previous session on a first launch", strip.previousSession == nil,
              detail: "\(String(describing: strip.previousSession))")
        let one: CefChromeWindow, two: CefChromeWindow
        do {
            one = try await CefChromeWindow.open(url: url("a"))
            let b = try await one.openTab(url("b"))
            _ = try? await b.browser?.waitUntilLoaded(timeout: .seconds(10))
            b.browser?.load(url("b2"))
            _ = await waitUntil(timeout: .seconds(5)) { b.browser?.canGoBack == true && b.url == url("b2") }
            try await one.openTab(url("c"))
            two = try await CefChromeWindow.open(url: url("w2a"))
            try await two.openTab(url("w2b"))
        } catch {
            check("session: opens windows", false, detail: "\(error)")
            return closeAllBrowsers()
        }
        // Close a tab, then a whole window: the tab is no longer the newest.
        let bBrowser = one.tabs.first { $0.url == url("b2") }?.browser
        one.tabs.first { $0.url == url("b2") }?.close()
        _ = await waitUntil(timeout: .seconds(5)) { !names(one).contains("b2") }
        two.activeTab?.browser?.execute(.closeWindow)
        _ = await waitUntil(timeout: .seconds(5)) { two.isClosed }
        let closed = await strip.refreshRecentlyClosed()
        check("session: a window closed as a window is one entry with its tabs; a tab, an entry with its place",
              closed.first?.kind == .window && closed.first?.tabCount == 2
                && closed.dropFirst().first.map { $0.kind == .tab && $0.windowID == one.id && $0.index == 1 } == true,
              detail: "\(closed.prefix(3).map { "\($0.kind) \($0.tabCount) \($0.windowID?.description ?? "-") \($0.index ?? -1)" })")

        if let tabItem = closed.first(where: { $0.kind == .tab }) {
            await expect("session: reopens a given tab, not the newest entry, in its window at its place, with its history") {
                let window = try await strip.reopen(tabItem)
                let reopened = await waitUntil(timeout: .seconds(5)) { one.tabs.contains { $0.url == url("b2") && $0.browser != nil } }
                let tab = one.tabs.first { $0.url == url("b2") }
                _ = await waitUntil(timeout: .seconds(5)) { tab?.browser?.canGoBack == true }
                return (reopened && window === one && tab?.index == 1 && tab?.browser?.canGoBack == true && tab?.browser !== bBrowser,
                        "\(names(one)) in \(window?.id.description ?? "-") index \(tab?.index ?? -1) back \(tab?.browser?.canGoBack ?? false)")
            }
        }
        if let windowItem = closed.first(where: { $0.kind == .window }) {
            await expect("session: reopens a given window with all its tabs") {
                let window = try await strip.reopen(windowItem)
                let shown = await waitUntil(timeout: .seconds(5)) { names(window) == ["w2a", "w2b"] && window?.window != nil }
                return (shown, "\(names(window))")
            }
        }
        check("session: the window that reopened entries from is gone",
              await waitUntil(timeout: .seconds(5)) { strip.windows.count == 2 && strip.windows.allSatisfy { !$0.tabs.isEmpty } },
              detail: "\(strip.windows.map(names))")
        for window in strip.windows { window.close() }
        _ = await waitUntil(timeout: .seconds(10)) { CefRuntime.shared.browsers.isEmpty }

        // The previous session, in two launches sharing a profile.
        for mode in ["clean", "crash"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-session-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            await runProbe("sessionRestore", label: "session (\(mode), first launch)", root: root,
                           environment: [sessionProbePhaseKey: "\(mode)-first"], timeout: .seconds(60))
            await runProbe("sessionRestore", label: "session (\(mode), relaunch)", root: root,
                           environment: [sessionProbePhaseKey: "\(mode)-second"], timeout: .seconds(60))
        }
        closeAllBrowsers()
    }

    /// One launch of the previous-session probe.
    static func sessionRestoreProbe() async {
        let phase = ProcessInfo.processInfo.environment[sessionProbePhaseKey] ?? ""
        let strip = CefProfile.default.tabStrip
        func url(_ name: String) -> URL { URL(string: "chrome://version/?\(name)")! }
        if phase.hasSuffix("first") {
            do {
                let one = try await CefChromeWindow.open(url: url("s1a"))
                let b = try await one.openTab(url("s1b"))
                _ = try? await b.browser?.waitUntilLoaded(timeout: .seconds(10))
                b.browser?.load(url("s1b2"))
                _ = await waitUntil(timeout: .seconds(5)) { b.url == url("s1b2") }
                try await b.pin()
                let two = try await CefChromeWindow.open(url: url("s2a"))
                try await two.openTab(url("s2b"))
            } catch {
                return check("previous session: opens windows", false, detail: "\(error)")
            }
            // The session file follows changes a second later.
            try? await Task.sleep(for: .seconds(2))
            check("previous session: the first launch has two windows", strip.windows.count == 2)
            if phase == "crash-first" {
                // Ends without quitting, as a crash would.
                fflush(stdout)
                _exit(0)
            }
            // Returning quits through NSApp.terminate with the windows open.
            return
        }
        guard let session = strip.previousSession else {
            return check("previous session: is reported after a relaunch", false)
        }
        let expectedExit: CefTabStrip.PreviousSession.Exit = phase.hasPrefix("clean") ? .clean : .crashed
        check("previous session: reports how the last run ended (\(expectedExit)) and its windows",
              session.exit == expectedExit && session.windows.count == 2
                && session.windows.map { $0.map { $0.url.query ?? "-" } }.sorted { $0.first ?? "" < $1.first ?? "" }
                    == [["s1b2", "s1a"], ["s2a", "s2b"]],
              detail: "\(session.exit) \(session.windows.map { $0.map { "\($0.url.query ?? "-")\($0.isPinned ? "(pinned)" : "")" } })")
        var announced = 0
        strip.onWindowOpened = { _ in announced += 1 }
        do {
            let windows = try await strip.restorePreviousSession()
            _ = await waitUntil(timeout: .seconds(10)) { strip.windows.count == 2 && strip.windows.allSatisfy { $0.window != nil } }
            let layout = strip.windows.map { $0.tabs.map { "\($0.url?.query ?? "-")\($0.isPinned ? "(pinned)" : "")" } }
            let b = strip.windows.flatMap(\.tabs).first { $0.url == url("s1b2") }
            _ = await waitUntil(timeout: .seconds(5)) { b?.browser?.canGoBack == true }
            let history = b?.browser?.canGoBack == true
            check("previous session: restores its windows, announced, with \(session.keepsHistory ? "history and pinned tabs" : "addresses and pinned tabs")",
                  windows.count == 2 && strip.windows.count == 2 && announced >= 2 && b?.isPinned == true
                    && history == session.keepsHistory && strip.previousSession == nil,
                  detail: "\(layout) announced \(announced) history \(history)")
        } catch {
            check("previous session: restores its windows", false, detail: "\(error)")
        }
        for window in strip.windows { window.close() }
        _ = await waitUntil(timeout: .seconds(10)) { CefRuntime.shared.browsers.isEmpty }
    }

    private static func closeAllBrowsers() {
        for browser in CefRuntime.shared.browsers { browser.close(force: true) }
    }
}
