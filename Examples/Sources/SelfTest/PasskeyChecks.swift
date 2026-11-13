import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Passkeys answered by the app (`CefBrowser.PasskeyPolicy.app`), in both browser
/// styles, on a page served from `http://localhost`, which WebAuthn treats
/// as a secure context. The store is in memory: nothing touches the
/// keychain.
extension SelfTest {
    static func passkeyChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("passkeys", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://localhost:\(server.port)/passkeys.html")!
        let watcher = ChromiumDialogWatcher()
        await passkeyRoundTrip(style: "Alloy", url: url, watcher: watcher)
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
        await passkeyRoundTrip(style: "Chrome style", url: url, watcher: watcher)
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
        await disabledPasskeyChecks(url: url)
        await passkeyStoreFailureChecks(url: url)
        await passkeyDecisionCancellationChecks(url: url)
        await popupPasskeyChecks(url: url)
        check("passkeys: Chromium's WebAuthn dialog never appears", !watcher.sawDialog, detail: watcher.titles.joined(separator: ", "))
        watcher.stop()
        await passkeySettingsChecks()
    }

    private static func passkeyRoundTrip(style: String, url: URL, watcher: ChromiumDialogWatcher) async {
        let store = CefInMemoryPasskeyStore()
        let policy = PasskeyPolicy()
        var configuration = CefBrowser.Configuration()
        configuration.passkeys = .app(store)
        let browser = CefBrowser(url: url, configuration: configuration, delegate: policy)
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
            // Chromium allows one pending request per frame, so the ignored
            // one times out (Chromium waits at least 10 seconds) before the click.
            browser.executeJavaScript("window.__waiting = signIn({ timeout: 1000 })")
            _ = await waitUntil(timeout: .seconds(5)) { policy.requests.last?.hasUserGesture == false && policy.requests.count == 4 }
            _ = await waitUntilAsync(timeout: .seconds(15)) {
                (try? await browser.evaluateJavaScript("window.__waiting.then(() => true, () => true)").boolValue) == true
            }
            let clicked = await PasskeyCall.click(browser)
            check("\(name): a click's request carries its user gesture",
                  policy.requests.last?.hasUserGesture == true && clicked.ok, detail: "\(clicked)")

            browser.reload()
            _ = await waitUntil { browser.isLoading }
            _ = await waitUntil { !browser.isLoading }
            policy.answer = { request in request.passkeys.first.map { .signIn(with: $0) } ?? .deny }
            let afterReload = await PasskeyCall.run(browser, "signIn()")
            check("\(name): a new document is watched too", afterReload.ok, detail: "\(afterReload)")

            // Discarding closes an Alloy browser's Chromium browser; the
            // new one must be set up again.
            view?.isHidden = true
            let discarded = (try? await browser.discard()) != nil && browser.isDiscarded
            view?.isHidden = false
            _ = await waitUntil { !browser.isDiscarded && !browser.isLoading && browser.title == "passkeys" }
            let afterRestore = await PasskeyCall.run(browser, "signIn()")
            check("\(name): the app still answers after a discard and restore",
                  discarded && afterRestore.ok, detail: "discarded: \(discarded), \(afterRestore)")

            // A call from the first script of a new document is held for the
            // delegate too.
            policy.answer = { _ in .deny }
            let asked = policy.requests.count
            browser.load(url.appending(queryItems: [URLQueryItem(name: "early", value: "1")]))
            let heard = await waitUntil(timeout: .seconds(10)) {
                policy.requests.count > asked && policy.requests.last?.kind == .assertion
            }
            let early = (try? await browser.evaluateJavaScript("window.__early"))?.stringValue
            check("\(name): a document's first script reaches the delegate",
                  heard && early == "NotAllowedError", detail: "\(policy.requests.count - asked) asked, \(early ?? "nil")")
        } else {
            if let passkey = saved.first { try? await store.remove(passkey) }
            check("\(name): removing from the store", (try? await store.passkeys())?.isEmpty == true)
            policy.answer = { request in request.passkeys.isEmpty ? .deny : .signIn(with: request.passkeys[0]) }
            let removed = await PasskeyCall.run(browser, "signIn()")
            check("\(name): a removed passkey is no longer offered",
                  !removed.ok && policy.requests.last?.passkeys.isEmpty == true, detail: "\(removed)")
        }
    }

    /// A popup a page opens calls `navigator.credentials` from its first
    /// script. With `.disabled` and `.app`, CefKit's interception answers
    /// it, not Chromium's authenticator, which would wait at least ten
    /// seconds (the page asks for three) or show its dialog.
    private static func popupPasskeyChecks(url: URL) async {
        for mode in ["disabled", "app"] {
            let policy = PasskeyPolicy()
            var configuration = CefBrowser.Configuration()
            configuration.passkeys = mode == "disabled" ? .disabled : .app(CefInMemoryPasskeyStore())
            let opener = CefBrowser(url: url, configuration: configuration, delegate: policy)
            let window = CefBrowserWindow(browser: opener)
            var popups: [CefBrowserWindow] = []
            window.onPopup = { popup in
                popups.append(popup)
                popup.show()
            }
            window.show()
            let name = "passkeys (\(mode), popup)"
            defer {
                popups.forEach { $0.close() }
                window.close()
            }
            guard await waitUntil(timeout: .seconds(20), { opener.title == "passkeys" && !opener.isLoading }) else {
                check("\(name): opener loads", false, detail: opener.title)
                continue
            }
            let target = url.appending(queryItems: [URLQueryItem(name: "early", value: "1")])
            let start = ContinuousClock.now
            let opened = try? await opener.evaluateJavaScript(
                "window.open('\(target.absoluteString)', 'p', 'width=400,height=300') === null", userGesture: true)
            guard await waitUntil(timeout: .seconds(10), { popups.first?.browser.title == "passkeys" }),
                  let popup = popups.first?.browser
            else {
                check("\(name): the popup opens", false, detail: "\(popups.count) popups")
                continue
            }
            // The title can arrive before the first script has run.
            _ = await waitUntilAsync(timeout: .seconds(10)) {
                (try? await popup.evaluateJavaScript("window.__early !== undefined").boolValue) == true
            }
            let early = (try? await popup.evaluateJavaScript("window.__early"))?.stringValue
            let elapsed = ContinuousClock.now - start
            let answeredByCefKit = early == "NotAllowedError" && elapsed < .seconds(9)
            if mode == "disabled" {
                check("\(name): a first-script request is refused by CefKit",
                      answeredByCefKit && policy.requests.isEmpty,
                      detail: "\(early ?? "nil") after \(elapsed), \(policy.requests.count) asked")
            } else {
                check("\(name): a first-script request reaches the delegate",
                      answeredByCefKit && policy.requests.contains { $0.kind == .assertion },
                      detail: "\(early ?? "nil") after \(elapsed), \(policy.requests.count) asked")
            }
            check("\(name): the popup keeps its opener and features, not the page's handle",
                  popup.opener === opener && popup.popupFeatures?.size == CGSize(width: 400, height: 300)
                      && opened?.boolValue == true,
                  detail: "opener \(popup.opener === opener), \(String(describing: popup.popupFeatures)), null \(String(describing: opened))")
            popups.forEach { $0.close() }
            window.close()
            _ = await waitUntil { window.isClosed && popups.allSatisfy(\.isClosed) }
        }
    }

    private static func disabledPasskeyChecks(url: URL) async {
        let policy = PasskeyPolicy()
        var configuration = CefBrowser.Configuration()
        configuration.passkeys = .disabled
        let browser = CefBrowser(url: url, configuration: configuration, delegate: policy)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil(timeout: .seconds(20)) { browser.title == "passkeys" && !browser.isLoading }
        let start = ContinuousClock.now
        let result = await PasskeyCall.run(browser, "register()")
        check("passkeys (disabled): requests are refused without asking",
              !result.ok && result.error == "NotAllowedError" && policy.requests.isEmpty
                  && ContinuousClock.now - start < .seconds(5),
              detail: "\(result) after \(ContinuousClock.now - start), \(policy.requests.count) asked")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// A passkey decision is a tracked one: leaving the page or closing the
    /// browser ends it, and the default sheet goes with it.
    private static func passkeyDecisionCancellationChecks(url: URL) async {
        var configuration = CefBrowser.Configuration()
        configuration.passkeys = .app(CefInMemoryPasskeyStore())
        let delegate = StallingDelegate()
        let browser = CefBrowser(url: url, configuration: configuration, delegate: delegate)
        let view = hostWindowed(browser)
        defer { view.removeFromSuperview() }
        if await waitUntil(timeout: .seconds(20), { browser.title == "passkeys" && !browser.isLoading }) {
            browser.executeJavaScript("register()")
            let asked = await waitUntil(timeout: .seconds(5)) { delegate.started == 1 && browser.pendingDecisionCount == 1 }
            browser.load(URL(string: "selftest://app/second.html")!)
            let ended = await waitUntil(timeout: .seconds(10)) {
                delegate.cancelled == 1 && browser.pendingDecisionCount == 0 && browser.title == "second"
            }
            check("passkeys: leaving the page cancels a pending passkey decision", asked && ended,
                  detail: "asked \(asked), cancelled \(delegate.cancelled), pending \(browser.pendingDecisionCount), "
                      + "title \(browser.title)")
        } else {
            check("passkeys (cancellation): page loads", false, detail: browser.title)
        }
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }

        // The default delegate's sheet, for a click's sign-in with no
        // saved passkey, goes when the browser closes.
        let sheetBrowser = CefBrowser(url: url, configuration: configuration)
        view.browser = sheetBrowser
        guard await waitUntil(timeout: .seconds(20), { sheetBrowser.title == "passkeys" && !sheetBrowser.isLoading }) else {
            check("passkeys (sheet): page loads", false, detail: sheetBrowser.title)
            return
        }
        // Not awaited: the release's reply waits for the page, which stays
        // stopped before its call while the sheet is up.
        // A click sent before the page takes input is lost, so it is sent
        // again until the sheet shows.
        var shown = false
        for _ in 0 ..< 5 where !shown {
            Task {
                for type in ["mousePressed", "mouseReleased"] {
                    _ = try? await sheetBrowser.devTools.send("Input.dispatchMouseEvent", [
                        "type": .string(type), "x": 40, "y": 40, "button": "left", "clickCount": 1,
                    ])
                }
            }
            shown = await waitUntil(timeout: .seconds(3)) { window.attachedSheet != nil }
        }
        sheetBrowser.close(force: true)
        let gone = await waitUntil(timeout: .seconds(5)) {
            window.attachedSheet == nil && sheetBrowser.state == .closed && sheetBrowser.pendingDecisionCount == 0
        }
        check("passkeys: closing dismisses the default passkey sheet", shown && gone,
              detail: "shown \(shown), sheet \(String(describing: window.attachedSheet)), state \(sheetBrowser.state)")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// A store that cannot be read refuses the call before the delegate is
    /// asked; a save that fails after the page has its answer reaches the
    /// delegate with the passkey that was not saved.
    private static func passkeyStoreFailureChecks(url: URL) async {
        let store = UnreliablePasskeyStore()
        let policy = PasskeyPolicy()
        policy.answer = { request in request.passkeys.first.map { .signIn(with: $0) } ?? .createPasskey }
        var configuration = CefBrowser.Configuration()
        configuration.passkeys = .app(store)
        let browser = CefBrowser(url: url, configuration: configuration, delegate: policy)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        defer { window.close() }
        guard await waitUntil(timeout: .seconds(20), { browser.title == "passkeys" && !browser.isLoading }) else {
            check("passkeys (failing store): page loads", false, detail: browser.title)
            return
        }
        store.failsReads = true
        let unavailable = await PasskeyCall.run(browser, "register()")
        check("passkeys (failing store): an unavailable store refuses a registration unasked",
              !unavailable.ok && unavailable.error == "NotAllowedError" && policy.requests.isEmpty
                  && policy.storeFailures.map(\.operation) == [.checkAvailability],
              detail: "\(unavailable), \(policy.requests.count) asked, \(policy.storeFailures)")
        let unreadable = await PasskeyCall.run(browser, "signIn()")
        check("passkeys (failing store): an unreadable store refuses a sign-in unasked",
              !unreadable.ok && unreadable.error == "NotAllowedError" && policy.requests.isEmpty
                  && policy.storeFailures.last?.operation == .read,
              detail: "\(unreadable), \(policy.storeFailures)")

        store.failsReads = false
        store.failsSaves = true
        let created = await PasskeyCall.run(browser, "register()")
        _ = await waitUntil(timeout: .seconds(3)) { policy.storeFailures.last?.operation == .save }
        let failure = policy.storeFailures.last
        check("passkeys (failing store): a failed save reaches the delegate with the passkey",
              created.ok && failure?.operation == .save && failure?.passkey?.id.base64URLString == created.id,
              detail: "\(created), \(String(describing: failure))")
    }

    /// The Passkeys button in Chrome's autofill settings opens a tab of
    /// Chromium's own; it must reach `onOpenBrowser`, not a window.
    private static func passkeySettingsChecks() async {
        var opened: [URL] = []
        CefRuntime.shared.onOpenBrowser = { opened.append($0.url); return .close }
        defer { CefRuntime.shared.onOpenBrowser = nil }
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
        // Windows already on screen, such as one still closing from an
        // earlier check, are not Chromium's new one.
        let present = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        var sawWindow: String?
        let arrived = await waitUntil {
            let ours = Set(CefBrowserWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
            if sawWindow == nil, let shown = NSApp.windows.first(where: {
                $0.isVisible && $0.alphaValue > 0.05 && $0.styleMask.contains(.titled) && $0.parent == nil
                    && $0 !== SelfTest.window && !ours.contains(ObjectIdentifier($0)) && !present.contains(ObjectIdentifier($0))
            }) {
                sawWindow = "\(type(of: shown)) “\(shown.title)”"
            }
            return !opened.isEmpty
        }
        check("passkeys: the settings Passkeys button hands its tab over",
              clicked && arrived && opened.first?.host() == "password-manager" && sawWindow == nil,
              detail: "clicked: \(clicked), \(opened), window: \(sawWindow ?? "none")")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    private static func server(_ url: URL) -> Int { url.port ?? 0 }
}

enum PasskeyChecks {
    /// The test page. Each call reports its outcome instead of throwing.
    static let page = """
        <!doctype html><title>passkeys</title>
        <script>
          // The document's first script: it calls before anything else runs.
          if (location.search.includes('early')) {
            window.__early = navigator.credentials.get({ publicKey: {
              challenge: new Uint8Array(16), rpId: 'localhost', timeout: 3000 } }).then(() => 'ok', e => e.name);
          }
        </script>
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
    private(set) var storeFailures: [CefPasskeyStoreError] = []

    func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
        requests.append(request)
        return answer(request)
    }

    func browser(_ browser: CefBrowser, passkeyStoreDidFail error: CefPasskeyStoreError) {
        storeFailures.append(error)
    }
}

/// An in-memory store whose reads or saves fail on request, as a keychain
/// without its entitlement, or a locked one, does.
@MainActor
final class UnreliablePasskeyStore: CefPasskeyStore {
    var failsReads = false
    var failsSaves = false
    private let stored = CefInMemoryPasskeyStore()

    func passkeys() async throws -> [CefPasskey] {
        if failsReads { throw CefError.operationFailed("the store is unavailable") }
        return try await stored.passkeys()
    }

    func save(_ passkey: CefPasskey) async throws {
        if failsSaves { throw CefError.operationFailed("the store is read-only") }
        try await stored.save(passkey)
    }

    func remove(_ passkey: CefPasskey) async throws { try await stored.remove(passkey) }
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
