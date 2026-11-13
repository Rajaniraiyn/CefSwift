import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Waiting for loads: `load(_:)`'s ``CefNavigation`` and
/// `waitUntilLoaded(timeout:)` end once, with the outcome of the
/// navigation they belong to, and `evaluateJavaScript`'s timeout ends only
/// the wait.
extension SelfTest {
    static func loadingChecks() async {
        let recorder = Recorder()
        let browser = CefBrowser(url: URL(string: "selftest://loading/first.html")!, delegate: recorder)
        let view = hostWindowed(browser)
        await expect("loading: waitUntilLoaded waits for a browser's first page") {
            let result = try await browser.waitUntilLoaded(timeout: .seconds(15))
            return (result.url?.lastPathComponent == "first.html" && browser.title == "first", "\(result) \(browser.title)")
        }
        await expect("loading: waitUntilLoaded returns at once once loaded") {
            let start = ContinuousClock.now
            let result = try await browser.waitUntilLoaded()
            return (ContinuousClock.now - start < .milliseconds(100) && result.url?.lastPathComponent == "first.html",
                    "\(result) after \(ContinuousClock.now - start)")
        }
        await navigationOutcomeChecks(browser, recorder: recorder)
        await evaluationTimeoutChecks(browser)
        await closeHosted(browser, view)

        // Closing fails the navigation and the wait.
        let closing = CefBrowser(url: URL(string: "selftest://loading/first.html")!)
        let closingView = hostWindowed(closing)
        _ = try? await closing.waitUntilLoaded(timeout: .seconds(15))
        let navigation = closing.load(URL(string: "selftest://loading/slow.html")!)
        var waitError: Error?
        var navigationError: Error?
        Task { do { try await closing.waitUntilLoaded() } catch { waitError = error } }
        Task { do { try await navigation.waitUntilLoaded() } catch { navigationError = error } }
        try? await Task.sleep(for: .milliseconds(200))
        await closeHosted(closing, closingView)
        check("loading: closing the browser fails the navigation and the wait with browserClosed",
              await waitUntil(timeout: .seconds(2)) { isBrowserClosed(waitError) && isBrowserClosed(navigationError) },
              detail: "\(String(describing: navigationError)), \(String(describing: waitError))")
        let afterClose = closing.load(URL(string: "selftest://loading/first.html")!)
        let afterCloseError = await failure(of: afterClose)
        check("loading: a closed browser's load has failed already",
              afterClose.outcome != nil && isBrowserClosed(afterCloseError))
    }

    static func navigationOutcomeChecks(_ browser: CefBrowser, recorder: Recorder) async {
        await expect("loading: load(_:) finishes with its own page") {
            let result = try await browser.load(URL(string: "selftest://loading/second.html")!).waitUntilLoaded(timeout: .seconds(10))
            return (result.url?.lastPathComponent == "second.html" && browser.title == "second" && !result.isSameDocument,
                    "\(result) \(browser.title)")
        }
        await expect("loading: a fragment finishes in the same document") {
            let result = try await browser.load(URL(string: "selftest://loading/second.html#part")!)
                .waitUntilLoaded(timeout: .seconds(5))
            return (result.isSameDocument && result.url?.fragment == "part", "\(result)")
        }
        await expect("loading: the fragment shown, loaded again, finishes") {
            let result = try await browser.load(URL(string: "selftest://loading/second.html#part")!)
                .waitUntilLoaded(timeout: .seconds(5))
            return (result.url?.fragment == "part", "\(result)")
        }
        await expect("loading: a second load supersedes the first") {
            let first = browser.load(URL(string: "selftest://loading/slow.html")!)
            let second = browser.load(URL(string: "selftest://loading/third.html")!)
            let result = try await second.waitUntilLoaded(timeout: .seconds(10))
            let error = await failure(of: first)
            return (isSuperseded(error) && result.url?.lastPathComponent == "third.html", "\(String(describing: error)) \(result)")
        }
        await expect("loading: going back supersedes the load, and waitUntilLoaded follows it") {
            let slow = browser.load(URL(string: "selftest://loading/slow.html")!)
            try? await Task.sleep(for: .milliseconds(200))
            browser.goBack()
            let settled = try await browser.waitUntilLoaded(timeout: .seconds(10))
            let error = await failure(of: slow)
            return (isSuperseded(error) && settled.url?.lastPathComponent == "second.html" && browser.title == "second",
                    "\(String(describing: error)) \(settled)")
        }
        await expect("loading: the timeout ends the wait and the load goes on") {
            let slow = browser.load(URL(string: "selftest://loading/slow.html")!)
            var timedOut = false
            do { try await slow.waitUntilLoaded(timeout: .milliseconds(300)) } catch { timedOut = isTimedOut(error) }
            let result = try await slow.waitUntilLoaded(timeout: .seconds(10))
            return (timedOut && result.url?.lastPathComponent == "slow.html" && browser.title == "slow", "\(timedOut) \(result)")
        }
        await expect("loading: cancelling the waiting task ends the wait with CancellationError") {
            let slow = browser.load(URL(string: "selftest://loading/slow.html")!)
            let error = await errorAfterCancelling { try await slow.waitUntilLoaded() }
            let finished = try await slow.waitUntilLoaded(timeout: .seconds(10))
            return (error is CancellationError && finished.url?.lastPathComponent == "slow.html", "\(String(describing: error))")
        }
        await expect("loading: stopLoading() ends the load with ERR_ABORTED") {
            let slow = browser.load(URL(string: "selftest://loading/slow.html")!)
            try? await Task.sleep(for: .milliseconds(200))
            browser.stopLoading()
            let error = await failure(of: slow)
            return ((error as? CefLoadError)?.isCancellation == true, "\(String(describing: error))")
        }
        await expect("loading: a failed load throws its CefLoadError") {
            let error = await failure(of: browser.load(URL(string: "https://nonexistent.invalid/")!))
            guard let loadError = error as? CefLoadError else { return (false, "\(String(describing: error))") }
            return (!loadError.isCancellation && recorder.loadErrors.contains(loadError), "\(loadError)")
        }
        await expect("loading: waitUntilLoaded throws the last load's error while it shows") {
            do {
                try await browser.waitUntilLoaded(timeout: .seconds(2))
                return (false, "returned")
            } catch {
                return (error is CefLoadError, "\(error)")
            }
        }

        guard let server = try? await LocalServer.start() else {
            skip("loading: HTTP outcomes", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        await expect("loading: an HTTP page finishes with its status") {
            let result = try await browser.load(URL(string: "\(base)/page")!).waitUntilLoaded(timeout: .seconds(10))
            return (result.httpStatus == 200 && browser.title == "page", "\(result)")
        }
        await expect("loading: a 404 page finishes with status 404") {
            let result = try await browser.load(URL(string: "\(base)/status?404")!).waitUntilLoaded(timeout: .seconds(10))
            return (result.httpStatus == 404, "\(result)")
        }
        await expect("loading: a server redirect is part of the navigation") {
            let result = try await browser.load(URL(string: "\(base)/redirect-page")!).waitUntilLoaded(timeout: .seconds(10))
            return (result.url?.path() == "/page" && result.httpStatus == 200, "\(result)")
        }
        await expect("loading: a 204 response ends the load with ERR_ABORTED and keeps the page") {
            let error = await failure(of: browser.load(URL(string: "\(base)/status?204")!))
            return ((error as? CefLoadError)?.isCancellation == true && browser.title == "page" && !browser.isLoading,
                    "\(String(describing: error)) \(browser.title)")
        }
        await expect("loading: a download ends the load with ERR_ABORTED and keeps the page") {
            recorder.downloadDestination = nil
            let error = await failure(of: browser.load(URL(string: "\(base)/loading.txt")!))
            return ((error as? CefLoadError)?.isCancellation == true && browser.title == "page",
                    "\(String(describing: error)) \(browser.title)")
        }
        await expect("loading: a renderer crash while the document loads fails the load") {
            let stalled = browser.load(URL(string: "selftest://loading/stalled.html")!)
            guard await waitUntil(timeout: .seconds(10), { browser.title == "stalled" }) else { return (false, browser.title) }
            let crash = browser.load(URL(string: "chrome://crash")!)
            let error = await failure(of: stalled)
            let crashError = await failure(of: crash)
            return (isTerminated(error) && isTerminated(crashError),
                    "\(String(describing: error)), \(String(describing: crashError))")
        }
        await expect("loading: a load after a crash finishes") {
            let result = try await browser.load(URL(string: "selftest://loading/first.html")!).waitUntilLoaded(timeout: .seconds(10))
            return (result.url?.lastPathComponent == "first.html" && browser.title == "first", "\(result)")
        }
    }

    static func evaluationTimeoutChecks(_ browser: CefBrowser) async {
        await expect("evaluation: a timeout ends the wait for a promise that never settles") {
            let start = ContinuousClock.now
            do {
                try await browser.evaluateJavaScript("new Promise(() => {})", timeout: .milliseconds(300))
                return (false, "returned")
            } catch {
                return (isTimedOut(error) && ContinuousClock.now - start < .seconds(3), "\(error)")
            }
        }
        await expect("evaluation: the script goes on after its timeout, and the page keeps working") {
            var timedOut = false
            do {
                _ = try await browser.evaluateJavaScript(
                    "new Promise(resolve => setTimeout(() => { window.__late = 'ran'; resolve(1); }, 600))",
                    as: Int.self, timeout: .milliseconds(100))
            } catch {
                timedOut = isTimedOut(error)
            }
            try? await Task.sleep(for: .seconds(1))
            let late = try await browser.evaluateJavaScript("window.__late", as: String.self, timeout: .seconds(5))
            let sum = try await browser.evaluateJavaScript("1 + 1", timeout: .seconds(5)).intValue
            return (timedOut && late == "ran" && sum == 2, "\(timedOut) \(late) \(String(describing: sum))")
        }
        await expect("evaluation: a timeout in a frame ends the wait") {
            guard let frame = browser.mainFrame else { return (false, "no main frame") }
            do {
                try await browser.evaluateJavaScript("new Promise(() => {})", in: frame, timeout: .milliseconds(200))
                return (false, "returned")
            } catch {
                let after = try await browser.evaluateJavaScript("2 + 2", as: Int.self, in: frame, timeout: .seconds(5))
                return (isTimedOut(error) && after == 4, "\(error) \(after)")
            }
        }
        await expect("evaluation: a value in time is returned with a timeout") {
            try await browser.evaluateJavaScript("Promise.resolve(7)", userGesture: true, timeout: .seconds(5)).intValue == 7
        }
    }

    /// How `navigation` failed, or `nil` when it finished or took longer
    /// than 10 seconds.
    static func failure(of navigation: CefNavigation) async -> Error? {
        do {
            try await navigation.waitUntilLoaded(timeout: .seconds(10))
            return nil
        } catch {
            return error
        }
    }

    static func isSuperseded(_ error: Error?) -> Bool {
        if case .navigationSuperseded? = error as? CefError { true } else { false }
    }

    static func isTimedOut(_ error: Error?) -> Bool {
        if case .timedOut? = error as? CefError { true } else { false }
    }

    static func isTerminated(_ error: Error?) -> Bool {
        if case .renderProcessTerminated? = error as? CefError { true } else { false }
    }
}

/// Pages for the loading checks, at `selftest://loading/…`: any name is a
/// page titled with it; `slow.html` arrives after 2 seconds, and
/// `stalled.html` shows at once but keeps loading an image for 8.
struct LoadingPages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let path = request.url?.path ?? ""
        let name = path.dropFirst().split(separator: ".").first.map(String.init) ?? "page"
        switch path {
        case "/slow.html":
            try? await Task.sleep(for: .seconds(2))
        case "/stalled.html":
            return Self.page("<title>stalled</title><p>stalled</p><img src=stalled.png>")
        case "/stalled.png":
            try? await Task.sleep(for: .seconds(8))
            return CefSchemeResponse(mimeType: "image/png", body: EdgePages.iconPNG)
        default:
            break
        }
        return Self.page("<title>\(name)</title><p>\(name)</p>")
    }

    private static func page(_ html: String) -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
