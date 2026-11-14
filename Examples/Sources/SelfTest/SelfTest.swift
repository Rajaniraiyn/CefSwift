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
        SelfTestCleanup.install()
        if isIsolatedParent {
            exit(runIsolated())
        }
        var configuration = CefRuntime.Configuration.embedded
        configuration.isOffscreenRenderingEnabled = true
        configuration.productName = "SelfTestBrowser"
        configuration.preferences["webkit.webprefs.default_font_size"] = 21
        configuration.preferences["browser.confirm_to_quit"] = false
        configuration.customSchemes = [
            CefCustomScheme(name: "selftest"),
            // For the bridge's origin checks: a scheme that is not standard
            // (no host, opaque origins) and one with file's security rules.
            CefCustomScheme(name: "selftest-plain", options: []),
            CefCustomScheme(name: "selftest-local", options: [.standard, .local]),
        ]
        if let sandboxOverride { configuration.isSandboxEnabled = sandboxOverride }
        configuration.rootCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        // relaunchChecks() starts this app a second time on the same cache
        // directory, which must hand its arguments over and exit.
        let relaunchDirectory = ProcessInfo.processInfo.environment[relaunchEnvironmentKey]
        if let relaunchDirectory {
            configuration.rootCacheDirectory = URL(fileURLWithPath: relaunchDirectory)
        }
        if let probe {
            configuration.rootCacheDirectory = ProcessInfo.processInfo.environment[probeRootEnvironmentKey]
                .map { URL(fileURLWithPath: $0) } ?? configuration.rootCacheDirectory
            configure(&configuration, forProbe: probe)
        }
        // Those second instances report to this one, which counts their
        // lines; they write no results file of their own.
        if relaunchDirectory != nil || probe != nil {
            unsetenv("SELFTEST_JSON")
            unsetenv("SELFTEST_STRICT")
        }
        SystemPromptWatch.shared.install()
        sendJobBeforeStartUp()
        CefDiagnostics.enableCensus()
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
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest-plain", handler: StaticPage())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest-local", handler: StaticPage())
        installBridgeHandlers()
        // Pages several groups load, so that each group also runs by itself.
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "edge", handler: EdgePages())
        // A second site, for cross-site (out-of-process) iframes.
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "edge-frame", handler: EdgePages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "ax", handler: AccessibilityPages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "loading", handler: LoadingPages())
        CefRuntime.shared.registerSchemeHandler(scheme: "https", domain: "cefswift.test", handler: CapabilityPages())

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
            } else if let probe {
                await probes[probe]?()
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
                    quitChecksAfterShutdown()
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
        ("sandbox", sandboxChecks),
        ("windowed", windowedBrowserChecks),
        ("offscreen", offscreenBrowserChecks),
        ("hosting", hostingChecks),
        ("tooltips", tooltipChecks),
        ("popups", popupBlockingChecks),
        ("externalProtocols", externalProtocolChecks),
        ("backForward", backForwardChecks),
        ("frameContents", frameContentChecks),
        ("browserControls", browserControlsChecks),
        ("threads", threadChecks),
        ("lifecycle", lifecycleChecks),
        ("frames", frameChecks),
        ("compositor", compositorChecks),
        ("graphics", graphicsChecks),
        ("accessibility", offscreenAccessibilityChecks),
        ("profile", profileChecks),
        ("profileStorage", profileStorageChecks),
        ("systemPrompts", systemPromptChecks),
        ("window", windowChecks),
        ("behavior", browserBehaviorChecks),
        ("authentication", authenticationChecks),
        ("urlRequest", urlRequestChecks),
        ("localization", localizationChecks),
        ("configuration", configurationChecks),
        ("favicon", faviconChecks),
        ("toolbarAndZoom", toolbarAndZoomChecks),
        ("bridgeScope", bridgeScopeChecks),
        ("bridgeWire", bridgeWireChecks),
        ("bridgeOrigins", bridgeOriginChecks),
        ("compatibility", compatibilityChecks),
        ("internalPages", internalPageDataChecks),
        ("serviceLifetime", serviceLifetimeChecks),
        ("serviceHosts", serviceHostChecks),
        ("serviceCalls", serviceCallChecks),
        // After the history checks: the pages these visit would crowd the
        // probe out of the most-visited tiles.
        ("nativeUI", nativeUIChecks),
        ("surfaces", surfaceStateChecks),
        ("relaunch", relaunchChecks),
        ("protectedMedia", protectedMediaChecks),
        ("systemEngine", systemEngineChecks),
        ("passkeys", passkeyChecks),
        ("chromiumTabs", chromiumTabChecks),
        ("chromeWindow", chromeWindowChecks),
        ("tabHosting", tabHostingChecks),
        ("tabStrip", tabStripChecks),
        ("chromeWindowSurfaces", chromeWindowSurfaceChecks),
        ("session", sessionRestoreChecks),
        ("operations", operationChecks),
        ("loading", loadingChecks),
        ("siteSettings", siteSettingsChecks),
        ("processes", processChecks),
        ("pdf", pdfChecks),
        ("security", securityChecks),
        ("pageIntegration", pageIntegrationChecks),
        ("discard", discardChecks),
        ("contextMenu", contextMenuChecks),
        ("background", backgroundChecks),
        ("extensions", extensionChecks),
    ]

    static func runChecks() async {
        if ProcessInfo.processInfo.environment["SELFTEST_ONLY"]?.split(separator: ",")
            .contains("accessibility-external") == true {
            await accessibilityExternalClientSession()
            return
        }
        let baseline = CefDiagnostics.census()
        for group in selectedGroups {
            await run(group: group.name, group.run)
            await reportCensus(after: group.name, baseline: baseline)
        }
        await censusChecks(baseline: baseline)
        // After the census: these stay open for the quit.
        if selectedGroups.contains(where: { $0.name == "discard" }) {
            await discardBrowsersForQuitting()
        }
        if selectedGroups.contains(where: { $0.name == "urlRequest" }) {
            await requestsStalledForQuitting()
        }
    }

    // MARK: Harness

    static func check(_ name: String, _ passed: Bool, detail: String = "") {
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL") \(name)\(passed || detail.isEmpty ? "" : " — \(detail)")")
    }

    static func expect(_ name: String, _ body: () async throws -> Bool) async {
        await expect(name) { (try await body(), "") }
    }

    /// Checks what `body` returns, with the detail to report if it fails; a
    /// thrown error fails the check.
    static func expect(_ name: String, _ body: () async throws -> (passed: Bool, detail: String)) async {
        do {
            let (passed, detail) = try await body()
            check(name, passed, detail: detail)
        } catch {
            check(name, false, detail: "\(error)")
        }
    }

    /// Shows `browser` in a windowed view that fills the test window, less
    /// `inset` points at the top and bottom.
    static func hostWindowed(_ browser: CefBrowser, inset: CGFloat = 0) -> CefWindowedBrowserView {
        let view = CefWindowedBrowserView(browser: browser)
        host(view, inset: inset)
        return view
    }

    /// Shows `browser` in an offscreen view, as ``hostWindowed(_:inset:)``.
    static func hostOffscreen(_ browser: CefBrowser, inset: CGFloat = 0) -> CefOffscreenBrowserView {
        let view = CefOffscreenBrowserView(browser: browser)
        host(view, inset: inset)
        return view
    }

    private static func host(_ view: NSView, inset: CGFloat) {
        view.frame = window.contentView!.bounds.insetBy(dx: 0, dy: inset)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
    }

    /// Closes a hosted browser, waits until it has closed and removes its view.
    static func closeHosted(_ browser: CefBrowser, _ view: NSView) async {
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        view.removeFromSuperview()
    }

    static func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Whether `browser` finishes loading what it loads within `timeout`
    /// (``CefBrowser/waitUntilLoaded(timeout:)``), showing `title` when one
    /// is given.
    static func loaded(_ browser: CefBrowser, title: String? = nil, timeout: Duration = .seconds(15)) async -> Bool {
        guard (try? await browser.waitUntilLoaded(timeout: timeout)) != nil else { return false }
        return title.map { browser.title == $0 } ?? true
    }

    /// Whether every one of `browsers` finishes loading within `timeout`,
    /// as ``loaded(_:title:timeout:)``.
    static func allLoaded(_ browsers: [CefBrowser], title: String? = nil, timeout: Duration = .seconds(15)) async -> Bool {
        var all = true
        for browser in browsers where !(await loaded(browser, title: title, timeout: timeout)) { all = false }
        return all
    }

    /// Loads `url` in `browser` and returns whether that navigation finishes
    /// within `timeout`, showing `title` when one is given.
    static func load(_ url: URL, in browser: CefBrowser, title: String? = nil, timeout: Duration = .seconds(15)) async -> Bool {
        guard (try? await browser.load(url).waitUntilLoaded(timeout: timeout)) != nil else { return false }
        return title.map { browser.title == $0 } ?? true
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
        case "/transfer.html":
            html = """
                <title>transfer</title>
                <h1>Transfer</h1>
                <script>
                  addEventListener('mousedown', e => { document.title = 'down ' + e.clientX + ',' + e.clientY; });
                </script>
                """
        case "/history-probe.html":
            html = "<title>CefSwift History Probe</title><h1>history</h1>"
        default:
            html = "ok"
        }
        return CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
