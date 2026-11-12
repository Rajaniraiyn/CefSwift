import AppKit
import CefSwiftUI
import SwiftUI

/// Favicons, toolbars and zoom, where a bridge is installed, when a
/// profile's hidden service browsers close, and what a second launch does.
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

    // MARK: Toolbar and zoom

    static func toolbarAndZoomChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!)
        let window = CefBrowserWindow(browser: browser)
        let renders = RenderLog()
        window.setToolbar { TitleProbe(browser: browser, log: renders) }
        window.setTabAccessory { TitleProbe(browser: browser, log: renders) }
        window.show()
        _ = await waitUntil { browser.title == "second" && !browser.isLoading }
        check("toolbar: installed in the window",
              window.window?.toolbar?.items.count == 5 && window.window?.tab.accessoryView != nil)
        check("toolbar: its views follow the browser's state", await waitUntil { renders.titles.last == "second" },
              detail: "\(renders.titles)")

        let zoom = ZoomObserver(browser)
        browser.zoomLevel = 1
        check("zoom: a level set reads back and is observed",
              await waitUntil { browser.zoomLevel == 1 && zoom.changes == 1 },
              detail: "\(browser.zoomLevel), \(zoom.changes) changes")
        browser.execute(.zoomIn)
        check("zoom: Chrome's zoom commands are observed",
              await waitUntil { browser.zoomLevel > 1 && zoom.changes >= 2 },
              detail: "\(browser.zoomLevel)")
        browser.load(URL(string: "selftest://edge/tab.html")!)
        check("zoom: each site keeps its own level", await waitUntil {
            browser.title == "tab" && !browser.isLoading && browser.zoomLevel == 0
        }, detail: "\(browser.zoomLevel)")
        browser.goBack()
        check("zoom: returning to a site restores its level", await waitUntil {
            browser.title == "second" && browser.zoomLevel > 1
        }, detail: "\(browser.zoomLevel)")
        browser.zoomLevel = 0

        window.close()
        _ = await waitUntil { window.isClosed }
        var ranAfterClose = false
        window.withWindow { _ in ranAfterClose = true }
        check("toolbar: setup after the window closed is ignored", !ranAfterClose)
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
            await expect("service lifetime: incognito bookmarks are the default profile's") {
                guard profile.bookmarks === CefProfile.default.bookmarks else { return false }
                return try await profile.bookmarks.tree().contains { $0.permanentFolder == .bookmarksBar }
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

/// Records what a SwiftUI view saw each time it rendered.
@MainActor
final class RenderLog {
    var titles: [String] = []
}

/// Shows a browser's title and logs each render.
struct TitleProbe: View {
    let browser: CefBrowser
    let log: RenderLog

    var body: some View {
        let _ = log.titles.append(browser.title)
        Text(browser.title)
    }
}

/// Counts changes to a browser's observable zoom level.
@MainActor
final class ZoomObserver {
    let browser: CefBrowser
    private(set) var changes = 0

    init(_ browser: CefBrowser) {
        self.browser = browser
        observe()
    }

    private func observe() {
        withObservationTracking { _ = browser.zoomLevel } onChange: { [weak self] in
            Task { @MainActor in
                self?.changes += 1
                self?.observe()
            }
        }
    }
}
