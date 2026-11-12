import AppKit
import CefSwiftUI

/// Passkeys answered by the app (`CefPasskeyMode.app`), in both browser
/// styles, on a page served from `http://localhost`, which WebAuthn treats
/// as a secure context. The store is in memory: nothing touches the
/// keychain.
extension SelfTest {
    static func passkeyChecks() async {
        guard let server = try? await LocalServer.start() else {
            print("SKIP passkeys: could not start a local HTTP server")
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://localhost:\(server.port)/passkeys.html")!
        let watcher = ChromiumDialogWatcher()
        await passkeyRoundTrip(style: "Alloy", url: url, watcher: watcher)
        await passkeyRoundTrip(style: "Chrome style", url: url, watcher: watcher)
        await disabledPasskeyChecks(url: url)
        check("passkeys: Chromium's WebAuthn dialog never appears", !watcher.sawDialog, detail: watcher.titles.joined(separator: ", "))
        watcher.stop()
        await passkeySettingsChecks()
    }

    private static func passkeyRoundTrip(style: String, url: URL, watcher: ChromiumDialogWatcher) async {
        let store = CefInMemoryPasskeyStore()
        let policy = PasskeyPolicy()
        var options = CefBrowserOptions()
        options.passkeys = .app(store)
        let browser = CefBrowser(url: url, options: options, delegate: policy)
        var window: CefBrowserWindow?
        var view: CefWindowedBrowserView?
        if style == "Alloy" {
            let hosted = CefWindowedBrowserView()
            hosted.frame = SelfTest.window.contentView!.bounds
            SelfTest.window.contentView!.addSubview(hosted)
            hosted.browser = browser
            view = hosted
        } else {
            window = CefBrowserWindow(browser: browser)
            window?.show()
        }
        defer {
            browser.close(force: true)
            window?.close()
            view?.removeFromSuperview()
        }
        guard await waitUntil(timeout: .seconds(20), { browser.title == "passkeys" && !browser.isLoading }) else {
            check("passkeys (\(style)): page loads", false, detail: browser.title)
            return
        }
        let name = "passkeys (\(style))"

        policy.answer = { _ in .createPasskey }
        let created = await PasskeyCall.run(browser, "register()")
        // The store hears of the passkey as the page does.
        _ = await waitUntilAsync(timeout: .seconds(3)) { (try? await store.passkeys())?.isEmpty == false }
        let saved = (try? await store.passkeys()) ?? []
        check("\(name): registration is answered by the app's authenticator",
              created.ok && saved.count == 1 && saved.first?.id.base64URLString == created.id,
              detail: "\(created) \(saved.count) saved")
        check("\(name): the saved passkey has the site's account",
              saved.first?.relyingPartyID == "localhost" && saved.first?.userName == "ada@example.com"
                  && saved.first?.userHandle == Data([1, 2, 3, 4]) && saved.first?.privateKey.isEmpty == false)
        let registration = policy.requests.last
        check("\(name): the delegate hears the registration with its origin",
              registration?.kind == .registration && registration?.origin == "http://localhost:\(server(url))"
                  && registration?.isMainFrame == true,
              detail: "\(String(describing: registration))")

        policy.answer = { request in request.passkeys.first.map { .signIn(with: $0) } ?? .deny }
        let signedIn = await PasskeyCall.run(browser, "signIn()")
        check("\(name): sign-in uses the saved passkey",
              signedIn.ok && signedIn.id == created.id && signedIn.user == Data([1, 2, 3, 4]).base64URLString,
              detail: "\(signedIn)")
        check("\(name): the assertion request lists the usable passkeys",
              policy.requests.last?.kind == .assertion && policy.requests.last?.passkeys.map(\.id) == saved.map(\.id))
        _ = await waitUntilAsync(timeout: .seconds(3)) { (try? await store.passkeys())?.first?.lastUsedDate != nil }
        let used = (try? await store.passkeys())?.first
        check("\(name): the store keeps the new sign count",
              (used?.signCount ?? 0) > (saved.first?.signCount ?? 0) && used?.lastUsedDate != nil,
              detail: "\(String(describing: used?.signCount))")

        policy.answer = { _ in .deny }
        let start = ContinuousClock.now
        let denied = await PasskeyCall.run(browser, "signIn()")
        check("\(name): a refusal rejects at once",
              !denied.ok && denied.error == "NotAllowedError" && ContinuousClock.now - start < .seconds(5),
              detail: "\(denied)")

        if style == "Alloy" {
            // A user gesture reaches the delegate; a waiting, ignored request
            // does not keep a later one from being answered.
            policy.answer = { request in request.hasUserGesture ? (request.passkeys.first.map { .signIn(with: $0) } ?? .deny) : .ignore }
            browser.executeJavaScript("window.__waiting = signIn({ timeout: 60000 })")
            _ = await waitUntil(timeout: .seconds(5)) { policy.requests.last?.hasUserGesture == false && policy.requests.count == 4 }
            let clicked = await PasskeyCall.click(browser)
            check("\(name): a click's request carries its user gesture",
                  policy.requests.last?.hasUserGesture == true && clicked.ok, detail: "\(clicked)")

            browser.reload()
            _ = await waitUntil { browser.isLoading }
            _ = await waitUntil { !browser.isLoading }
            policy.answer = { request in request.passkeys.first.map { .signIn(with: $0) } ?? .deny }
            let afterReload = await PasskeyCall.run(browser, "signIn()")
            check("\(name): a new document is watched too", afterReload.ok, detail: "\(afterReload)")
        } else {
            if let passkey = saved.first { try? await store.remove(passkey) }
            check("\(name): removing from the store", (try? await store.passkeys())?.isEmpty == true)
            policy.answer = { request in request.passkeys.isEmpty ? .deny : .signIn(with: request.passkeys[0]) }
            let removed = await PasskeyCall.run(browser, "signIn()")
            check("\(name): a removed passkey is no longer offered",
                  !removed.ok && policy.requests.last?.passkeys.isEmpty == true, detail: "\(removed)")
        }
    }

    private static func disabledPasskeyChecks(url: URL) async {
        let policy = PasskeyPolicy()
        var options = CefBrowserOptions()
        options.passkeys = .disabled
        let browser = CefBrowser(url: url, options: options, delegate: policy)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil(timeout: .seconds(20)) { browser.title == "passkeys" && !browser.isLoading }
        let start = ContinuousClock.now
        let result = await PasskeyCall.run(browser, "register()")
        check("passkeys (disabled): requests are refused without asking",
              !result.ok && result.error == "NotAllowedError" && policy.requests.isEmpty
                  && ContinuousClock.now - start < .seconds(5),
              detail: "\(result)")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// The Passkeys button in Chrome's autofill settings opens a tab of
    /// Chromium's own; it must reach `onChromiumOpensTab`, not a window.
    private static func passkeySettingsChecks() async {
        var opened: [URL] = []
        CefRuntime.shared.onChromiumOpensTab = { opened.append($0) }
        defer { CefRuntime.shared.onChromiumOpensTab = nil }
        let browser = CefBrowser(url: URL(string: "chrome://settings/autofill")!)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title.contains("Autofill") && !browser.isLoading }
        let clicked = await waitUntilAsync {
            (try? await browser.evaluateJavaScript("""
                (() => {
                  const deepAll = (sel, root = document) => [...root.querySelectorAll(sel)].concat(
                    ...[...root.querySelectorAll('*')].filter(e => e.shadowRoot).map(e => deepAll(sel, e.shadowRoot)));
                  const button = deepAll('cr-button').find(b => b.innerText.trim() === 'Passkeys');
                  if (button) button.click();
                  return !!button;
                })()
                """).boolValue) == true
        }
        let ours = Set(CefBrowserWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
        var sawWindow = false
        let arrived = await waitUntil {
            sawWindow = sawWindow || NSApp.windows.contains {
                $0.isVisible && $0.alphaValue > 0.05 && $0.styleMask.contains(.titled) && $0.parent == nil
                    && $0 !== SelfTest.window && !ours.contains(ObjectIdentifier($0))
            }
            return !opened.isEmpty
        }
        check("passkeys: the settings Passkeys button hands its tab over",
              clicked && arrived && opened.first?.host() == "password-manager" && !sawWindow,
              detail: "\(opened)")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    private static func server(_ url: URL) -> Int { url.port ?? 0 }
}

enum PasskeyChecks {
    /// The test page. Each call reports its outcome instead of throwing.
    static let page = """
        <!doctype html><title>passkeys</title>
        <button id=go style="position:fixed;left:0;top:0;width:300px;height:200px">Sign in</button>
        <script>
          const b64 = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer)))
            .replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
          const report = promise => promise.then(
            c => ({ ok: true, id: c.id, user: c.response.userHandle ? b64(c.response.userHandle) : null }),
            e => ({ ok: false, error: e.name, message: e.message }));
          function register() {
            return report(navigator.credentials.create({ publicKey: {
              challenge: new Uint8Array(32), rp: { name: 'SelfTest', id: 'localhost' },
              user: { id: new Uint8Array([1, 2, 3, 4]), name: 'ada@example.com', displayName: 'Ada' },
              pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
              authenticatorSelection: { residentKey: 'required', userVerification: 'preferred' },
              timeout: 15000 } }));
          }
          function signIn(extra) {
            return report(navigator.credentials.get({ publicKey: Object.assign({
              challenge: new Uint8Array(32), rpId: 'localhost', userVerification: 'preferred', timeout: 15000 }, extra) }));
          }
          document.getElementById('go').onclick = () => { window.__clicked = signIn(); };
        </script>
        """
}

/// Answers passkey requests as a test says, and records them.
@MainActor
final class PasskeyPolicy: CefBrowserDelegate {
    var answer: (CefPasskeyRequest) -> CefPasskeyDecision = { _ in .deny }
    private(set) var requests: [CefPasskeyRequest] = []

    func browser(_ browser: CefBrowser, decidePasskeyRequest request: CefPasskeyRequest) async -> CefPasskeyDecision {
        requests.append(request)
        return answer(request)
    }
}

/// The outcome of a WebAuthn call on the test page.
struct PasskeyCall: Decodable, CustomStringConvertible {
    var ok = false
    var id: String?
    var user: String?
    var error: String?
    var message: String?

    var description: String { ok ? "ok \(id ?? "")" : "\(error ?? "?"): \(message ?? "")" }

    @MainActor static func run(_ browser: CefBrowser, _ script: String) async -> PasskeyCall {
        do {
            return try await browser.evaluateJavaScript(script, as: PasskeyCall.self)
        } catch {
            return PasskeyCall(error: "evaluate", message: "\(error)")
        }
    }

    /// Clicks the page's Sign In button, as the user would, and returns
    /// what the click's call gave.
    @MainActor static func click(_ browser: CefBrowser) async -> PasskeyCall {
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": .string(type), "x": 40, "y": 40, "button": "left", "clickCount": 1,
            ])
        }
        return await run(browser, "window.__clicked ?? Promise.resolve({ ok: false, error: 'not clicked' })")
    }
}

/// Watches for the window Chromium opens for its own WebAuthn dialog,
/// whose title names the site ("Use your security key with localhost").
@MainActor
final class ChromiumDialogWatcher {
    private(set) var sawDialog = false
    private(set) var titles: [String] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    private func look() {
        for window in NSApp.windows where window.isVisible && !window.title.isEmpty
            && String(describing: type(of: window)).contains("NativeWidget") {
            sawDialog = true
            if !titles.contains(window.title) { titles.append(window.title) }
        }
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }
}

extension Data {
    fileprivate var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
