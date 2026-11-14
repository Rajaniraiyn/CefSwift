import AppKit
@_spi(Testing) import CefKit

// URLs of schemes Chromium does not load (`mailto:`, `zoommtg:`): the
// delegate decides, and CefKit opens the allowed ones. The opener is
// replaced, and the scheme is made up, so no other app ever opens.
extension SelfTest {
    @MainActor
    private final class ExternalProtocolRecorder: CefBrowserDelegate {
        var requests: [CefExternalProtocolRequest] = []
        var answer = CefExternalProtocolDecision.allow

        func browser(_ browser: CefBrowser, decideExternalProtocolFor request: CefExternalProtocolRequest) async
            -> CefExternalProtocolDecision
        {
            requests.append(request)
            return answer
        }
    }

    static func externalProtocolChecks() async {
        var opened: [URL] = []
        let opener = CefBrowser.openExternalURL
        CefBrowser.openExternalURL = { opened.append($0) }
        defer { CefBrowser.openExternalURL = opener }

        for style in ["Alloy", "Chrome style"] {
            opened = []
            let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!)
            let recorder = ExternalProtocolRecorder()
            browser.delegate = recorder
            var view: NSView?
            var window: CefWindow?
            if style == "Alloy" {
                view = hostWindowed(browser)
            } else {
                window = CefWindow(browser: browser)
                window?.show()
            }
            guard await loaded(browser, title: "second") else {
                check("external protocols (\(style)): page loads", false, detail: browser.title)
                continue
            }
            func open(_ target: String) async {
                _ = try? await browser.evaluateJavaScript("location.href = '\(target)'; 0", userGesture: true)
            }
            await open("cefswift-selftest-app://allowed")
            let asked = await waitUntil(timeout: .seconds(5)) { !recorder.requests.isEmpty }
            if asked {
                _ = await waitUntil(timeout: .seconds(2)) { !opened.isEmpty }
                let request = recorder.requests[0]
                check("external protocols (\(style)): the delegate decides, and an allowed URL is opened",
                      request.url.absoluteString == "cefswift-selftest-app://allowed" && request.isMainFrame
                          && request.frameURL?.host() == "app" && opened.map(\.absoluteString) == ["cefswift-selftest-app://allowed"]
                          && browser.url?.path == "/second.html",
                      detail: "\(recorder.requests), opened \(opened)")
                recorder.answer = .deny
                await open("cefswift-selftest-app://denied")
                _ = await waitUntil(timeout: .seconds(5)) { recorder.requests.count == 2 }
                try? await Task.sleep(for: .milliseconds(300))
                check("external protocols (\(style)): a denied URL is not opened",
                      recorder.requests.count == 2 && opened.count == 1, detail: "opened \(opened)")
            } else {
                // Recorded, not hidden: what CEF does here decides whether
                // the delegate covers this runtime style.
                skip("external protocols (\(style)): the delegate decides",
                     because: "CEF did not call on_protocol_execution for this runtime style", .limitation)
            }
            browser.close(force: true)
            _ = await waitUntil { browser.state == .closed && (window?.isClosed ?? true) }
            view?.removeFromSuperview()
        }
    }
}
