import AppKit
import CefSwiftUI

/// Browsers Chromium opens in tabbed windows of its own, through
/// `CefRuntime.onChromeTab`.
extension SelfTest {
    static func chromiumTabChecks() async {
        var requests: [CefChromeTabRequest] = []
        var decision = CefChromeTabDecision.close
        var announced: [CefBrowser] = []
        var wasLive: [Bool] = []
        CefRuntime.shared.onChromeTab = { request in
            wasLive.append(request.browser.state == .live && CefRuntime.shared.browsers.contains { $0 === request.browser })
            requests.append(request)
            return decision
        }
        CefRuntime.shared.onBrowserCreated = { announced.append($0) }
        defer {
            CefRuntime.shared.onChromeTab = nil
            CefRuntime.shared.onBrowserCreated = nil
        }
        var configuration = CefBrowser.Configuration()
        configuration.profile = .persistent(id: "selftest-tabs", displayName: "SelfTest Tabs")
        let page = "data:text/html,<title>links</title><a href='selftest://app/second.html' "
            + "style='display:block;width:300px;height:100px'>second</a>"
        let browser = CefBrowser(url: URL(string: page)!, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        defer { window.close() }
        guard await loaded(browser, title: "links", timeout: .seconds(20)) else {
            check("Chromium's tabs: page loads", false, detail: browser.title)
            return
        }

        // ⌘-click: the delegate leaves the link to Chromium, which opens it
        // in a background tab of a window of its own.
        let present = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": .string(type), "x": 40, "y": 40, "button": "left", "clickCount": 1, "modifiers": 4,
            ])
        }
        // A window of the app's own that appears meanwhile is not Chromium's.
        let unrelated = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.title = "Unrelated"
        unrelated.isReleasedWhenClosed = false
        unrelated.orderFront(nil)
        var sawChromiumWindow: String?
        let arrived = await waitUntil {
            let ours = Set(CefWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
            if sawChromiumWindow == nil, let shown = NSApp.windows.first(where: {
                $0.isVisible && $0.alphaValue > 0.05 && $0.styleMask.contains(.titled) && $0.parent == nil
                    && $0 !== SelfTest.window && $0 !== unrelated && !ours.contains(ObjectIdentifier($0))
                    && !present.contains(ObjectIdentifier($0))
            }) {
                sawChromiumWindow = "\(type(of: shown)) “\(shown.title)”"
            }
            return !requests.isEmpty
        }
        let request = requests.first
        check("Chromium's tabs: a ⌘-clicked link's tab arrives with its opener, disposition and profile",
              arrived && request?.url.absoluteString == "selftest://app/second.html" && request?.opener === browser
                  && request?.disposition == .newBackgroundTab && request?.profile === configuration.profile,
              detail: "\(String(describing: request.map { ($0.url, $0.opener?.identifier, $0.disposition, $0.profile === configuration.profile) }))")
        check("Chromium's tabs: the request carries Chromium's live browser",
              request?.browser.opener == nil && wasLive.first == true)
        let closed = await waitUntil { request?.browser.state == .closed }
        check("Chromium's tabs: answering close closes Chromium's browser, whose window is never seen",
              closed && sawChromiumWindow == nil, detail: "window: \(sawChromiumWindow ?? "none")")
        check("Chromium's tabs: the app's own windows stay on screen", unrelated.isVisible && unrelated.alphaValue == 1)
        unrelated.close()
        check("Chromium's tabs: a browser handed over is not announced as created", announced.isEmpty,
              detail: "\(announced.map(\.identifier))")

        // A Chrome command opens a tab with no page asking for it; this one
        // stays in Chromium's window.
        decision = .showInChromeWindow
        requests = []
        browser.execute(.newTab)
        _ = await waitUntil { !requests.isEmpty }
        let shown = requests.first
        let visible = await waitUntil {
            guard let window = shown?.browser.nativeView?.window else { return false }
            return window.isVisible && window.alphaValue == 1
        }
        check("Chromium's tabs: a new-tab command's tab has no opener",
              shown?.opener == nil && shown?.disposition == .unknown && shown?.url.scheme == "chrome"
                  && shown?.profile === configuration.profile,
              detail: "\(String(describing: shown.map { ($0.url, $0.opener?.identifier, $0.disposition) }))")
        check("Chromium's tabs: answering showInChromeWindow shows Chromium's window and announces the browser",
              visible && announced.contains { $0 === shown?.browser })
        shown?.browser.close(force: true)
        _ = await waitUntil { shown?.browser.state == .closed }
    }
}
