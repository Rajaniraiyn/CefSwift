import AppKit
import CefSwiftUI

/// Checks of what a browser built on `CefWindow` relies on: popups,
/// closing in awkward moments, downloads, `beforeunload`, load errors,
/// renderer crashes and Chromium's own pages.
extension SelfTest {
    static func browserBehaviorChecks() async {
        await bridgeRoundTripChecks()
        await popupChecks()
        await closingChecks()
        await downloadChecks()
        await leavingChecks()
        await loadFailureChecks()
        await rendererCrashChecks()
        await settingsPageChecks()
        // "Hold ⌘Q to Quit" is an application-wide setting, not a profile's.
        check("preference: configured application-wide preference applied",
              CefRuntime.shared.preferences.value(named: "browser.confirm_to_quit")?.boolValue == false,
              detail: "\(String(describing: CefRuntime.shared.preferences.value(named: "browser.confirm_to_quit")))")
    }

    // MARK: Bridge, as the Showcase uses it

    static func bridgeRoundTripChecks() async {
        var total = 0
        let counter = CefBridge(name: "counter")
        counter.handle("increment") { (amount: Int) -> Int in
            total += amount
            return total
        }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [counter]
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await loaded(browser, title: "tab")
        await expect("bridge: typed round trip in a Chrome-style window") {
            let first = try await browser.evaluateJavaScript("counter.increment(1)").intValue
            let second = try await browser.evaluateJavaScript("counter.increment(10)").intValue
            return first == 1 && second == 11 && total == 11
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Popups

    static func popupChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://edge/opener.html")!)
        let opener = CefWindow(browser: browser)
        var popups: [CefWindow] = []
        opener.onPopup = { popup in
            popups.append(popup)
            if let parent = opener.window, let panel = popup.window {
                parent.addChildWindow(panel, ordered: .above)
            }
            popup.onClose = { [weak parent = opener.window, weak panel = popup.window] in
                if let panel { parent?.removeChildWindow(panel) }
            }
            popup.show()
        }
        opener.show()
        _ = await loaded(browser, title: "opener")

        await expect("popup: requested size is reported") {
            try await browser.evaluateJavaScript("window.__popup = window.open('popup.html', 'p', 'width=420,height=360'); 0", userGesture: true)
            guard await waitUntil(timeout: .seconds(5), { popups.count == 1 }) else { return false }
            return popups[0].browser.popupFeatures?.size == CGSize(width: 420, height: 360)
        }
        check("popup: is a child window of its opener",
              popups.first?.window.map { opener.window?.childWindows?.contains($0) == true } == true)
        await expect("popup: page calling window.close() closes it") {
            guard let popup = popups.first else { return false }
            _ = await waitUntil { popup.browser.title == "popup" }
            // Run without awaiting a result: the close may come before an
            // evaluation's reply, which the closing browser then fails.
            popup.browser.executeJavaScript("window.close()")
            return await waitUntil { popup.isClosed }
        }
        check("popup: leaves its opener's child windows", opener.window?.childWindows?.isEmpty != false)

        await expect("popup: closing the opener with a popup open is clean") {
            try await browser.evaluateJavaScript("window.open('popup.html', 'q', 'width=300,height=200'); 0", userGesture: true)
            guard await waitUntil(timeout: .seconds(5), { popups.count == 2 }) else { return false }
            let popup = popups[1]
            opener.close()
            guard await waitUntil({ opener.isClosed && browser.state == .closed }) else { return false }
            // Chromium keeps a popup when its opener goes; the app decides.
            popup.close()
            return await waitUntil { popup.isClosed }
        }
    }

    // MARK: Closing

    static func closingChecks() async {
        let slow = CefBrowser(url: URL(string: "selftest://edge/slow.html")!)
        let loading = CefWindow(browser: slow)
        loading.show()
        _ = await waitUntil(timeout: .seconds(3)) { slow.isLoading }
        loading.close()
        check("closing: a window still loading closes", await waitUntil { loading.isClosed && slow.state == .closed })

        let windows = (0..<8).map { index in
            CefWindow(browser: CefBrowser(url: URL(string: "selftest://edge/tab.html?\(index)")!))
        }
        windows.forEach { $0.show() }
        check("closing: many tabs opened at once all load",
              await waitUntil { windows.allSatisfy { $0.browser.title == "tab" } })
        windows.forEach { $0.close() }
        check("closing: many tabs closed at once", await waitUntil { windows.allSatisfy(\.isClosed) })
    }

    // MARK: Downloads

    static func downloadChecks() async {
        // Chromium downloads only from network schemes, so these come from a
        // local server.
        guard let server = try? await LocalServer.start() else {
            skip("download", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-downloads-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = "http://127.0.0.1:\(server.port)"
        let recorder = Recorder()
        recorder.downloadDestination = directory
        // A profile of its own, so its policy and download list are the checks' alone.
        let profile = CefProfile.incognito()
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, configuration: configuration, delegate: recorder)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await loaded(browser, title: "tab")
        func download(named name: String) -> CefDownload? { browser.downloads.last { $0.url?.lastPathComponent == name } }
        func describe() -> String {
            browser.downloads.map { "\($0.suggestedFilename) \($0.state) \($0.fileURL?.path ?? "-")" }.joined(separator: "; ")
        }

        check("download: the profile's policy starts as the Downloads folder", profile.downloadPolicy == .downloadsFolder)
        // The delegate's decision wins over the policy.
        profile.downloadPolicy = .disabled
        browser.load(URL(string: "\(base)/report.txt")!)
        check("download: attachment is saved where the delegate says", await waitUntil {
            download(named: "report.txt")?.state == .completed
                && download(named: "report.txt")?.fileURL?.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent
        }, detail: describe())
        check("download: page stays put", browser.title == "tab")
        if let report = download(named: "report.txt") {
            check("download: the item has its name, type, size and progress",
                  report.suggestedFilename == "report.txt" && report.mimeType == "text/plain"
                      && report.receivedBytes == 2048 * 9 && report.fractionCompleted == 1 && !report.canResume,
                  detail: "\(report.suggestedFilename) \(report.mimeType) \(report.receivedBytes) \(String(describing: report.fractionCompleted))")
            check("download: the profile lists it, and its browser",
                  profile.downloads.contains { $0 === report } && report.browser === browser)
        }

        recorder.downloadDestination = nil
        browser.load(URL(string: "\(base)/denied.txt")!)
        check("download: denied download is cancelled", await waitUntil {
            download(named: "denied.txt")?.state == .cancelled
        }, detail: describe())

        // Without a decision of the delegate's, the profile's policy applies.
        recorder.followsDownloadPolicy = true
        defer { recorder.followsDownloadPolicy = false }
        let policyFolder = directory.appendingPathComponent("policy", isDirectory: true)
        try? FileManager.default.createDirectory(at: policyFolder, withIntermediateDirectories: true)
        try? Data("taken".utf8).write(to: policyFolder.appendingPathComponent("policy.txt"))
        profile.downloadPolicy = .folder(policyFolder)
        browser.load(URL(string: "\(base)/policy.txt")!)
        check("download: the policy's folder is used, and a taken name is numbered", await waitUntil {
            download(named: "policy.txt")?.state == .completed
                && download(named: "policy.txt")?.fileURL?.lastPathComponent == "policy (1).txt"
        }, detail: describe())
        profile.downloadPolicy = .disabled
        browser.load(URL(string: "\(base)/disabled.txt")!)
        check("download: a disabled policy cancels", await waitUntil {
            download(named: "disabled.txt")?.state == .cancelled
        }, detail: describe())

        // Asking shows the save panel as a sheet; cancelling it cancels the download.
        profile.downloadPolicy = .ask
        browser.load(URL(string: "\(base)/asked.txt")!)
        let hostWindow = browser.hostWindow
        _ = await waitUntil(timeout: .seconds(10)) { hostWindow?.attachedSheet is NSSavePanel }
        let panel = hostWindow?.attachedSheet as? NSSavePanel
        check("download: asking shows a save panel named for the file", panel?.nameFieldStringValue == "asked.txt",
              detail: "\(String(describing: hostWindow?.attachedSheet))")
        panel?.cancel(nil)
        check("download: cancelling the panel cancels the download", await waitUntil {
            download(named: "asked.txt")?.state == .cancelled
        }, detail: describe())

        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: beforeunload

    static func leavingChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/leave.html")!, delegate: recorder)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await loaded(browser, title: "leave")
        // beforeunload needs the page to have seen a user gesture.
        _ = try? await browser.evaluateJavaScript("document.body.click(); 0", userGesture: true)

        recorder.leavesPage = false
        window.close()
        check("beforeunload: the delegate is asked on close", await waitUntil { recorder.leaveRequests == 1 })
        try? await Task.sleep(for: .milliseconds(500))
        check("beforeunload: staying keeps the window open", !window.isClosed && browser.state == .live)

        recorder.leavesPage = true
        window.close()
        check("beforeunload: leaving closes the window", await waitUntil { window.isClosed })
    }

    // MARK: Load errors

    static func loadFailureChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "https://nonexistent.invalid/")!, delegate: recorder)
        let window = CefWindow(browser: browser)
        window.show()
        check("load error: reported through didFailLoad",
              await waitUntil { recorder.loadErrors.contains { !$0.isCancellation } },
              detail: "\(recorder.loadErrors)")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Renderer crashes

    static func rendererCrashChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, delegate: recorder)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await loaded(browser, title: "tab")
        browser.load(URL(string: "chrome://crash")!)
        check("renderer crash: delegate is told", await waitUntil { !recorder.terminations.isEmpty })
        browser.load(URL(string: "selftest://edge/tab.html?again")!)
        check("renderer crash: loading again recovers", await waitUntil {
            browser.title == "tab" && browser.url?.query() == "again"
        }, detail: browser.title)
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Chromium's settings

    /// Mirrors part of `BrowserController.internalPageStyles` in the
    /// Browser example. The appearance page's rows live in a component that
    /// sets its own `adoptedStyleSheets` after attaching its shadow root.
    static let settingsStyles = """
        #about-menu, a[href="/people"], a[href="/syncSetup"], a[href="/defaultBrowser"],
        settings-people-page-index, settings-default-browser-page,
        settings-about-page #updateStatusMessage, settings-about-page #relaunch,
        #themeRow, settings-toggle-button[pref-key="browser.show_home_button"], .cr-row:has(> #tabStripPosition)
        { display: none !important }
        """

    static func settingsPageChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.userScripts = [.styleSheet(settingsStyles, matching: "chrome://settings/*")]
        let browser = CefBrowser(url: URL(string: "chrome://settings/")!, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "Settings" && !browser.isLoading }
        let visibility = """
            (() => {
              const deepAll = (sel, root = document) => [...root.querySelectorAll(sel)].concat(
                ...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deepAll(sel, e.shadowRoot)));
              const shown = sel => deepAll(sel).some(e => e.getClientRects().length > 0);
              return [shown('#about-menu'), shown('a[href="/people"]'), shown('a[href="/defaultBrowser"]'),
                      shown('a[href="/appearance"]'), shown('settings-people-page-index')].join();
            })()
            """
        _ = await waitUntilAsync {
            (try? await browser.evaluateJavaScript(visibility).stringValue)?.contains("true") == true
        }
        let shown = (try? await browser.evaluateJavaScript(visibility).stringValue) ?? ""
        check("settings: About, You and Google and Default browser are hidden; the rest shows",
              shown == "false,false,false,true,false", detail: shown)

        // Components that assign their own adoptedStyleSheets keep the sheet.
        browser.load(URL(string: "chrome://settings/appearance")!)
        let appearance = """
            (() => {
              const deepAll = (sel, root = document) => [...root.querySelectorAll(sel)].concat(
                ...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deepAll(sel, e.shadowRoot)));
              const shown = sel => deepAll(sel).some(e => e.getClientRects().length > 0);
              return [shown('#themeRow'), shown('settings-toggle-button[pref-key="browser.show_home_button"]'),
                      shown('#tabStripPosition'), shown('#zoomLevel')].join();
            })()
            """
        _ = await waitUntilAsync {
            (try? await browser.evaluateJavaScript(appearance).stringValue)?.hasSuffix("true") == true
        }
        let appearanceShown = (try? await browser.evaluateJavaScript(appearance).stringValue) ?? ""
        check("settings: styles reach components that set their own adoptedStyleSheets",
              appearanceShown == "false,false,false,true", detail: appearanceShown)

        // The password manager link opens a tab Chromium creates itself.
        var opened: [URL] = []
        var sawChromiumWindow = false
        CefRuntime.shared.onChromeTab = { opened.append($0.url); return .close }
        defer { CefRuntime.shared.onChromeTab = nil }
        browser.load(URL(string: "chrome://settings/autofill")!)
        _ = await waitUntil { browser.title.contains("Autofill") && !browser.isLoading }
        _ = await waitUntilAsync {
            (try? await browser.evaluateJavaScript("""
                (() => {
                  const deepAll = (sel, root = document) => [...root.querySelectorAll(sel)].concat(
                    ...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deepAll(sel, e.shadowRoot)));
                  const row = deepAll('#passwordManagerButton')[0];
                  if (row) row.click();
                  return !!row;
                })()
                """).boolValue) == true
        }
        let ours = Set(CefWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
        let arrived = await waitUntil {
            sawChromiumWindow = sawChromiumWindow || NSApp.windows.contains {
                $0.isVisible && $0.alphaValue > 0.05 && $0.styleMask.contains(.titled) && $0.parent == nil
                    && $0 !== SelfTest.window && !ours.contains(ObjectIdentifier($0))
            }
            return !opened.isEmpty
        }
        check("Chromium's own tab is handed over", arrived && opened.first?.host() == "password-manager",
              detail: "\(opened)")
        try? await Task.sleep(for: .milliseconds(500))
        check("Chromium's own tab never shows its window", !sawChromiumWindow)
        window.close()
        _ = await waitUntil { window.isClosed }
    }
}

/// Records what a browser reports and answers its questions.
@MainActor
final class Recorder: CefBrowserDelegate {
    var downloadDestination: URL?
    /// Leaves downloads to the profile's policy instead of ``downloadDestination``.
    var followsDownloadPolicy = false
    var leavesPage = true
    var credential: CefCredential?
    /// Answers to give before ``credential``, one per challenge.
    var credentialQueue: [CefCredential?] = []
    private(set) var leaveRequests = 0
    private(set) var loadErrors: [CefLoadError] = []
    private(set) var challenges: [CefAuthenticationChallenge] = []
    private(set) var terminations: [CefTerminationReason] = []

    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
        if followsDownloadPolicy { return .default(for: download) }
        return downloadDestination.map { .save(to: $0.appendingPathComponent(download.suggestedFilename)) } ?? .cancel
    }

    func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool {
        leaveRequests += 1
        return leavesPage
    }

    func browser(_ browser: CefBrowser, didFailLoad error: CefLoadError) {
        loadErrors.append(error)
    }

    func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential? {
        challenges.append(challenge)
        return credentialQueue.isEmpty ? credential : credentialQueue.removeFirst()
    }

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        terminations.append(reason)
    }
}

/// Pages for the behavior checks, at `selftest://edge/…`.
struct EdgePages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let path = request.url?.path ?? ""
        switch path {
        case "/slow.html":
            try? await Task.sleep(for: .seconds(4))
            return Self.page("<title>slow</title>")
        case "/icon.png":
            return CefSchemeResponse(mimeType: "image/png", body: Self.iconPNG)
        case "/favicon.html":
            return Self.page("<title>favicon</title><link rel=icon href=icon.png><p>favicon</p>")
        case "/heavy.html":
            // A tall page whose `__allocate()` dirties 200 MB in its renderer.
            return Self.page("""
                <title>heavy</title><link rel=icon href=icon.png><div style="height: 5000px">heavy</div>
                <script>window.__allocate = () => (window.__heavy = new Float64Array(25e6).fill(1.5)).length;</script>
                """)
        case "/leave.html":
            return Self.page("""
                <title>leave</title><p>leave</p>
                <script>addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; });</script>
                """)
        default:
            let name = path.dropFirst().split(separator: ".").first.map(String.init) ?? "page"
            return Self.page("<title>\(name)</title><p>\(name)</p>")
        }
    }

    /// A solid red 32 × 32 PNG.
    static let iconPNG: Data = {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<32 { for y in 0..<32 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        return bitmap.representation(using: .png, properties: [:])!
    }()

    private static func page(_ html: String) -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
