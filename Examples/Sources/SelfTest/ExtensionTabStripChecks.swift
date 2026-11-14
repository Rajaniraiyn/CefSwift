import AppKit
import CefChromium
import CefKit

/// An extension's `chrome.tabs`, `chrome.tabGroups` and `chrome.windows`
/// and `CefTabStrip` see one tab model: what the test extension does shows
/// in the strip, and what the app does through the strip shows to the
/// extension. Runs in the `extensions` probe, which has the fixture loaded.
extension SelfTest {
    static func extensionTabStripChecks(base: URL) async {
        let strip = CefProfile.default.tabStrip
        // What an extension does to tabs reaches the strip through
        // Chromium's own events, which it listens to only when asked.
        strip.observesChromiumEvents = true
        defer { strip.observesChromiumEvents = false }
        let page = base.appendingPathComponent("page")
        let window: CefChromeWindow
        do { window = try await CefChromeWindow.open(url: page) } catch {
            return check("tab strip and extensions: opens a window", false, detail: "\(error)")
        }
        window.showsChromeUI = false
        let tabsPage = "chrome-extension://\(ExtensionFixture.id)/tabs.html"
        // The extension's page as a tab of the window, so its current
        // window is this one.
        guard let extensionTab = try? await window.openChromiumTab(URL(string: tabsPage + "?op=current")!, isActive: false),
              await waitUntil(timeout: .seconds(10), { extensionTab.browser != nil })
        else { return check("tab strip and extensions: opens the extension's page as a tab", false) }
        let other = try? await window.openChromiumTab(URL(string: page.absoluteString + "?other")!, isActive: false)
        _ = await waitUntil(timeout: .seconds(5)) { other?.browser != nil }
        func run(_ query: String) async -> String {
            guard let browser = extensionTab.browser,
                  await load(URL(string: tabsPage + "?" + query)!, in: browser) else { return "did not load" }
            _ = await waitUntil(timeout: .seconds(5)) { browser.title.hasPrefix("ok ") || browser.title.hasPrefix("error ") }
            return browser.title
        }
        guard let first = window.tabs.first, let other else {
            return check("tab strip and extensions: the window has its tabs", false, detail: "\(window.tabs.count)")
        }

        let pinned = await run("op=pin&tab=\(other.id)")
        check("tab strip and extensions: chrome.tabs.update({pinned}) shows in the strip",
              await waitUntil(timeout: .seconds(5)) { other.isPinned && other.index == 0 }, detail: pinned)
        let moved = await run("op=move&tab=\(first.id)&index=-1")
        check("tab strip and extensions: chrome.tabs.move shows in the strip",
              await waitUntil(timeout: .seconds(5)) { first.index == window.tabs.count - 1 }, detail: moved)
        let grouped = await run("op=group&tabs=\(first.id)&title=Extension&color=green")
        check("tab strip and extensions: chrome.tabs.group and chrome.tabGroups.update show in the strip",
              await waitUntil(timeout: .seconds(5)) { first.group?.title == "Extension" && first.group?.color == .green },
              detail: "\(grouped); group \(first.group.map { "\($0.title) \($0.color)" } ?? "none")")

        // The other way: the strip's commands, seen by chrome.tabs.
        try? await other.pin(false)
        let query = await run("op=query")
        check("tab strip and extensions: a pin changed through the strip shows to chrome.tabs.query",
              query.contains("[\(other.id),\(window.id),") && !query.contains("[\(other.id),\(window.id),0,false,true"),
              detail: query)
        if let group = first.group {
            try? await group.setTitle("Renamed")
            let groups = await run("op=groups")
            check("tab strip and extensions: a group renamed through Chrome's editor shows to chrome.tabGroups",
                  groups.contains("\"Renamed\""), detail: groups)
        }
        let browser = first.browser
        let windowed = await run("op=tabToWindow&tab=\(first.id)")
        check("tab strip and extensions: chrome.windows.create({tabId}) moves the tab to a window the strip lists, with its browser",
              await waitUntil(timeout: .seconds(5)) { first.window !== window && first.window != nil && first.browser === browser
                  && strip.windows.contains { $0 === first.window } },
              detail: windowed)
        await closeAll()

        // Every window closed, and gone, before the next checks.
        func closeAll() async {
            for browser in CefRuntime.shared.browsers where !CefWindow.all.contains(where: { $0.browser === browser }) {
                browser.close(force: true)
            }
            _ = await waitUntil { CefRuntime.shared.browsers.allSatisfy { b in CefWindow.all.contains { $0.browser === b } } }
            _ = await waitUntil(timeout: .seconds(5)) { strip.windows.isEmpty }
        }
    }
}
