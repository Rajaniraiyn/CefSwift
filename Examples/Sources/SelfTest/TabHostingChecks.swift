import AppKit
@_spi(Testing) import CefKit

/// How one window can show many Chrome-style tabs, measured: the facts the
/// Browser example's tab rail is built on (docs/design-notes.md, "Tabs:
/// one Chromium window per tab, one tab rail per window"). Runs in a probe
/// of its own, since a second browser view per window is not something CEF
/// supports.
extension SelfTest {
    static func tabHostingChecks() async {
        await runProbe("tabHosting", label: "tab hosting", timeout: .seconds(90))
        await attachedWindowChecks()
    }

    static func page(_ title: String) -> URL {
        URL(string: "data:text/html,<title>\(title)</title><p>\(title)")!
    }

    static func tabHostingProbe() async {
        await secondBrowserViewChecks()
        await chromiumTabModelChecks()
        await nativeTabBarChecks()
    }

    /// (a) Several Chrome-style browser views in one `cef_window_t`.
    private static func secondBrowserViewChecks() async {
        let first = CefBrowser(url: page("first"))
        let window = CefWindow(browser: first)
        window.show()
        _ = await loaded(first, title: "first")
        let second = CefBrowser(url: page("second"))
        window.addBrowserViewForTesting(second)
        let created = await waitUntil(timeout: .seconds(5)) { second.state != .pending }
        check("one window, two Chrome-style browser views: CEF leaves the second without a browser",
              !created && second.nativeView == nil, detail: "second is \(second.state)")
        let works = (try? await first.evaluateJavaScript("1 + 1").intValue) == 2
        check("one window, two Chrome-style browser views: the first browser keeps working", works)
        window.close()
        second.close(force: true)
        check("one window, two Chrome-style browser views: the window closes",
              await waitUntil { window.isClosed && first.state == .closed && second.state == .closed })
    }

    /// What Chromium's tab model makes of the app's tabs: every Chrome-style
    /// `CefWindow` is a Chromium window (`Browser`) of one tab, whether or
    /// not macOS shows the windows as one tab group; a window Chrome draws
    /// holds several.
    private static func chromiumTabModelChecks() async {
        let one = CefBrowser(url: page("one")), two = CefBrowser(url: page("two"))
        let first = CefWindow(browser: one), second = CefWindow(browser: two)
        first.show()
        second.show()
        _ = await allLoaded([one, two])
        if let a = first.window, let b = second.window {
            a.tabbingMode = .preferred
            b.tabbingMode = .preferred
            a.addTabbedWindow(b, ordered: .above)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let groupCount = first.window?.tabGroup?.windows.count ?? 0
        check("Chromium's tab model: each CefWindow is a Chromium window of one tab, in a native tab group too",
              groupCount == 2 && !one.canExecute(.selectNextTab) && !two.canExecute(.selectNextTab),
              detail: "group of \(groupCount); next tab \(one.canExecute(.selectNextTab)) \(two.canExecute(.selectNextTab))")
        first.close()
        second.close()
        _ = await waitUntil { first.isClosed && second.isClosed }

        let chrome = CefRuntime.shared.openChromeWindow(url: page("chrome"))
        _ = await loaded(chrome, title: "chrome")
        chrome.execute(.newTab)
        let twoTabs = await waitUntil(timeout: .seconds(5)) { chrome.canExecute(.selectNextTab) }
        check("Chromium's tab model: a window Chrome draws holds several tabs", twoTabs)
        for open in CefRuntime.shared.browsers { open.close(force: true) }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }

    /// (c) Native window tabbing with the system tab bar hidden.
    private static func nativeTabBarChecks() async {
        let one = CefBrowser(url: page("one")), two = CefBrowser(url: page("two"))
        var configuration = CefWindow.Configuration()
        configuration.tabbingIdentifier = "selftest-tabs"
        let first = CefWindow(browser: one, configuration: configuration)
        let second = CefWindow(browser: two, configuration: configuration)
        first.show()
        _ = await allLoaded([one, two])
        guard let a = first.window, let b = second.window else { return check("native tab bar: windows", false) }
        a.addTabbedWindow(b, ordered: .above)
        b.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let shownBefore = a.tabGroup?.isTabBarVisible == true
        b.toggleTabBar(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let shownAfter = a.tabGroup?.isTabBarVisible == true
        print("NOTE native tab bar: shown with two tabs \(shownBefore), after toggleTabBar \(shownAfter)")
        check("native tab bar: macOS keeps the tab bar of a group of two tabs shown", shownBefore && shownAfter)
        first.close()
        second.close()
        _ = await waitUntil { first.isClosed && second.isClosed }
    }

}
