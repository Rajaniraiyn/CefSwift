import AppKit
import CefKit

// A frame's text and source read natively, and loading a URLRequest with
// a method, headers and a body.
extension SelfTest {
    static func frameContentChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("frame contents", because: "the local server could not start", .environment)
            return
        }
        let base = "http://127.0.0.1:\(server.port)"
        let browser = CefBrowser(url: URL(string: "\(base)/page")!)
        let view = hostWindowed(browser)
        defer { view.removeFromSuperview() }
        guard await loaded(browser, title: "page") else {
            check("frame contents: page loads", false, detail: browser.title)
            await closeHosted(browser, view)
            return
        }

        await expect("frame contents: text(of:) reads the main frame's text") {
            let text = try await browser.text()
            return (text.contains("A page on http") && !text.contains("<p>"), text)
        }
        await expect("frame contents: source(of:) reads the main frame's HTML") {
            let source = try await browser.source()
            return (source.contains("<title>page</title>") && source.contains("id=\"link\""), String(source.prefix(200)))
        }
        _ = try? await browser.evaluateJavaScript(
            "document.body.insertAdjacentHTML('beforeend', '<iframe srcdoc=\"<p>inner words</p>\"></iframe>'); 0")
        _ = await waitUntil { browser.frames.count == 2 }
        await expect("frame contents: text(of:) reads a subframe's text") {
            guard let frame = browser.frames.first(where: { !$0.isMain }) else { return (false, "no subframe") }
            _ = await waitUntilAsync { (try? await browser.text(of: frame))?.contains("inner words") == true }
            let text = try await browser.text(of: frame)
            return (text.contains("inner words") && !text.contains("A page on http"), text)
        }
        await expect("frame contents: a frame that is gone throws") {
            do {
                _ = try await browser.text(of: CefFrame(id: "0-0", url: nil, isMain: false))
                return false
            } catch CefError.operationFailed {
                return true
            }
        }

        // POST with a header and a body, from a page of the same origin.
        var post = URLRequest(url: URL(string: "\(base)/echo-page")!)
        post.httpMethod = "POST"
        post.setValue("yes", forHTTPHeaderField: "X-SelfTest")
        post.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data("hello=world".utf8)
        await expect("frame contents: load(URLRequest) sends the method, headers and body") {
            let result = try await browser.load(post).waitUntilLoaded(timeout: .seconds(10))
            return (browser.title == "POST yes hello=world" && result.httpStatus == 200, browser.title)
        }
        await expect("frame contents: load(URLRequest) for another origin fails without sending") {
            let elsewhere = URLRequest(url: URL(string: "http://localhost:\(server.port)/echo-page")!)
            do {
                _ = try await browser.load(elsewhere).waitUntilLoaded(timeout: .seconds(5))
                return (false, "loaded")
            } catch CefError.operationFailed {
                return (browser.title == "POST yes hello=world", browser.title)
            }
        }
        await closeHosted(browser, view)
    }
}
