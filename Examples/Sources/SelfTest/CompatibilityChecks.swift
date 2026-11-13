import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// What a page can observe about a CefSwift browser: nothing of the
/// DevTools protocol unless a feature that needs it is used, no automation
/// flag, no globals other than a bridge's own, and an offscreen browser
/// that reports the window it is shown in. The same readings as
/// `Scripts/compat/probe.html`, on a local page.
extension SelfTest {
    static func compatibilityChecks() async {
        await plainBrowserChecks()
        await bridgeAndScriptChecks()
        await offscreenGeometryChecks()
    }

    private static func plainBrowserChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/compat.html")!)
        let view = hostWindowed(browser)
        _ = await waitUntil { browser.title == "compat" && !browser.isLoading }

        await expect("compatibility: navigator.webdriver is false") {
            try await browser.evaluateJavaScript("[navigator.webdriver, window.__webdriver]") == [false, false]
        }
        await expect("compatibility: a debugger statement does not stop the page") {
            try await browser.evaluateJavaScript("window.__debuggerMs").doubleValue.map { $0 < 50 } == true
        }
        await expect("compatibility: no automation globals") {
            try await browser.evaluateJavaScript("window.__globals") == []
        }
        check("compatibility: a plain browser has no DevTools session",
              browser.devTools.sentMessageCount == 0 && !browser.devTools.isAttached,
              detail: "\(browser.devTools.sentMessageCount) messages")
        await closeHosted(browser, view)
    }

    private static func bridgeAndScriptChecks() async {
        let bridge = CefBridge(name: "app")  // The name frame.html calls.
        bridge.access = .anyFrame
        bridge.handle("greet") { (person: [String: String], call: CefBridgeCall) in
            "Hello, \(person["name"] ?? "") from \(call.isMainFrame ? "main" : "sub")!"
        }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [bridge]
        configuration.userScripts = [
            CefUserScript(source: "window.__start = document.readyState;"),
            CefUserScript(
                source: "document.body.dataset.end = document.readyState;",
                injectionTime: .documentEnd, frames: .mainFrame),
        ]
        let browser = CefBrowser(url: URL(string: "selftest://app/compat.html")!, configuration: configuration)
        let view = hostWindowed(browser)
        _ = await waitUntil { browser.title == "compat" && !browser.isLoading }

        await expect("compatibility: user scripts run at document start and end") {
            try await browser.evaluateJavaScript("[window.__start, document.body.dataset.end]") == ["loading", "interactive"]
        }
        await expect("compatibility: the bridge is the only global it adds, and is native") {
            try await browser.evaluateJavaScript("""
                [window.__globals.length, typeof app, /\\[native code\\]/.test(String(app.greet))]
                """) == [0, "object", true]
        }
        await expect("compatibility: the bridge answers") {
            try await browser.evaluateJavaScript("app.greet({ name: 'Ann' })") == "Hello, Ann from main!"
        }
        await expect("compatibility: a cross-site frame gets the bridge its access allows") {
            let outcome = try await browser.evaluateJavaScript("""
                new Promise(resolve => {
                  addEventListener('message', e => resolve(e.data), { once: true });
                  const frame = document.createElement('iframe');
                  frame.src = 'selftest://other/frame.html';
                  document.body.appendChild(frame);
                })
                """)
            if outcome != "allowed" { print("NOTE cross-site frame: \(outcome.text)") }
            return outcome == "allowed"
        }
        check("compatibility: bridges, user scripts and evaluation use no DevTools session",
              browser.devTools.sentMessageCount == 0 && !browser.devTools.isAttached,
              detail: "\(browser.devTools.sentMessageCount) messages")
        await closeHosted(browser, view)
    }

    private static func offscreenGeometryChecks() async {
        // A window draws at the display's rate whatever the energy saver
        // does; compare at full rate, as on a Mac on power.
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = .automatic }
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "selftest://app/compat.html")!, configuration: configuration)
        let view = hostOffscreen(browser)
        _ = await waitUntil { browser.title == "compat" && !browser.isLoading }

        guard let screen = window.screen else {
            skip("compatibility: offscreen geometry", because: "the test window has no screen", .environment)
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let frame = window.frame, visible = screen.visibleFrame
        let expected: CefJSON = [
            .number(frame.minX.rounded()), .number((primaryHeight - frame.maxY).rounded()),
            .number(frame.width.rounded()), .number(frame.height.rounded()),
            .number(visible.width.rounded()), .number(visible.height.rounded()),
            .number(window.backingScaleFactor),
        ]
        await expect("compatibility: an offscreen page reports its window and screen") {
            let reported = try await browser.evaluateJavaScript(
                "[screenX, screenY, outerWidth, outerHeight, screen.availWidth, screen.availHeight, devicePixelRatio]")
            if reported != expected { print("NOTE offscreen geometry \(reported.text), window \(expected.text)") }
            return reported == expected
        }
        if window.occlusionState.contains(.visible) {
            await expect("compatibility: an offscreen page gets animation frames as a window does") {
                let rate = try await browser.evaluateJavaScript("""
                    new Promise(resolve => {
                      let frames = 0; const start = performance.now();
                      const tick = () => { frames++; performance.now() - start < 1000 ? requestAnimationFrame(tick) : resolve(frames); };
                      requestAnimationFrame(tick);
                    })
                    """).intValue ?? 0
                if rate < 50 { print("NOTE offscreen animation frames: \(rate) per second") }
                return rate >= 50
            }
        }
        await closeHosted(browser, view)
    }
}
