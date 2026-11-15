import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// What a page can observe about a CefSwift browser: nothing of the
/// DevTools protocol unless a feature that needs it is used, no automation
/// flag, no globals other than a bridge's own, and an offscreen page
/// that reports the window it is shown in. The same readings as
/// `Scripts/compat/probe.html`, on a local page.
extension SelfTest {
    static func compatibilityChecks() async {
        await plainPageChecks()
        await bridgeAndScriptChecks()
        await offscreenGeometryChecks()
    }

    private static func plainPageChecks() async {
        let page = CefPage(url: URL(string: "selftest://app/compat.html")!)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "compat")

        await expect("compatibility: navigator.webdriver is false") {
            try await page.evaluateJavaScript("[navigator.webdriver, window.__webdriver]") == [false, false]
        }
        await expect("compatibility: a debugger statement does not stop the page") {
            try await page.evaluateJavaScript("window.__debuggerMs").doubleValue.map { $0 < 50 } == true
        }
        await expect("compatibility: no automation globals") {
            try await page.evaluateJavaScript("window.__globals") == []
        }
        check("compatibility: a plain browser has no DevTools session",
              page.devTools.sentMessageCount == 0 && !page.devTools.isAttached,
              detail: "\(page.devTools.sentMessageCount) messages")
        await closeHosted(page, view)
    }

    private static func bridgeAndScriptChecks() async {
        let bridge = CefBridge(name: "app")  // The name frame.html calls.
        bridge.access = .anyFrame
        bridge.handle("greet") { (person: [String: String], call: CefBridge.Call) in
            "Hello, \(person["name"] ?? "") from \(call.frame.isMain ? "main" : "sub")!"
        }
        var configuration = CefPage.Configuration()
        configuration.bridges = [bridge]
        configuration.userScripts = [
            CefUserScript(source: "window.__start = document.readyState;"),
            CefUserScript(
                source: "document.body.dataset.end = document.readyState;",
                injectionTime: .documentEnd, frames: .mainFrame),
        ]
        let page = CefPage(url: URL(string: "selftest://app/compat.html")!, configuration: configuration)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "compat")

        await expect("compatibility: user scripts run at document start and end") {
            try await page.evaluateJavaScript("[window.__start, document.body.dataset.end]") == ["loading", "interactive"]
        }
        await expect("compatibility: the bridge is the only global it adds, and is native") {
            try await page.evaluateJavaScript("""
                [window.__globals.length, typeof app, /\\[native code\\]/.test(String(app.greet))]
                """) == [0, "object", true]
        }
        await expect("compatibility: the bridge answers") {
            try await page.evaluateJavaScript("app.greet({ name: 'Ann' })") == "Hello, Ann from main!"
        }
        await expect("compatibility: a cross-site frame gets the bridge its access allows") {
            let outcome = try await page.evaluateJavaScript("""
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
              page.devTools.sentMessageCount == 0 && !page.devTools.isAttached,
              detail: "\(page.devTools.sentMessageCount) messages")
        await closeHosted(page, view)
    }

    private static func offscreenGeometryChecks() async {
        // A window draws at the display's rate whatever the energy saver
        // does; compare at full rate, as on a Mac on power.
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = .automatic }
        var configuration = CefPage.Configuration()
        configuration.rendering = .offscreen
        let page = CefPage(url: URL(string: "selftest://app/compat.html")!, configuration: configuration)
        let view = hostOffscreen(page)
        _ = await loaded(page, title: "compat")

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
            let reported = try await page.evaluateJavaScript(
                "[screenX, screenY, outerWidth, outerHeight, screen.availWidth, screen.availHeight, devicePixelRatio]")
            if reported != expected { print("NOTE offscreen geometry \(reported.text), window \(expected.text)") }
            return reported == expected
        }
        if window.occlusionState.contains(.visible) {
            let name = "compatibility: an offscreen page gets animation frames as a window does"
            let rate = (try? await page.evaluateJavaScript("""
                new Promise(resolve => {
                  let frames = 0; const start = performance.now();
                  const tick = () => { frames++; performance.now() - start < 1000 ? requestAnimationFrame(tick) : resolve(frames); };
                  requestAnimationFrame(tick);
                })
                """, timeout: .seconds(10)).intValue) ?? 0
            if rate < 50, let reason = SelfTestReport.unsteadyFrameRateReason {
                skip(name, because: "\(rate) frames a second; \(reason)", .environment)
            } else {
                check(name, rate >= 50, detail: "\(rate) frames a second")
            }
        }
        await closeHosted(page, view)
    }
}
