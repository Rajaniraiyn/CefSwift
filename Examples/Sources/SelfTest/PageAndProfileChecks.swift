import AppKit
import CefSwiftUI

/// Favicons, where a bridge is installed, when a profile's hidden service
/// browsers close, and what a second launch does.
extension SelfTest {
    static let relaunchEnvironmentKey = "CEFSWIFT_SELFTEST_RELAUNCH_ROOT"

    // MARK: Favicons

    static func faviconChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://edge/favicon.html")!)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        check("favicon: downloaded as an image", await waitUntil { browser.favicon != nil },
              detail: "\(String(describing: browser.faviconURL))")
        if let favicon = browser.favicon {
            let color = favicon.representations.compactMap { $0 as? NSBitmapImageRep }.first?
                .colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
            check("favicon: the page's icon, sized in points",
                  browser.faviconURL?.lastPathComponent == "icon.png" && favicon.size.width <= 32
                      && (color?.redComponent ?? 0) > 0.9 && (color?.greenComponent ?? 1) < 0.3,
                  detail: "\(favicon.size) \(String(describing: color))")
        }
        let history = CefProfile.default.history
        check("favicon: Chromium keeps the icon of a visited page", await waitUntilAsync(timeout: .seconds(15)) {
            (try? await history.favicon(for: URL(string: "selftest://edge/favicon.html")!, size: 32)) != nil
        })
        await expect("favicon: none kept for a page never visited") {
            try await history.favicon(for: URL(string: "https://never-visited.invalid/")!) == nil
        }
        // tab.html declares no icon; its default /favicon.ico is not an image.
        browser.load(URL(string: "selftest://edge/tab.html")!)
        check("favicon: reset when a new page loads", await waitUntil {
            browser.title == "tab" && browser.faviconURL?.lastPathComponent != "icon.png"
        })
        try? await Task.sleep(for: .milliseconds(500))
        check("favicon: none for a page without one", browser.favicon == nil)
        browser.goBack()
        check("favicon: back again shows the icon", await waitUntil { browser.favicon != nil },
              detail: "\(String(describing: browser.faviconURL))")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Bridge scope

    static func bridgeScopeChecks() async {
        let bridge = CefBridge(name: "scoped")
        bridge.access = .origins(["selftest://app"])
        bridge.handle("ping") { (_: CefJSON) in "pong" }
        var options = CefBrowserOptions()
        options.bridges = [bridge]
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "second" }
        await expect("bridge scope: a permitted origin gets the bridge, not its raw binding") {
            try await browser.evaluateJavaScript(
                "typeof __cefswift_scoped === 'undefined' ? scoped.ping() : 'binding visible'").stringValue == "pong"
        }
        browser.load(URL(string: "selftest://edge/tab.html")!)
        _ = await waitUntil { browser.title == "tab" }
        await expect("bridge scope: other origins have no global at all") {
            try await browser.evaluateJavaScript(
                "typeof scoped === 'undefined' && typeof __cefswift_scoped === 'undefined'").boolValue == true
        }
        bridge.access = .anyFrame
        try? await Task.sleep(for: .milliseconds(200))
        browser.reload()
        await expect("bridge scope: widening access installs it on the next load") {
            await waitUntilAsync {
                (try? await browser.evaluateJavaScript("typeof scoped === 'object' && document.readyState === 'complete'").boolValue) == true
            }
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Service browsers

    static func serviceLifetimeChecks() async {
        weak var released: CefProfile?
        do {
            let profile = CefProfile.incognito()
            released = profile
            var options = CefBrowserOptions()
            options.profile = profile
            let window = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options))
            check("service lifetime: incognito tab loads", await waitUntil { window.browser.title == "second" })
            // Starts the profile's hidden suggestions browser.
            await expect("service lifetime: incognito suggestions answer") {
                await profile.autocomplete.prepare()
                return try await !profile.autocomplete.suggestions(for: "cefswift").isEmpty
            }
            await expect("service lifetime: incognito history throws instead of opening chrome://history") {
                do {
                    _ = try await profile.history.search(limit: 1)
                    return false
                } catch {
                    return true
                }
            }
            window.close()
            _ = await waitUntil { window.isClosed }
        }
        check("service lifetime: an incognito profile goes with its last tab", await waitUntil { released == nil })
    }

    // MARK: Relaunch

    static func relaunchChecks() async {
        var received: [([String], URL?)] = []
        CefRuntime.shared.onRelaunch = { received.append(($0, $1)) }
        defer { CefRuntime.shared.onRelaunch = nil }
        guard let root = CefRuntime.shared.configuration?.rootCacheDirectory else {
            check("relaunch: cache directory known", false)
            return
        }
        let visibleBefore = NSApp.windows.filter(\.isVisible).count
        let second = Process()
        second.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        second.arguments = ["https://relaunch.selftest/"]
        second.currentDirectoryURL = FileManager.default.temporaryDirectory
        second.environment = ProcessInfo.processInfo.environment.merging([relaunchEnvironmentKey: root.path]) { $1 }
        do {
            try second.run()
        } catch {
            check("relaunch: second launch starts", false, detail: "\(error)")
            return
        }
        let exited = await waitUntil(timeout: .seconds(20)) { !second.isRunning }
        check("relaunch: the second launch exits", exited && second.terminationStatus == 0,
              detail: exited ? "status \(second.terminationStatus)" : "still running")
        if !exited { second.terminate() }
        check("relaunch: arguments reach onRelaunch", await waitUntil(timeout: .seconds(5)) {
            received.contains { $0.0.contains("https://relaunch.selftest/") && $0.1 != nil }
        }, detail: "\(received)")
        try? await Task.sleep(for: .seconds(1))
        check("relaunch: no window of Chromium's appears",
              NSApp.windows.filter(\.isVisible).count == visibleBefore && CefRuntime.shared.browsers.isEmpty,
              detail: "\(NSApp.windows.filter(\.isVisible).map(\.title)), \(CefRuntime.shared.browsers.count) browsers")
    }
}
