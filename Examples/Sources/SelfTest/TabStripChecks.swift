import AppKit
import CefChromium
import CefKit

/// `CefTabStrip`: Chromium's own tabbed windows, mirrored and driven.
extension SelfTest {
    static func tabStripChecks() async {
        let strip = CefProfile.default.tabStrip
        let following = Task { await strip.follow() }
        defer { following.cancel() }
        func url(_ name: String) -> URL { URL(string: "chrome://version/?\(name)")! }
        func tabs() -> [CefTabStrip.Tab] { strip.windows.flatMap(\.tabs) }
        func tab(_ name: String) -> CefTabStrip.Tab? { tabs().first { $0.url == url(name) } }

        let first = CefRuntime.shared.openChromeWindow(url: url("a"))
        _ = await loaded(first)
        let seen = await waitUntil(timeout: .seconds(10)) { tab("a") != nil }
        check("tab strip: mirrors a window Chrome draws", seen && strip.lastError == nil,
              detail: strip.lastError ?? "\(strip.windows.map { $0.tabs.map(\.url) })")
        guard seen, let window = tab("a")?.window else { return closeAll() }

        do {
            try await strip.newTab(url("b"), in: window)
            try await strip.newTab(url("c"), in: window, isActive: false)
        } catch { check("tab strip: opens tabs", false, detail: "\(error)") }
        let opened = await waitUntil(timeout: .seconds(10)) {
            strip.window(window)?.tabs.map(\.url) == [url("a"), url("b"), url("c")].map(Optional.some)
        }
        check("tab strip: opens tabs in the window, in order", opened, detail: "\(strip.window(window)?.tabs.map(\.url) ?? [])")
        _ = await waitUntil(timeout: .seconds(5)) { ["a", "b", "c"].allSatisfy { tab($0).flatMap(strip.browser(for:)) != nil } }
        let browsers = ["a", "b", "c"].compactMap { tab($0).flatMap(strip.browser(for:)) }
        check("tab strip: each tab is a CefBrowser of its own", browsers.count == 3 && Set(browsers.map(ObjectIdentifier.init)).count == 3
              && browsers.first === first, detail: "\(browsers.map { $0.url?.absoluteString ?? "-" })")

        await expect("tab strip: pins a tab, which moves to the front") {
            guard let c = tab("c") else { return false }
            try await strip.pin(c)
            return await waitUntil(timeout: .seconds(5)) { tab("c")?.isPinned == true && tab("c")?.index == 0 }
        }
        await expect("tab strip: groups tabs, and reads the group back") {
            guard let a = tab("a"), let b = tab("b") else { return false }
            let group = try await strip.group([a, b])
            return await waitUntil(timeout: .seconds(5)) {
                group != nil && tab("a")?.group == group && tab("b")?.group == group
                    && strip.window(window)?.groups.first?.tabs == [a.id, b.id]
            }
        }
        await expect("tab strip: ungroups") {
            guard let b = tab("b") else { return false }
            try await strip.ungroup([b])
            return await waitUntil(timeout: .seconds(5)) { tab("b")?.group == nil && tab("a")?.group != nil }
        }
        await expect("tab strip: selects a tab") {
            guard let a = tab("a") else { return false }
            try await strip.select(a)
            return await waitUntil(timeout: .seconds(5)) { tab("a")?.isActive == true && tab("b")?.isActive == false }
        }
        // A change made by Chromium itself shows up while following.
        let count = strip.window(window)?.tabs.count ?? 0
        first.execute(.newTab)
        check("tab strip: follows a change Chromium makes (Chrome's New Tab command)",
              await waitUntil(timeout: .seconds(5)) { (strip.window(window)?.tabs.count ?? 0) == count + 1 },
              detail: "can pin \(first.canExecute(.pinTab)); \(tabs().map { "\($0.url?.query ?? "-") pinned \($0.isPinned) active \($0.isActive) browser \(strip.browser(for: $0)?.identifier ?? -1)" }), error \(strip.lastError ?? "none")")

        let other = CefRuntime.shared.openChromeWindow(url: url("z"))
        _ = await loaded(other)
        _ = await waitUntil(timeout: .seconds(5)) { tab("z") != nil }
        let before = tab("b").flatMap(strip.browser(for:))
        var moveError = ""
        if let b = tab("b"), let target = tab("z")?.window {
            do { try await strip.move(b, to: 1, in: target) } catch { moveError = "\(error)" }
            _ = await waitUntil(timeout: .seconds(5)) { tab("b")?.window == target && tab("b")?.index == 1 }
        }
        let after = tab("b").flatMap(strip.browser(for:))
        check("tab strip: moves a tab to another window, keeping its browser",
              tab("b")?.window == tab("z")?.window && tab("b")?.index == 1 && before != nil && before === after && before?.state == .live,
              detail: "\(moveError) b in \(tab("b")?.window.description ?? "-") at \(tab("b")?.index ?? -1), z in \(tab("z")?.window.description ?? "-"); browser \(before?.identifier ?? -1) -> \(after?.identifier ?? -1)")
        if let b = tab("b") { strip.close(b) }
        check("tab strip: closes a tab", await waitUntil(timeout: .seconds(5)) { tab("b") == nil },
              detail: "browser \(tab("b").flatMap(strip.browser(for:))?.identifier ?? -1)")
        closeAll()

        func closeAll() {
            for browser in CefRuntime.shared.browsers { browser.close(force: true) }
        }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }
}
