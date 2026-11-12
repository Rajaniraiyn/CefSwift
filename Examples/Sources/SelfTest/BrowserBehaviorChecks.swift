import AppKit
import CefSwiftUI
import Network

/// Checks of what a browser built on `CefBrowserWindow` relies on: popups,
/// closing in awkward moments, downloads, `beforeunload`, load errors,
/// authentication, renderer crashes and Chromium's own pages.
extension SelfTest {
    static func browserBehaviorChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "edge", handler: EdgePages())
        await bridgeRoundTripChecks()
        await popupChecks()
        await closingChecks()
        await downloadChecks()
        await leavingChecks()
        await loadFailureChecks()
        await authenticationChecks()
        await rendererCrashChecks()
        await settingsPageChecks()
        // "Hold ⌘Q to Quit" is an application-wide setting, not a profile's.
        check("preference: configured application-wide preference applied",
              CefRuntime.shared.preference("browser.confirm_to_quit")?.boolValue == false,
              detail: "\(String(describing: CefRuntime.shared.preference("browser.confirm_to_quit")))")
    }

    // MARK: Bridge, as the Showcase uses it

    static func bridgeRoundTripChecks() async {
        var total = 0
        let counter = CefBridge(name: "counter")
        counter.handle("increment") { (amount: Int) -> Int in
            total += amount
            return total
        }
        var options = CefBrowserOptions()
        options.bridges = [counter]
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, options: options)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "tab" }
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
        let opener = CefBrowserWindow(browser: browser)
        var popups: [CefBrowserWindow] = []
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
        _ = await waitUntil { browser.title == "opener" }

        await expect("popup: requested size is reported") {
            try await browser.evaluateJavaScript("window.__popup = window.open('popup.html', 'p', 'width=420,height=360'); 0")
            guard await waitUntil(timeout: .seconds(5), { popups.count == 1 }) else { return false }
            return popups[0].browser.popupFeatures?.size == CGSize(width: 420, height: 360)
        }
        check("popup: is a child window of its opener",
              popups.first?.window.map { opener.window?.childWindows?.contains($0) == true } == true)
        await expect("popup: page calling window.close() closes it") {
            guard let popup = popups.first else { return false }
            _ = await waitUntil { popup.browser.title == "popup" }
            try await popup.browser.evaluateJavaScript("setTimeout(() => window.close(), 10); 0")
            return await waitUntil { popup.isClosed }
        }
        check("popup: leaves its opener's child windows", opener.window?.childWindows?.isEmpty != false)

        await expect("popup: closing the opener with a popup open is clean") {
            try await browser.evaluateJavaScript("window.open('popup.html', 'q', 'width=300,height=200'); 0")
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
        let loading = CefBrowserWindow(browser: slow)
        loading.show()
        _ = await waitUntil(timeout: .seconds(3)) { slow.isLoading }
        loading.close()
        check("closing: a window still loading closes", await waitUntil { loading.isClosed && slow.state == .closed })

        let windows = (0..<8).map { index in
            CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/tab.html?\(index)")!))
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
            print("SKIP download: could not start a local HTTP server")
            return
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-downloads-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        recorder.downloadDestination = directory
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "tab" }

        browser.load(URL(string: "http://127.0.0.1:\(server.port)/report.txt")!)
        check("download: attachment is saved where the delegate says", await waitUntil {
            browser.downloads.contains { $0.isComplete && $0.destinationURL?.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent }
        }, detail: "\(browser.downloads)")
        check("download: page stays put", browser.title == "tab")

        recorder.downloadDestination = nil
        browser.load(URL(string: "http://127.0.0.1:\(server.port)/denied.txt")!)
        check("download: denied download is cancelled", await waitUntil {
            browser.downloads.contains { $0.url?.lastPathComponent == "denied.txt" && $0.isCancelled }
        }, detail: "\(browser.downloads)")

        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: beforeunload

    static func leavingChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/leave.html")!, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "leave" }
        // beforeunload needs the page to have seen a user gesture.
        _ = try? await browser.evaluateJavaScript("document.body.click(); 0")

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
        let window = CefBrowserWindow(browser: browser)
        window.show()
        check("load error: reported through didFailLoad",
              await waitUntil { recorder.loadErrors.contains { !$0.isCancellation } },
              detail: "\(recorder.loadErrors)")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Authentication

    static func authenticationChecks() async {
        guard let server = try? await LocalServer.start() else {
            print("SKIP authentication: could not start a local HTTP server")
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/private")!

        let recorder = Recorder()
        recorder.credential = CefCredential(username: "ada", password: "lovelace")
        let browser = CefBrowser(url: url, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        // CEF 156 does not consult the request handler for HTTP auth: Chrome
        // style shows Chromium's own sign-in dialog, as a child window.
        check("authentication: Chromium's sign-in dialog appears",
              await waitUntil { window.window?.childWindows?.isEmpty == false })
        check("bubbles: sign-in dialog recognized",
              await waitUntil { window.chromiumBubbles.contains { $0.kind == .signIn } },
              detail: "\(window.chromiumBubbles.map { "\($0.kind) '\($0.title)'" })")
        if let signIn = window.chromiumBubbles.first(where: { $0.kind == .signIn }) {
            signIn.dismiss()
            check("bubbles: dismissing the sign-in dialog cancels it",
                  await waitUntil { !signIn.isVisible && window.chromiumBubbles.isEmpty && browser.title == "denied" },
                  detail: browser.title)
        }
        if recorder.challenges.isEmpty {
            print("SKIP authentication: CEF does not call credentialFor (Chromium's dialog asks instead)")
        } else {
            check("authentication: delegate answers the challenge", await waitUntil { browser.title == "authorized" })
        }
        window.close()
        check("authentication: window with the dialog open closes", await waitUntil { window.isClosed })

        // An embedded (Alloy-style) browser: CEF 156 does not ask the
        // delegate either. The load fails with ERR_INVALID_AUTH_CREDENTIALS
        // and Chromium shows its sign-in window on its own.
        let embeddedRecorder = Recorder()
        embeddedRecorder.credential = recorder.credential
        let embedded = CefBrowser(url: url, delegate: embeddedRecorder)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = embedded
        let failed = await waitUntil { embeddedRecorder.loadErrors.contains { $0.code == -338 } || embedded.title == "authorized" }
        if embeddedRecorder.challenges.isEmpty {
            check("authentication (embedded): fails with ERR_INVALID_AUTH_CREDENTIALS, delegate not asked",
                  failed && embedded.title != "authorized", detail: "\(embeddedRecorder.loadErrors)")
        } else {
            check("authentication (embedded): delegate answers the challenge",
                  await waitUntil { embedded.title == "authorized" })
        }
        try? await Task.sleep(for: .milliseconds(500))
        embedded.close(force: true)
        check("authentication (embedded): closing with Chromium's sign-in window open is clean", await waitUntil {
            embedded.state == .closed && !NSApp.windows.contains { $0.isVisible && $0.title == "Sign in" }
        }, detail: "\(NSApp.windows.filter(\.isVisible).map(\.title))")
        view.removeFromSuperview()
    }

    // MARK: Renderer crashes

    static func rendererCrashChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "tab" }
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
        var options = CefBrowserOptions()
        options.userScripts = [.styleSheet(settingsStyles, matching: "chrome://settings/*")]
        let browser = CefBrowser(url: URL(string: "chrome://settings/")!, options: options)
        let window = CefBrowserWindow(browser: browser)
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
        CefRuntime.shared.onChromiumOpensTab = { opened.append($0) }
        defer { CefRuntime.shared.onChromiumOpensTab = nil }
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
        let ours = Set(CefBrowserWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
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
    var leavesPage = true
    var credential: CefCredential?
    private(set) var leaveRequests = 0
    private(set) var loadErrors: [CefLoadError] = []
    private(set) var challenges: [CefAuthenticationChallenge] = []
    private(set) var terminations: [CefTerminationReason] = []

    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision {
        downloadDestination.map { .allow(destination: $0.appendingPathComponent(suggestedName)) } ?? .deny
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
        return credential
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

/// A local HTTP server. `/private` wants Basic credentials `ada:lovelace`;
/// `*.txt` is served as an attachment and `/page` as a plain page.
final class LocalServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = LocalServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let head: String, body: String
                if path.hasSuffix(".txt") {
                    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                        + "Content-Disposition: attachment; filename=\"\(path.dropFirst())\"\r\n"
                    body = String(repeating: "CefSwift\n", count: 2048)
                } else if path == "/page" {
                    head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                    body = "<title>page</title><p>A page on http, which Chrome's QR code generator accepts.</p>"
                } else if request.contains("Authorization: Basic \(Data("ada:lovelace".utf8).base64EncodedString())") {
                    head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                    body = "<title>authorized</title>ok"
                } else {
                    head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: text/html\r\nWWW-Authenticate: Basic realm=\"selftest\"\r\n"
                    body = "<title>denied</title>denied"
                }
                let response = head + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                // Close the write side after the response; the client closes the rest.
                connection.send(
                    content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { connection.cancel() }
                    })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    server.port = server.listener.port?.rawValue ?? 0
                    continuation.resume(returning: server)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            server.listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
    }
}
