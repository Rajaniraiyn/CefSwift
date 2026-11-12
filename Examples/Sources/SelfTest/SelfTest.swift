import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// End-to-end checks of CefSwift against the real Chromium runtime.
///
/// Launch the bundled app; it runs every check, prints one line per result
/// and exits with the number of failures (124 if the watchdog fires).
/// Harness.swift describes deadlines, skip categories, `SELFTEST_STRICT`,
/// `SELFTEST_ISOLATED` and `SELFTEST_JSON`.
@main
@MainActor
enum SelfTest {
    static let bridge = CefBridge(name: "app")
    static var window: NSWindow!
    static var failures = 0
    static let started = ContinuousClock.now

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = started
        if isIsolatedParent {
            exit(runIsolated())
        }
        var configuration = CefConfiguration.embedded
        configuration.isOffscreenRenderingEnabled = true
        configuration.productName = "SelfTestBrowser"
        configuration.preferences["webkit.webprefs.default_font_size"] = 21
        configuration.preferences["browser.confirm_to_quit"] = false
        configuration.customSchemes = [CefCustomScheme(name: "selftest")]
        configuration.rootCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        // relaunchChecks() starts this app a second time on the same cache
        // directory, which must hand its arguments over and exit.
        let relaunchDirectory = ProcessInfo.processInfo.environment[relaunchEnvironmentKey]
        if let relaunchDirectory {
            configuration.rootCacheDirectory = URL(fileURLWithPath: relaunchDirectory)
        }
        // protectedMediaChecks() starts this app a second time with Widevine on.
        let widevineProbeDirectory = ProcessInfo.processInfo.environment[widevineProbeEnvironmentKey]
        if let widevineProbeDirectory {
            configuration.rootCacheDirectory = URL(fileURLWithPath: widevineProbeDirectory)
            configuration.protectedMedia = .automatic
        }
        // Those second instances report to this one, which counts their
        // lines; they write no results file of their own.
        if relaunchDirectory != nil || widevineProbeDirectory != nil {
            unsetenv("SELFTEST_JSON")
            unsetenv("SELFTEST_STRICT")
        }
        sendJobBeforeStartUp()
        do {
            try CefRuntime.shared.initialize(configuration: configuration)
            if relaunchDirectory != nil {
                print("FAIL relaunch: a second instance started")
                exit(3)
            }
        } catch .anotherInstanceRunning where relaunchDirectory != nil {
            exit(0)
        } catch {
            print("FAIL initialize: \(error)")
            exit(1)
        }
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", handler: StaticPage())
        installBridgeHandlers()
        // Pages several groups load, so that each group also runs by itself.
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "edge", handler: EdgePages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "ax", handler: AccessibilityPages())

        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // Offscreen views pause while they cannot be seen, so keep the test
        // window in front of whatever else is on screen.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // A last resort: each group has its own deadline.
        let isBenchmark = ServiceBenchmark.isRequested || Benchmarks.requested != nil
        let watchdog = isBenchmark ? 900 : 90 + selectedGroups.reduce(0) { $0 + Int(deadline(of: $1.name).components.seconds) }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(watchdog)) {
            MainActor.assumeIsolated {
                check("watchdog: checks finish within \(watchdog) s", false,
                      detail: "stuck in group \(SelfTestResults.shared.group)")
                SelfTestReport.finish(failures: failures, isolated: false, started: started)
            }
            exit(124)
        }
        Task {
            if let benchmark = Benchmarks.requested {
                await Benchmarks.run(benchmark)
            } else if ServiceBenchmark.isRequested {
                await ServiceBenchmark.run()
            } else if widevineProbeDirectory != nil {
                await widevineProbeChecks()
            } else {
                await runChecks()
            }
            // Quit as an app does, through terminate: and cef_shutdown(). A
            // crash there ends the process with a signal instead.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    SelfTestResults.shared.group = "quit"
                    check("quit: Chromium shuts down cleanly", CefRuntime.shared.state == .stopped,
                          detail: "\(CefRuntime.shared.state)")
                    var restart = "started"
                    do { try CefRuntime.shared.initialize() } catch { restart = "\(error)" }
                    check("quit: the runtime does not start again after shutting down",
                          restart.contains("cannot be initialized again") && CefRuntime.shared.state == .stopped,
                          detail: restart)
                    check("quit: a job sent to CefIOActor after shutdown runs", jobAfterShutdownRuns())
                    exit(Int32(min(SelfTestReport.finish(failures: failures, isolated: false, started: started), 123)))
                }
            }
            if ProcessInfo.processInfo.environment["SELFTEST_QUIT"] == "logout" {
                // As loginwindow asks when the user logs out.
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(enumCode: OSType(kAELogOut)), forKeyword: AEKeyword(kAEQuitReason))
                _ = try? event.sendEvent(options: [.noReply], timeout: 5)
            } else {
                NSApp.terminate(nil)
            }
        }
        NSApp.run()
    }

    // MARK: Checks

    /// Every group of checks, in the order they run.
    /// `SELFTEST_ONLY=<name>[,<name>…]` runs only the named groups, such as
    /// `SELFTEST_ONLY=passkeys`; `accessibility-external` is a session for an
    /// outside accessibility client instead of checks.
    static let checkGroups: [(name: String, run: @MainActor () async -> Void)] = [
        ("capabilities", { capabilityChecks() }),
        ("windowed", windowedBrowserChecks),
        ("offscreen", offscreenBrowserChecks),
        ("threads", threadChecks),
        ("lifecycle", lifecycleChecks),
        ("frames", frameChecks),
        ("compositor", compositorChecks),
        ("accessibility", offscreenAccessibilityChecks),
        ("profile", profileChecks),
        ("browserWindow", browserWindowChecks),
        ("behavior", browserBehaviorChecks),
        ("favicon", faviconChecks),
        ("toolbarAndZoom", toolbarAndZoomChecks),
        ("bridgeScope", bridgeScopeChecks),
        ("compatibility", compatibilityChecks),
        ("internalPages", internalPageDataChecks),
        ("serviceLifetime", serviceLifetimeChecks),
        ("serviceHosts", serviceHostChecks),
        // After the history checks: the pages these visit would crowd the
        // probe out of the most-visited tiles.
        ("nativeUI", nativeUIChecks),
        ("relaunch", relaunchChecks),
        ("protectedMedia", protectedMediaChecks),
        ("systemEngine", systemEngineChecks),
        ("passkeys", passkeyChecks),
        ("chromiumTabs", chromiumTabChecks),
        ("chromeWindow", chromeWindowChecks),
        ("operations", operationChecks),
        ("siteSettings", siteSettingsChecks),
        ("processes", processChecks),
        ("pdf", pdfChecks),
        // Last: it leaves discarded browsers open for the quit.
        ("discard", discardChecks),
    ]

    static func runChecks() async {
        if ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator: ",")
            .contains("accessibility-external") == true {
            await accessibilityExternalClientSession()
            return
        }
        for group in selectedGroups {
            await run(group: group.name, group.run)
        }
    }

    /// What the bundle's signature allows, as CefKit reads it.
    static func capabilityChecks() {
        let capabilities = CefRuntime.shared.capabilities
        let consistent = capabilities.signature.hasAppleTeam == (capabilities.teamIdentifier != nil)
            && capabilities.passkeyAuthenticators.contains(.securityKey)
            && (capabilities.teamIdentifier != nil
                || capabilities.resolvedSafeStorage(.automatic) == .mockKeychain)
        check("capabilities: signature (\(capabilities.signature.rawValue)" +
              (capabilities.isHardenedRuntime ? ", hardened runtime" : "") + ") and passkey authenticators (" +
              capabilities.passkeyAuthenticators.map(\.description).sorted().joined(separator: ", ") + ")",
              consistent && capabilities.signature != .unsigned)
    }

    struct Person: Codable { var name: String }

    /// The `app` bridge's handlers, which the windowed and discard groups
    /// call. Installed at start-up so that each group also runs by itself.
    static func installBridgeHandlers() {
        bridge.handle("greet") { (person: Person, call: CefBridgeCall) in
            "Hello, \(person.name) from \(call.isMainFrame ? "main" : "sub")!"
        }
        bridge.handle("fail") { (_: CefJSON) -> String in throw CefError.operationFailed("nope") }
    }

    static func windowedBrowserChecks() async {
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
            skip("offscreen: paints", because: "the test window is not visible (screen locked or asleep?)", .environment)
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

        // Scheme handlers registered with CefRuntime serve every profile.
        var options = CefBrowserOptions()
        options.profile = isolated
        let privateWindow = CefBrowserWindow(
            browser: CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options))
        check("profile: custom scheme serves an incognito profile",
              await waitUntil { privateWindow.browser.title == "second" }, detail: privateWindow.browser.title)
        privateWindow.close()
        _ = await waitUntil { privateWindow.isClosed }
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
        check("browser window: has NSWindow", browserWindow.window != nil)
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
            try await browser.evaluateJavaScript("window.open('about:blank', '_blank', 'width=320,height=240'); 0", userGesture: true)
            let arrived = await waitUntil(timeout: .seconds(5)) { !popups.isEmpty }
            return arrived && popups[0].window != nil && popups[0].browser.opener === browser
        }
        for popup in popups { popup.close() }
        check("browser window: popup closes", await waitUntil { popups.allSatisfy(\.isClosed) })

        browserWindow.close()
        check("browser window: closes", await waitUntil { browserWindow.isClosed && browser.state == .closed })
    }

    /// Bookmarks, history, most-visited and autocomplete reach Chromium
    /// through its internal pages; these checks catch a Chromium update that
    /// moves them.
    static func internalPageDataChecks() async {
        let profile = CefProfile.default
        let bookmarks = profile.bookmarks
        var bookmarkChanges = 0
        let watcher = Task { for await _ in bookmarks.changes { bookmarkChanges += 1 } }
        defer { watcher.cancel() }

        await expect("bookmarks: tree has the permanent folders") {
            try await bookmarks.tree().contains { $0.permanentFolder == .bookmarksBar }
        }
        let bookmarkURL = URL(string: "https://selftest.invalid/zanzibar")!
        var added: CefBookmark?
        await expect("bookmarks: add") {
            added = try await bookmarks.add(bookmarkURL, title: "CefSwift Zanzibar Bookmark")
            return added?.url == bookmarkURL && added?.isFolder == false
        }
        var folder: CefBookmark?
        if let added {
            await expect("bookmarks: read back") { try await bookmarks.bookmark(added.id)?.title == "CefSwift Zanzibar Bookmark" }
            await expect("bookmarks: search") { try await bookmarks.search("zanzibar").contains { $0.id == added.id } }
            await expect("bookmarks: by URL") { try await bookmarks.bookmarks(for: bookmarkURL).map(\.id) == [added.id] }
            await expect("bookmarks: folder, update, move") {
                let created = try await bookmarks.addFolder("CefSwift Folder")
                folder = created
                try await bookmarks.update(added.id, title: "CefSwift Zanzibar Renamed")
                try await bookmarks.move(added.id, to: created.id)
                let children = try await bookmarks.children(of: created.id)
                return children.map(\.title) == ["CefSwift Zanzibar Renamed"] && children[0].parentID == created.id
            }
            check("bookmarks: change events", await waitUntil(timeout: .seconds(5)) { bookmarkChanges >= 4 },
                  detail: "\(bookmarkChanges) events")
            check("bookmarks: a change not yet saved keeps reads on the service", bookmarks.hasUnsavedChanges)
            // Chromium saves its Bookmarks file about 2.5 s after a change,
            // while the app shows a page.
            var difference = ""
            check("bookmarks: Chromium's file reads as the service answers", await withVisiblePage { await waitUntilAsync(timeout: .seconds(8)) {
                bookmarks.readSource = .service
                let served = (try? await bookmarks.tree()) ?? []
                bookmarks.readSource = .file
                let stored = (try? await bookmarks.tree()) ?? []
                var contents: [CefBookmark]?
                if let folder { contents = try? await bookmarks.children(of: folder.id) }
                let recent = try? await bookmarks.recent(limit: 1)
                bookmarks.readSource = .automatic
                difference = "\(bookmarkSummary(served)) vs \(bookmarkSummary(stored))"
                return !served.isEmpty && bookmarkSummary(served) == bookmarkSummary(stored)
                    && contents?.map(\.id) == [added.id] && recent?.map(\.id) == [added.id]
            } }, detail: difference)
            check("bookmarks: reads return to the file once Chromium has saved", !bookmarks.hasUnsavedChanges)
        }

        // Visit a page in a Chrome-style browser so Chromium records it.
        let visitedURL = URL(string: "selftest://app/history-probe.html")!
        let visitor = CefBrowserWindow(browser: CefBrowser(url: visitedURL))
        check("history: page visited", await waitUntil { visitor.browser.title == "CefSwift History Probe" })
        // Most visited has eight places, and earlier checks visit other
        // pages; visit this one more often than any of them.
        for _ in 0..<12 {
            visitor.browser.load(URL(string: "selftest://app/second.html")!)
            _ = await waitUntil { visitor.browser.title == "second" && !visitor.browser.isLoading }
            visitor.browser.load(visitedURL)
            _ = await waitUntil { visitor.browser.title == "CefSwift History Probe" && !visitor.browser.isLoading }
        }
        visitor.close()
        _ = await waitUntil { visitor.isClosed }

        let history = profile.history
        var entry: CefHistoryEntry?
        check("history: visit found", await waitUntilAsync(timeout: .seconds(15)) {
            entry = try? await history.search("History Probe").first { $0.url == visitedURL }
            return entry != nil
        })
        if let entry {
            check("history: entry details", entry.title == "CefSwift History Probe" && !entry.visitDates.isEmpty
                  && abs(entry.lastVisitDate.timeIntervalSinceNow) < 120)
        }
        var tiles: [URL] = []
        check("history: most visited includes the visit", await waitUntilAsync(timeout: .seconds(20)) {
            tiles = (try? await history.mostVisited().map(\.url)) ?? []
            return tiles.contains(visitedURL)
        }, detail: "\(tiles.count) tiles: \(tiles.map(\.absoluteString))")

        await expect("autocomplete: bookmark ranked for a title prefix") {
            let suggestions = try await profile.autocomplete.suggestions(for: "CefSwift Zanzib")
            return suggestions.contains { $0.kind == .bookmark && $0.url == bookmarkURL && $0.isBookmarked }
        }
        await expect("autocomplete: address prefix finds the bookmark") {
            let suggestions = try await profile.autocomplete.suggestions(for: "selftest.invalid/zan")
            return suggestions.contains { $0.url == bookmarkURL } && suggestions.contains { $0.kind == .search }
        }

        check("internal pages: service browsers stay out of public lists",
              CefRuntime.shared.browsers.isEmpty && CefBrowserWindow.all.isEmpty,
              detail: "\(CefRuntime.shared.browsers.count) browsers, \(CefBrowserWindow.all.count) windows")

        if let entry {
            await expect("history: remove") {
                try await history.remove([entry])
                return try await history.search("History Probe").allSatisfy { $0.url != visitedURL }
            }
        }
        if let folder {
            await expect("bookmarks: remove folder with contents") {
                try await bookmarks.remove(folder.id)
                return try await bookmarks.search("CefSwift Zanzibar").isEmpty
            }
        }
    }

    /// What two reads of the bookmark tree are compared by.
    static func bookmarkSummary(_ nodes: [CefBookmark]) -> String {
        nodes.map { node in
            "\(node.id):\(node.parentID?.description ?? "-"):\(node.index):\(node.title):\(node.url?.absoluteString ?? "")"
                + ":\(String(describing: node.permanentFolder)):\(node.isEditable):"
                + "\(node.dateAdded.map { Int($0.timeIntervalSince1970) } ?? 0)[\(bookmarkSummary(node.children ?? []))]"
        }.joined(separator: ",")
    }

    /// Runs `body` while a page shows in a visible window, then closes it.
    /// Chromium's profile file saves (`Bookmarks` among them) wait while
    /// the app shows no page, as a group run on its own may not.
    static func withVisiblePage<T>(_ body: () async -> T) async -> T {
        let window = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://app/second.html")!))
        window.show()
        _ = await waitUntil(timeout: .seconds(15)) { window.browser.title == "second" && !window.browser.isLoading }
        let result = await body()
        window.close()
        _ = await waitUntil { window.isClosed && window.browser.state == .closed }
        return result
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
        case "/compat.html":
            // What bot-detection pages read about the browser, at document
            // start (CompatibilityChecks.swift).
            html = """
                <title>compat</title>
                <script>
                  const start = performance.now();
                  debugger;
                  window.__debuggerMs = performance.now() - start;
                  window.__globals = Object.getOwnPropertyNames(window)
                    .filter(name => /cefswift|cdc_|__pw|puppeteer|webdriver/i.test(name));
                  window.__webdriver = navigator.webdriver;
                </script>
                <h1>compat</h1>
                """
        case "/history-probe.html":
            html = "<title>CefSwift History Probe</title><h1>history</h1>"
        default:
            html = "ok"
        }
        return CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
