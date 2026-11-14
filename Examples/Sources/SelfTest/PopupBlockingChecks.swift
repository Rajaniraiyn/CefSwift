import AppKit
import CefKit

// What happens to a script's `window.open` without a user gesture, per
// runtime style: Chromium's popup blocker stops it before the delegate in
// both (measured with CEF 156), unless the popups site setting allows it;
// then the default window-open decision denies it in Alloy style.
extension SelfTest {
    @MainActor
    private final class WindowOpenRecorder: CefBrowserDelegate {
        var requests: [CefWindowOpenRequest] = []

        func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
            requests.append(request)
            return .default(for: request)
        }
    }

    static func popupBlockingChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("popups: gesture-less window.open", because: "the local server could not start", .environment)
            return
        }
        let page = URL(string: "http://127.0.0.1:\(server.port)/page")!
        let target = "http://127.0.0.1:\(server.port)/status"
        let script = "window.open('\(target)'); 0"

        // Both runtime styles run Chromium's popup blocker before the
        // delegate is asked; with the popups site setting allowed, the
        // delegate sees the request, without a gesture.
        let settings = CefProfile.default.siteSettings
        let origin = URL(string: "http://127.0.0.1:\(server.port)")!
        settings.reset(origin: origin)
        defer { settings.reset(origin: origin) }

        // Alloy style: and the default denies it, so the page stays.
        let alloy = CefBrowser(url: page)
        let alloyRecorder = WindowOpenRecorder()
        alloy.delegate = alloyRecorder
        let view = hostWindowed(alloy)
        if await loaded(alloy, title: "page") {
            _ = try? await alloy.evaluateJavaScript(script)
            try? await Task.sleep(for: .milliseconds(1500))
            check("popups: Alloy — Chromium's popup blocker stops a gesture-less window.open before the delegate",
                  alloyRecorder.requests.isEmpty && alloy.url?.path == "/page",
                  detail: "\(alloyRecorder.requests.count) requests")
            settings.set(.allow, for: .popups, origin: origin)
            _ = try? await alloy.evaluateJavaScript(script)
            _ = await waitUntil(timeout: .seconds(3)) { !alloyRecorder.requests.isEmpty }
            try? await Task.sleep(for: .milliseconds(500))
            check("popups: Alloy — with the popups setting allowed, the delegate sees it, and the default keeps the page",
                  alloyRecorder.requests.first?.hasUserGesture == false && alloy.url?.path == "/page"
                      && alloy.title == "page",
                  detail: "\(alloyRecorder.requests.count) requests, at \(alloy.url?.absoluteString ?? "-")")
            settings.reset(origin: origin)
        } else {
            check("popups: Alloy page loads", false, detail: alloy.title)
        }
        await closeHosted(alloy, view)

        // Chrome style: Chromium's popup blocker stops it before the
        // delegate unless the popups site setting allows it.
        let chrome = CefBrowser(url: page)
        let chromeRecorder = WindowOpenRecorder()
        chrome.delegate = chromeRecorder
        let window = CefWindow(browser: chrome)
        var popups: [CefWindow] = []
        window.onPopup = { popup in popups.append(popup) }
        window.show()
        defer { for popup in popups { popup.close() } }
        if await loaded(chrome, title: "page") {
            _ = try? await chrome.evaluateJavaScript(script)
            try? await Task.sleep(for: .milliseconds(1500))
            check("popups: Chrome style — Chromium's popup blocker stops a gesture-less window.open before the delegate",
                  chromeRecorder.requests.isEmpty && popups.isEmpty && chrome.url?.path == "/page",
                  detail: "\(chromeRecorder.requests.count) requests, \(popups.count) popups")

            // The recipe for an app that wants to see such popups: allow
            // the site setting, then decide in decideWindowOpenFor.
            settings.set(.allow, for: .popups, origin: origin)
            _ = try? await chrome.evaluateJavaScript(script)
            _ = await waitUntil(timeout: .seconds(3)) { !chromeRecorder.requests.isEmpty }
            check("popups: Chrome style — with the popups setting allowed, the delegate sees it, without a gesture",
                  chromeRecorder.requests.first?.hasUserGesture == false,
                  detail: "\(chromeRecorder.requests.count) requests")
        } else {
            check("popups: Chrome-style page loads", false, detail: chrome.title)
        }
        window.close()
        _ = await waitUntil { window.isClosed }
        for popup in popups { popup.close() }
        _ = await waitUntil { popups.allSatisfy(\.isClosed) }
    }
}
