import AppKit
import CefKit
import CefSwiftUI

/// End-to-end checks of CefSwift against the real Chromium runtime.
///
/// Launch the bundled app; it runs every check, prints one line per result
/// and exits with the number of failures (124 if the watchdog fires).
@main
@MainActor
enum SelfTest {
    static let bridge = CefBridge(name: "app")
    static var window: NSWindow!
    static var failures = 0

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var configuration = CefConfiguration.embedded
        configuration.isOffscreenRenderingEnabled = true
        configuration.productName = "SelfTestBrowser"
        configuration.preferences["webkit.webprefs.default_font_size"] = 21
        configuration.customSchemes = [CefCustomScheme(name: "selftest")]
        configuration.rootCachePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try CefRuntime.shared.initialize(configuration: configuration)
        } catch {
            print("FAIL initialize: \(error)")
            exit(1)
        }
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", handler: StaticPage())

        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Offscreen views pause while they cannot be seen, so keep the test
        // window in front of whatever else is on screen.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            print("FAIL watchdog: checks did not finish in 90s")
            exit(124)
        }
        Task {
            await runChecks()
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(Int32(failures))
        }
        NSApp.run()
    }

    // MARK: Checks

    static func runChecks() async {
        await windowedBrowserChecks()
        await offscreenBrowserChecks()
        await profileChecks()
        await browserWindowChecks()
        await chromeWindowChecks()
    }

    static func windowedBrowserChecks() async {
        struct Person: Codable { var name: String }
        bridge.handle("greet") { (person: Person, call: CefBridgeCall) in
            "Hello, \(person.name) from \(call.isMainFrame ? "main" : "sub")!"
        }
        bridge.handle("fail") { (_: CefJSON) -> String in throw CefError.operationFailed("nope") }

        var options = CefBrowserOptions()
        options.bridges = [bridge]
        options.userScripts = [CefUserScript(source: "window.__injected = 42;")]
        options.requestFilter = { request in
            request.url?.path == "/blocked" ? .block : .allow
        }
        // The page calls the bridge from an inline script: it must already exist.
        let browser = CefBrowser(url: URL(string: "selftest://app/index.html")!, options: options)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.browser = browser

        check("windowed: bridge available at document start",
              await waitUntil { browser.title == "Hello, Ada from main!" }, detail: browser.title)
        check("windowed: state", browser.state == .live && !browser.isLoading && browser.url?.scheme == "selftest")

        await expect("evaluateJavaScript: value") { try await browser.evaluateJavaScript("1 + 2").intValue == 3 }
        await expect("evaluateJavaScript: promise") {
            try await browser.evaluateJavaScript("new Promise(r => setTimeout(() => r('later'), 10))").stringValue == "later"
        }
        await expect("evaluateJavaScript: typed") {
            try await browser.evaluateJavaScript("({name: 'Grace'})", as: Person.self).name == "Grace"
        }
        await expect("evaluateJavaScript: exception throws") {
            do {
                try await browser.evaluateJavaScript("throw new Error('boom')")
                return false
            } catch let error as CefJavaScriptError {
                return error.message.contains("boom")
            }
        }
        await expect("user script ran before page") { try await browser.evaluateJavaScript("window.__sawInjected").intValue == 42 }
        await expect("bridge: handler error rejects") {
            try await browser.evaluateJavaScript("app.fail({}).then(() => 'resolved', e => e.message)").stringValue?.contains("nope") == true
        }
        await expect("bridge: unknown method rejects") {
            try await browser.evaluateJavaScript("app.missing().then(() => 'resolved', e => 'rejected')").stringValue == "rejected"
        }
        await expect("bridge: event Swift → JS") {
            try await browser.evaluateJavaScript("app.on('ping', value => { window.__ping = value.n; }); 0")
            bridge.emit("ping", ["n": 7])
            return try await browser.evaluateJavaScript(
                "new Promise(r => { const t = setInterval(() => { if (window.__ping) { clearInterval(t); r(window.__ping); } }, 10); })"
            ).intValue == 7
        }
        await expect("bridge: cross-site iframe cannot call") {
            // A cross-site frame lives in another process and never gets the
            // bridge; a same-process one would be refused by the access policy.
            let outcome = try await browser.evaluateJavaScript("""
                new Promise(resolve => {
                  addEventListener('message', e => resolve(e.data), { once: true });
                  const frame = document.createElement('iframe');
                  frame.src = 'selftest://other/frame.html';
                  document.body.appendChild(frame);
                })
                """).stringValue
            return outcome == "missing" || outcome == "rejected"
        }
        await expect("request filter blocks") {
            try await browser.evaluateJavaScript("fetch('selftest://app/blocked').then(() => 'loaded', () => 'blocked')").stringValue == "blocked"
        }
        await expect("devTools: event stream") {
            try await browser.devTools.send("Network.enable")
            async let first = browser.devTools.events("Network.requestWillBeSent").first { _ in true }
            try await Task.sleep(for: .milliseconds(50))
            browser.executeJavaScript("fetch('selftest://app/ping')")
            return await first?["request"]["url"].stringValue == "selftest://app/ping"
        }
        await expect("snapshot: PNG") { try await browser.snapshot().starts(with: [0x89, 0x50, 0x4E, 0x47]) }
        await expect("printToPDF") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest.pdf")
            try? FileManager.default.removeItem(at: file)
            try await browser.printToPDF(at: file)
            return (try? Data(contentsOf: file))?.starts(with: Array("%PDF".utf8)) == true
        }

        browser.load(URL(string: "selftest://app/second.html")!)
        check("navigation: history", await waitUntil { browser.title == "second" && browser.canGoBack })
        await expect("bridge survives navigation") {
            try await browser.evaluateJavaScript("app.greet({name: 'Bob'})").stringValue == "Hello, Bob from main!"
        }

        browser.close(force: true)
        check("windowed: closes", await waitUntil { browser.state == .closed })
        view.removeFromSuperview()
    }

    static func offscreenBrowserChecks() async {
        var options = CefBrowserOptions()
        options.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options)
        let view = CefOffscreenBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser

        check("offscreen: loads", await waitUntil { browser.title == "second" }, detail: browser.title)
        if window.occlusionState.contains(.visible) {
            check("offscreen: paints", await waitUntil { view.layer?.sublayers?.first?.contents != nil })
        } else {
            print("SKIP offscreen: paints — the test window is not visible (screen locked or asleep?)")
        }
        await expect("offscreen: evaluateJavaScript") { try await browser.evaluateJavaScript("document.title").stringValue == "second" }
        browser.close(force: true)
        check("offscreen: closes", await waitUntil { browser.state == .closed })
        view.removeFromSuperview()
    }

    static func profileChecks() async {
        let profile = CefProfile.default
        check("profile: preferences readable", (profile.allPreferences().objectValue?.count ?? 0) > 10)
        check("profile: configured preference applied",
              profile.preference("webkit.webprefs.default_font_size")?.intValue == 21)
        do {
            try profile.setPreference("webkit.webprefs.default_font_size", to: 19)
            check("profile: preference round-trips", profile.preference("webkit.webprefs.default_font_size")?.intValue == 19)
        } catch {
            check("profile: preference round-trips", false, detail: "\(error)")
        }
        check("profile: unknown preference is nil", profile.preference("cefswift.no.such.pref") == nil)

        let cookie = HTTPCookie(properties: [
            .name: "selftest", .value: "yes", .domain: "example.com", .path: "/", .secure: "TRUE",
        ])!
        check("profile: setCookie", profile.setCookie(cookie))
        let url = URL(string: "https://example.com/")!
        check("profile: cookie readable", await waitUntilAsync {
            await profile.cookies(for: url).contains { $0.name == "selftest" && $0.value == "yes" }
        })
        profile.deleteCookies(for: url, named: "selftest")
        check("profile: cookie deleted", await waitUntilAsync {
            await !profile.cookies(for: url).contains { $0.name == "selftest" }
        })

        let isolated = CefProfile.incognito()
        check("profile: incognito is isolated", await isolated.cookies().isEmpty)
        check("profile: configured preference reaches new profiles", await waitUntil {
            isolated.preference("webkit.webprefs.default_font_size")?.intValue == 21
        })
    }

    static func browserWindowChecks() async {
        var options = CefBrowserOptions()
        options.userScripts = [
            CefUserScript(source: "window.__scoped = 1", matching: "chrome://version/*"),
            CefUserScript(source: "window.__elsewhere = 1", matching: "https://*"),
            .styleSheet("body { --cefswift-probe: 7 }", matching: "chrome://*"),
        ]
        let browser = CefBrowser(url: URL(string: "chrome://version")!, options: options)
        let browserWindow = CefBrowserWindow(browser: browser)
        var popups: [CefBrowserWindow] = []
        browserWindow.onPopup = { popups.append($0) }
        browserWindow.show()

        check("browser window: chrome:// page loads", await waitUntil { browser.state == .live && !browser.isLoading && !browser.title.isEmpty }, detail: browser.title)
        check("browser window: has NSWindow", browserWindow.nsWindow != nil)
        await expect("browser window: product name override") {
            let text = try await browser.evaluateJavaScript("document.body.innerText").stringValue ?? ""
            return text.contains("SelfTestBrowser")
        }
        check("browser window: chrome commands", browser.canExecute(.find))
        await expect("browser window: ad-hoc signed builds use the mock keychain") {
            // Local builds must never touch the login keychain (no password prompts).
            let text = try await browser.evaluateJavaScript("document.body.innerText").stringValue ?? ""
            return text.contains("--use-mock-keychain")
        }
        await expect("internal page: scoped script runs, others don't") {
            _ = await waitUntilAsync(timeout: .seconds(3)) {
                (try? await browser.evaluateJavaScript("window.__scoped === 1").boolValue) == true
            }
            return try await browser.evaluateJavaScript("window.__scoped === 1 && window.__elsewhere === undefined").boolValue == true
        }
        await expect("internal page: stylesheet applies") {
            try await browser.evaluateJavaScript(
                "getComputedStyle(document.body).getPropertyValue('--cefswift-probe').trim()").stringValue == "7"
        }
        await expect("browser window: popup is hosted by the app") {
            try await browser.evaluateJavaScript("window.open('about:blank', '_blank', 'width=320,height=240'); 0")
            let arrived = await waitUntil(timeout: .seconds(5)) { !popups.isEmpty }
            return arrived && popups[0].nsWindow != nil && popups[0].browser.opener === browser
        }
        for popup in popups { popup.close() }
        check("browser window: popup closes", await waitUntil { popups.allSatisfy(\.isClosed) })

        browserWindow.close()
        check("browser window: closes", await waitUntil { browserWindow.isClosed && browser.state == .closed })
    }

    static func chromeWindowChecks() async {
        var created: [CefBrowser] = []
        CefRuntime.shared.onBrowserCreated = { created.append($0) }
        let browser = CefRuntime.shared.openChromeWindow(url: URL(string: "selftest://app/second.html")!)
        check("chrome UI window: loads", await waitUntil { browser.title == "second" }, detail: browser.title)

        browser.execute(.newTab)
        check("chrome UI window: new tab is adopted", await waitUntil { !created.isEmpty && CefRuntime.shared.browsers.count == 2 })

        for open in CefRuntime.shared.browsers { open.close(force: true) }
        check("all browsers close", await waitUntil { CefRuntime.shared.browsers.isEmpty })
    }

    // MARK: Harness

    static func check(_ name: String, _ passed: Bool, detail: String = "") {
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)\(passed || detail.isEmpty ? "" : " — \(detail)")")
    }

    static func expect(_ name: String, _ body: () async throws -> Bool) async {
        do {
            check(name, try await body())
        } catch {
            check(name, false, detail: "\(error)")
        }
    }

    static func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    static func waitUntilAsync(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

/// Serves the pages the checks load.
struct StaticPage: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let html: String
        switch request.url?.path {
        case "/index.html":
            html = """
                <title>loading</title>
                <script>
                  window.__sawInjected = window.__injected;
                  app.greet({ name: 'Ada' }).then(reply => { document.title = reply; });
                </script>
                """
        case "/frame.html":
            html = """
                <script>
                  const answer = typeof app === 'undefined'
                    ? Promise.resolve('missing')
                    : app.greet({ name: 'Eve' }).then(() => 'allowed', () => 'rejected');
                  answer.then(result => parent.postMessage(result, '*'));
                </script>
                """
        case "/second.html":
            html = "<title>second</title><h1>second</h1>"
        default:
            html = "ok"
        }
        return CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
