import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// HTTP authentication: the delegate's `credentialFor` in both runtime
/// styles and for a proxy, the default sheet, and, in a probe,
/// `CefAuthenticationPrompt.chromium`.
extension SelfTest {
    static func authenticationChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("authentication", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/private")!
        let right = CefCredential(username: "ada", password: "lovelace")

        // Chrome style: a refused password, then the right one.
        let recorder = Recorder()
        recorder.credentialQueue = [CefCredential(username: "ada", password: "wrong")]
        recorder.credential = right
        let browser = CefBrowser(url: url, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        check("authentication: the delegate answers the challenge (Chrome style)",
              await waitUntil { browser.title == "authorized" }, detail: "title '\(browser.title)', \(recorder.challenges)")
        let expected = CefAuthenticationChallenge(
            origin: url.absoluteString, isProxy: false, host: "127.0.0.1", port: Int(server.port),
            realm: "selftest", scheme: "basic")
        check("authentication: the challenge names the server, realm and scheme",
              recorder.challenges.first == expected, detail: "\(recorder.challenges)")
        check("authentication: a refused password asks the delegate again",
              recorder.challenges.count == 2 && recorder.challenges.allSatisfy { $0 == expected },
              detail: "\(recorder.challenges.count) challenges")
        check("authentication: Chromium shows no sign-in dialog of its own",
              !window.chromiumSurfaces.contains { $0.kind == .signIn } && window.window?.childWindows?.isEmpty != false,
              detail: "\(window.chromiumSurfaces.map(\.kind))")

        // Cancelling shows the server's own 401 page.
        let cancelling = Recorder()
        browser.delegate = cancelling
        browser.load(URL(string: "http://localhost:\(server.port)/private")!)
        check("authentication: answering nil cancels the sign-in",
              await waitUntil { browser.title == "denied" } && cancelling.challenges.count == 1,
              detail: "title '\(browser.title)', \(cancelling.challenges.count) challenges")

        // Without a delegate: the native sheet, dismissed when the browser
        // navigates away.
        browser.delegate = nil
        browser.load(URL(string: "http://localhost:\(server.port)/private?sheet")!)
        let sheetShown = await waitUntil { window.window?.attachedSheet != nil }
        check("authentication: without a delegate, a native sheet asks", sheetShown)
        browser.load(URL(string: "selftest://edge/tab.html")!)
        check("authentication: the sheet dismisses itself when the page navigates away",
              await waitUntil { window.window?.attachedSheet == nil && browser.title == "tab" }
                && browser.pendingDecisionCount == 0,
              detail: "title '\(browser.title)', \(browser.pendingDecisionCount) pending")
        window.close()
        check("authentication: the window closes", await waitUntil { window.isClosed })

        // Alloy style (embedded): the delegate is asked as well.
        let embeddedRecorder = Recorder()
        embeddedRecorder.credential = right
        // A profile of its own: Chromium keeps the credentials it was given
        // for the server, and would not ask again.
        var embeddedOptions = CefBrowserOptions()
        embeddedOptions.profile = .incognito()
        let embedded = CefBrowser(url: url, options: embeddedOptions, delegate: embeddedRecorder)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = embedded
        check("authentication (embedded): the delegate answers the challenge",
              await waitUntil { embedded.title == "authorized" } && embeddedRecorder.challenges.count == 1,
              detail: "title '\(embedded.title)', \(embeddedRecorder.loadErrors)")
        check("authentication (embedded): the load does not fail first",
              !embeddedRecorder.loadErrors.contains { $0.code == -338 }, detail: "\(embeddedRecorder.loadErrors)")
        // Closing while the default sheet asks.
        embedded.delegate = nil
        embedded.load(URL(string: "http://localhost:\(server.port)/private?close")!)
        let embeddedSheet = await waitUntil { SelfTest.window.attachedSheet != nil }
        check("authentication (embedded): without a delegate, a native sheet asks", embeddedSheet)
        embedded.close(force: true)
        check("authentication (embedded): closing while the sheet asks is clean", await waitUntil {
            embedded.state == .closed && SelfTest.window.attachedSheet == nil
        }, detail: "state \(embedded.state), sheet \(String(describing: SelfTest.window.attachedSheet))")
        view.removeFromSuperview()

        await proxyAuthenticationChecks(server: server)

        // Chromium's own dialog, in a second instance.
        await runProbe("chromiumSignIn", label: "authentication (.chromium)")
    }

    /// A proxy that wants credentials: the challenge says so.
    static func proxyAuthenticationChecks(server: LocalServer) async {
        let profile = CefProfile.incognito()
        var options = CefBrowserOptions()
        options.profile = profile
        let recorder = Recorder()
        recorder.credential = CefCredential(username: "grace", password: "hopper")
        let browser = CefBrowser(url: URL(string: "about:blank")!, options: options, delegate: recorder)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil({ browser.state == .live && !browser.isLoading }) else {
            check("authentication (proxy): browser starts", false)
            return
        }
        do {
            try profile.setPreference("proxy", to: ["mode": "fixed_servers", "server": .string("127.0.0.1:\(server.port)")])
        } catch {
            check("authentication (proxy): the profile takes the proxy", false, detail: "\(error)")
            return
        }
        browser.load(URL(string: "http://proxied.invalid/")!)
        check("authentication (proxy): the delegate answers the proxy's challenge",
              await waitUntil { browser.title == "proxied" }, detail: "title '\(browser.title)', \(recorder.challenges)")
        check("authentication (proxy): the challenge is the proxy's",
              recorder.challenges.first.map {
                  $0.isProxy && $0.host == "127.0.0.1" && $0.port == Int(server.port) && $0.realm == "selftest-proxy"
              } == true,
              detail: "\(recorder.challenges)")
    }

    /// The probe: `CefAuthenticationPrompt.chromium`. Chromium's dialog
    /// asks instead of the delegate.
    static func chromiumSignInProbeChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("sign-in", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/private")!

        let recorder = Recorder()
        recorder.credential = CefCredential(username: "ada", password: "lovelace")
        let browser = CefBrowser(url: url, delegate: recorder)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        check("Chromium's sign-in dialog appears",
              await waitUntil { window.window?.childWindows?.isEmpty == false })
        check("surfaces: sign-in dialog recognized",
              await waitUntil { window.chromiumSurfaces.contains { $0.kind == .signIn } },
              detail: "\(window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })")
        if let signIn = window.chromiumSurfaces.first(where: { $0.kind == .signIn }) {
            signIn.dismiss()
            check("surfaces: dismissing the sign-in dialog cancels it",
                  await waitUntil { signIn.window?.isVisible != true && window.chromiumSurfaces.isEmpty && browser.title == "denied" },
                  detail: browser.title)
        }
        check("the delegate is not asked", recorder.challenges.isEmpty, detail: "\(recorder.challenges)")
        window.close()
        check("window with the dialog open closes", await waitUntil { window.isClosed })

        // Alloy style: the load fails with ERR_INVALID_AUTH_CREDENTIALS and
        // Chromium shows its sign-in window on its own.
        let embeddedRecorder = Recorder()
        let embedded = CefBrowser(url: url, delegate: embeddedRecorder)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = embedded
        let failed = await waitUntil { embeddedRecorder.loadErrors.contains { $0.code == -338 } }
        check("embedded: fails with ERR_INVALID_AUTH_CREDENTIALS, delegate not asked",
              failed && embeddedRecorder.challenges.isEmpty, detail: "\(embeddedRecorder.loadErrors)")
        try? await Task.sleep(for: .milliseconds(500))
        embedded.close(force: true)
        check("embedded: closing with Chromium's sign-in window open is clean", await waitUntil {
            embedded.state == .closed && !NSApp.windows.contains { $0.isVisible && $0.title == "Sign in" }
        }, detail: "\(NSApp.windows.filter(\.isVisible).map(\.title))")
        view.removeFromSuperview()
    }
}
