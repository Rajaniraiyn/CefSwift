import AppKit
@_spi(Testing) import CefKit

/// What a profile decides for every page in it — its request filter,
/// scheme handlers, user scripts, bridges, attachments, delegate and
/// configuration — reaching pages the app creates and those Chromium
/// creates itself, and the order in which a page, its profile and the
/// runtime win.
extension SelfTest {
    static func profilePolicyChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("profile policy", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/policy"
        let profile = CefProfile.incognito()
        let policy = ProfilePolicyRecorder()
        profile.delegate = policy
        profile.userScripts = [CefUserScript(source: "window.__order = (window.__order || '') + 'P';")]
        let bridge = CefBridge(name: "profileBridge")
        bridge.handle("ping") { (_: CefJSON) in "pong" }
        profile.bridges = [bridge]
        let attachment = CountingAttachment()
        profile.attachments = [attachment]
        await PolicyFilterLog.reset()
        profile.requestFilter = CefRequestFilter(urlPatterns: ["*/policy/*"]) { request in
            PolicyFilterLog.entries.append(request)
            switch request.url?.lastPathComponent {
            case "blocked": return .block
            case "set-cookie": return .restrictCookies(to: [])
            default: return .allow
            }
        }

        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        configuration.userScripts = [CefUserScript(source: "window.__order = (window.__order || '') + 'G';")]
        let browser = CefBrowser(url: URL(string: "\(base)/page")!, configuration: configuration)
        let view = hostWindowed(browser)
        guard await loaded(browser, title: "policy") else {
            check("profile policy: page loads", false, detail: browser.title)
            await closeHosted(browser, view)
            return
        }

        // Scripts and bridges: the profile's first, then the page's.
        await expect("profile policy: profile scripts run before the page's own") {
            let order = try await browser.evaluateJavaScript("window.__order").stringValue
            return (order == "PG", order ?? "nil")
        }
        await expect("profile policy: a profile bridge reaches the page") {
            try await browser.evaluateJavaScript("profileBridge.ping()").stringValue == "pong"
        }
        check("profile policy: profile attachments set the page up",
              await waitUntil { attachment.created.contains(ObjectIdentifier(browser)) })

        // The request filter: the profile's applies to a page without one.
        func fetch(_ path: String, in page: CefBrowser) async -> String {
            (try? await page.evaluateJavaScript(
                "fetch('\(path)').then(r => r.status + '', e => 'blocked')").stringValue) ?? "no answer"
        }
        let blocked = await fetch("/policy/blocked", in: browser)
        let allowed = await fetch("/policy/allowed", in: browser)
        let other = await fetch("/other", in: browser)
        let seen = await PolicyFilterLog.snapshot()
        check("profile policy: the profile's filter blocks and allows a page's requests",
              blocked == "blocked" && allowed == "200", detail: "\(blocked) \(allowed)")
        check("profile policy: requests outside the filter's patterns never reach it",
              other == "404" && !seen.contains { $0.url?.path == "/other" }, detail: "\(seen.compactMap(\.url?.path))")
        let fetched = seen.first { $0.url?.path == "/policy/allowed" }
        check("profile policy: a request carries its type, frame, page, initiator and first party",
              fetched?.resourceType == .fetch && fetched?.frame?.isMain == true
                  && fetched?.pageIdentifier == browser.identifier
                  && fetched?.initiator?.absoluteString == "http://127.0.0.1:\(server.port)"
                  && fetched?.firstPartyURL?.host() == "127.0.0.1" && fetched?.isThirdParty == false
                  && seen.first { $0.url?.path == "/policy/page" }?.resourceType == .mainFrame,
              detail: "\(String(describing: fetched))")

        // Cookies the filter keeps out are neither sent nor saved.
        _ = await fetch("/policy/set-cookie", in: browser)
        let cookies = (try? await profile.cookies(for: URL(string: base)!)) ?? []
        check("profile policy: restrictCookies keeps a response's cookies out",
              !cookies.contains { $0.name == "policyCookie" }, detail: "\(cookies.map(\.name))")

        // The app's own requests are the app's: CEF does not hand them to
        // the profile's filter.
        await PolicyFilterLog.reset()
        let appRequest = try? await profile.data(from: URL(string: "\(base)/blocked")!)
        let appSeen = await PolicyFilterLog.snapshot()
        check("profile policy: the app's own requests are not filtered",
              appRequest?.1.statusCode == 200 && appSeen.isEmpty,
              detail: "\(appSeen.map { ($0.url?.path ?? "", $0.resourceType) })")

        // A service worker's requests have no page: only the profile's
        // request context handler sees them.
        await PolicyFilterLog.reset()
        let worker = CefBrowser(url: URL(string: "\(base)/sw-page")!, configuration: configuration)
        let workerView = hostWindowed(worker)
        let registered = await waitUntilAsync(timeout: .seconds(15)) {
            (try? await worker.evaluateJavaScript("window.__worker || ''").stringValue) == "blocked"
        }
        let workerSeen = await PolicyFilterLog.snapshot()
        let fromWorker = workerSeen.first { $0.url?.path == "/policy/blocked" && $0.frame == nil }
        check("profile policy: a service worker's request is filtered",
              registered && fromWorker != nil,
              detail: "\((try? await worker.evaluateJavaScript("window.__worker || ''").stringValue) ?? "") "
                  + "\(workerSeen.map { ($0.url?.path ?? "", $0.resourceType, $0.frame?.isMain as Any) })")
        await closeHosted(worker, workerView)

        // A page's own filter takes the profile's place for its requests.
        var own = configuration
        own.requestFilter = CefRequestFilter { _ in .allow }
        let overriding = CefBrowser(url: URL(string: "\(base)/page")!, configuration: own)
        let overridingView = hostWindowed(overriding)
        _ = await loaded(overriding, title: "policy")
        await PolicyFilterLog.reset()
        let unblocked = await fetch("/policy/blocked", in: overriding)
        let profileSawIt = !(await PolicyFilterLog.snapshot()).isEmpty
        check("profile policy: a page's own filter replaces the profile's",
              unblocked == "200" && !profileSawIt, detail: unblocked)
        await closeHosted(overriding, overridingView)

        await permissionPrecedenceChecks(profile: profile, policy: policy)
        await chromiumCreatedPageChecks(profile: profile, policy: policy, base: base, attachment: attachment)
        await closeHosted(browser, view)
        await schemeHandlerPrecedenceChecks()
        profileFactChecks(profile: profile)
    }

    /// Page delegate, then profile delegate, then the default (deny); and
    /// remembered answers land in the profile's site settings.
    private static func permissionPrecedenceChecks(profile: CefProfile, policy: ProfilePolicyRecorder) async {
        let origin = capabilityOrigin
        let settings = profile.siteSettings
        settings.reset(origin: origin)
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        let browser = CefBrowser(url: origin.appending(path: "permissions.html"), configuration: configuration)
        let view = hostWindowed(browser)
        defer { settings.reset(origin: origin) }
        guard await loaded(browser, title: "permissions") else {
            check("profile permissions: page loads", false, detail: browser.title)
            await closeHosted(browser, view)
            return
        }
        func request() async -> String {
            (try? await browser.evaluateJavaScript(
                "navigator.requestMIDIAccess({sysex: true}).then(() => 'granted', e => e.name)").stringValue) ?? "no answer"
        }
        policy.permissionRequests = []
        policy.answer = .deny
        let denied = await request()
        let asked = policy.permissionRequests.first
        check("profile permissions: a page without a delegate leaves the request to its profile",
              denied != "granted" && asked?.request.kinds == .midi && asked?.page === browser
                  && asked?.request.origin.absoluteString == "https://cefswift.test"
                  && asked?.request.topLevelOrigin?.absoluteString == "https://cefswift.test"
                  && asked?.request.isMainFrame == true,
              detail: "\(denied) \(String(describing: asked?.request))")

        let page = PermissionRecorder()
        page.answer = .allow
        browser.delegate = page
        policy.permissionRequests = []
        // Chromium keeps a prompt's deny for the site.
        settings.reset(origin: origin)
        let granted = await request()
        check("profile permissions: the page's delegate wins over the profile's",
              granted == "granted" && page.requests.count == 1 && policy.permissionRequests.isEmpty,
              detail: "\(granted), page \(page.requests.count), profile \(policy.permissionRequests.count)")

        browser.delegate = nil
        settings.reset(origin: origin)
        policy.answer = .alwaysAllow
        _ = await request()
        check("profile permissions: alwaysAllow from the profile is stored in its site settings",
              settings.setting(for: .midiSystemExclusive, origin: origin) == .allow)
        await closeHosted(browser, view)
    }

    /// A native popup and a tab Chromium opens in a window of its own get
    /// the profile's scripts, filter, attachments and permission answers.
    private static func chromiumCreatedPageChecks(
        profile: CefProfile, policy: ProfilePolicyRecorder, base: String, attachment: CountingAttachment
    ) async {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        let opener = PopupAllower()
        let page = "<title>links</title><a href='\(base)/page' style='display:block;width:300px;height:100px'>page</a>"
        let browser = CefBrowser(
            url: URL(string: "data:text/html," + page.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!,
            configuration: configuration, delegate: opener)
        let window = CefWindow(browser: browser)
        window.show()
        defer { window.close() }
        guard await loaded(browser, title: "links", timeout: .seconds(20)) else {
            check("Chromium-created pages: opener loads", false, detail: browser.title)
            return
        }

        // A native popup, which Chromium creates and loads at once.
        _ = try? await browser.evaluateJavaScript("window.open('\(base)/page', 'popup', 'width=400,height=300'); 0",
                                                  userGesture: true)
        _ = await waitUntil { opener.popups.first?.title == "policy" }
        if let popup = opener.popups.first {
            await expect("Chromium-created pages: a native popup runs the profile's scripts") {
                let order = try await popup.evaluateJavaScript("window.__order").stringValue
                return (order == "P", order ?? "nil")
            }
            await PolicyFilterLog.reset()
            let blocked = (try? await popup.evaluateJavaScript(
                "fetch('/policy/blocked').then(r => r.status + '', e => 'blocked')").stringValue) ?? "no answer"
            let popupSeen = await PolicyFilterLog.snapshot()
            check("Chromium-created pages: a native popup's requests go through the profile's filter",
                  blocked == "blocked" && popupSeen.contains { $0.pageIdentifier == popup.identifier },
                  detail: blocked)
            check("Chromium-created pages: a native popup gets the profile's attachments",
                  await waitUntil { attachment.created.contains(ObjectIdentifier(popup)) })
            popup.close(force: true)
            _ = await waitUntil { popup.state == .closed }
        } else {
            check("Chromium-created pages: a native popup opens", false)
        }

        // ⌘-click: Chromium opens the link in a tab of a window of its own,
        // with its default client and no `extra_info`.
        var tabs: [CefChromeTabRequest] = []
        CefRuntime.shared.onChromeTab = { request in
            tabs.append(request)
            return .showInChromeWindow
        }
        defer { CefRuntime.shared.onChromeTab = nil }
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": .string(type), "x": 40, "y": 40, "button": "left", "clickCount": 1, "modifiers": 4,
            ])
        }
        _ = await waitUntil { tabs.first?.browser.title == "policy" }
        guard let tab = tabs.first?.browser else {
            check("Chromium-created pages: a ⌘-clicked link opens a Chromium tab", false)
            return
        }
        // A window Chromium opens itself gives its tab no `extra_info`, and
        // CEF connects a frame to the browser process only once its first
        // document has committed: the profile's scripts and bridges arrive
        // for the next document.
        let firstOrder = try? await tab.evaluateJavaScript("window.__order").stringValue
        if firstOrder == "P" {
            check("Chromium-created pages: a tab in Chromium's own window runs the profile's scripts from its first document", true)
        } else {
            skip("Chromium-created pages: a tab in Chromium's own window runs the profile's scripts from its first document",
                 because: "CEF gives such a tab no extra_info and connects its frame only after the first document commits",
                 .limitation)
        }
        tab.reload()
        _ = try? await tab.waitUntilLoaded(timeout: .seconds(10))
        await expect("Chromium-created pages: a tab in Chromium's own window runs the profile's scripts from its next document") {
            let order = try await tab.evaluateJavaScript("window.__order").stringValue
            return (order == "P", order ?? "nil")
        }
        await expect("Chromium-created pages: a profile bridge reaches a tab in Chromium's own window") {
            try await tab.evaluateJavaScript("profileBridge.ping()").stringValue == "pong"
        }
        await PolicyFilterLog.reset()
        let blocked = (try? await tab.evaluateJavaScript(
            "fetch('/policy/blocked').then(r => r.status + '', e => 'blocked')").stringValue) ?? "no answer"
        let tabSeen = await PolicyFilterLog.snapshot()
        check("Chromium-created pages: a Chromium tab's requests go through the profile's filter",
              blocked == "blocked" && tabSeen.contains { $0.pageIdentifier == tab.identifier },
              detail: blocked)
        check("Chromium-created pages: a Chromium tab gets the profile's attachments",
              await waitUntil { attachment.created.contains(ObjectIdentifier(tab)) })
        policy.permissionRequests = []
        policy.answer = .deny
        _ = try? await tab.evaluateJavaScript("fetch('/policy/blocked').catch(() => 0); 0")
        if (try? await tab.load(capabilityOrigin.appending(path: "permissions.html")).waitUntilLoaded(timeout: .seconds(15))) != nil {
            _ = try? await tab.evaluateJavaScript(
                "navigator.requestMIDIAccess({sysex: true}).then(() => 'granted', e => e.name)")
            check("Chromium-created pages: a Chromium tab's permission requests go to the profile",
                  policy.permissionRequests.contains { $0.page === tab }, detail: "\(policy.permissionRequests.count)")
        }
        tab.close(force: true)
        _ = await waitUntil { tab.state == .closed }
    }

    /// A profile's scheme handler takes the runtime's place in that
    /// profile, and the runtime's comes back when it is removed.
    private static func schemeHandlerPrecedenceChecks() async {
        CefRuntime.shared.registerSchemeHandler(
            scheme: "selftest", domain: "precedence", handler: TitledPage(title: "runtime"))
        let own = CefProfile.incognito()
        own.registerSchemeHandler(scheme: "selftest", domain: "precedence", handler: TitledPage(title: "profile"))
        let url = URL(string: "selftest://precedence/")!
        func title(in profile: CefProfile) async -> String {
            var configuration = CefBrowser.Configuration()
            configuration.profile = profile
            let browser = CefBrowser(url: url, configuration: configuration)
            let view = hostWindowed(browser)
            _ = await loaded(browser)
            let title = browser.title
            await closeHosted(browser, view)
            return title
        }
        let inOwn = await title(in: own)
        let inOther = await title(in: .incognito())
        let inDefault = await title(in: .default)
        check("scheme handlers: a profile's own handler wins in that profile only",
              inOwn == "profile" && inOther == "runtime" && inDefault == "runtime",
              detail: "\(inOwn) \(inOther) \(inDefault)")
        CefProfile.default.registerSchemeHandler(scheme: "selftest", domain: "precedence", handler: TitledPage(title: "default"))
        let ownDefault = await title(in: .default)
        own.removeSchemeHandler(scheme: "selftest", domain: "precedence")
        CefProfile.default.removeSchemeHandler(scheme: "selftest", domain: "precedence")
        let restored = await title(in: own)
        let restoredDefault = await title(in: .default)
        check("scheme handlers: removing a profile's handler brings the runtime's back",
              ownDefault == "default" && restored == "runtime" && restoredDefault == "runtime",
              detail: "\(ownDefault) \(restored) \(restoredDefault)")
        CefRuntime.shared.removeSchemeHandler(scheme: "selftest", domain: "precedence")
        let removed = await title(in: .incognito())
        check("scheme handlers: removing the runtime's handler leaves the scheme's other handler",
              removed != "runtime", detail: removed)
    }

    /// Storage facts and the profile's own configuration.
    private static func profileFactChecks(profile: CefProfile) {
        let persistent = CefProfile.persistent(id: "selftest-tabs")
        check("profile facts: storage directories",
              CefProfile.default.storageDirectory?.lastPathComponent == "Default" && profile.storageDirectory == nil
                  && persistent.storageDirectory?.lastPathComponent == "Profile-selftest-tabs",
              detail: "\(CefProfile.default.storageDirectory?.path ?? "nil") \(persistent.storageDirectory?.path ?? "nil")")

        let other = CefProfile.incognito()
        profile.configuration.privacy.thirdPartyCookies = .block
        profile.configuration.network.proxy = .direct
        let mode = profile.preferences.value(named: "profile.cookie_controls_mode")
        let proxy = profile.preferences.value(named: "proxy")
        check("profile configuration: a profile's own settings apply to it at once",
              mode?.intValue == 1 && proxy?["mode"].stringValue == "direct",
              detail: "\(String(describing: mode)) \(String(describing: proxy))")
        _ = other.preferences.value(named: "proxy")
        check("profile configuration: another profile keeps the runtime's",
              other.configuration.network.proxy == .automatic && other.preferences.value(named: "proxy")?["mode"].stringValue != "direct")
        profile.configuration.privacy.thirdPartyCookies = .automatic
        check("profile configuration: going back to automatic resets the preference",
              profile.preferences.isDefault(named: "profile.cookie_controls_mode"))
    }
}

/// What the profile filter saw, on the IO thread it runs on.
enum PolicyFilterLog {
    @CefIOActor static var entries: [CefResourceRequest] = []

    static func reset() async { await Task { @CefIOActor in entries = [] }.value }
    static func snapshot() async -> [CefResourceRequest] { await Task { @CefIOActor in entries }.value }
}

/// A profile delegate that records the permission requests it answers.
@MainActor
final class ProfilePolicyRecorder: CefProfileDelegate {
    var answer = CefPermissionDecision.deny
    var permissionRequests: [(request: CefPermissionRequest, page: CefBrowser)] = []

    func profile(_ profile: CefProfile, decidePermissionFor request: CefPermissionRequest, in page: CefBrowser) async
        -> CefPermissionDecision
    {
        permissionRequests.append((request, page))
        return answer
    }
}

/// Lets every popup open natively and keeps the popups.
@MainActor
final class PopupAllower: CefBrowserDelegate {
    var popups: [CefBrowser] = []

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
        .allowNativePopup
    }

    func browser(_ browser: CefBrowser, didOpen popup: CefBrowser) {
        popups.append(popup)
    }
}

/// Counts the browsers it sets up.
@MainActor
final class CountingAttachment: CefBrowserAttachment {
    var created: Set<ObjectIdentifier> = []

    func browserDidCreate(_ browser: CefBrowser) async { created.insert(ObjectIdentifier(browser)) }
    func browserDidClose(_ browser: CefBrowser) {}
}

/// A page titled `title`.
struct TitledPage: CefSchemeHandler {
    let title: String

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data("<title>\(title)</title>\(title)".utf8))
    }
}

/// The pages of the profile policy checks, at `/policy/…` on the local server.
enum ProfilePolicyPages {
    static func content(for name: String) -> (String, Data, [(String, String)])? {
        switch name {
        case "page", "popup":
            return ("text/html", Data("<title>policy</title><p>policy</p>".utf8), [])
        case "allowed", "blocked":
            return ("text/plain", Data("ok".utf8), [])
        case "image.png":
            // One opaque pixel.
            let png = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
            return ("image/png", png ?? Data(), [])
        case "set-cookie":
            return ("text/plain", Data("set".utf8), [("Set-Cookie", "policyCookie=yes; Path=/")])
        case "sw-page":
            // The worker fetches a blocked address and reports how it went.
            return ("text/html", Data("""
                <title>sw</title>
                <script>
                navigator.serviceWorker.addEventListener('message', e => { window.__worker = e.data; });
                navigator.serviceWorker.register('/policy/sw.js').then(() => navigator.serviceWorker.ready)
                  .then(r => r.active.postMessage('go'), e => { window.__worker = 'register failed: ' + e; });
                </script>
                """.utf8), [])
        case "sw.js":
            return ("text/javascript", Data("""
                self.addEventListener('install', () => self.skipWaiting());
                self.addEventListener('activate', e => e.waitUntil(clients.claim()));
                self.addEventListener('message', e => {
                  fetch('/policy/blocked').then(r => 'status ' + r.status, () => 'blocked')
                    .then(result => e.source.postMessage(result));
                });
                """.utf8), [])
        default:
            return nil
        }
    }
}
