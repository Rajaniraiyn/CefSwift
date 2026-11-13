import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// The task manager and recovering a page that stopped responding.
extension SelfTest {
    static func processChecks() async {
        let manager = CefRuntime.shared.taskManager
        let recorder = HangRecorder()
        let browser = CefBrowser(url: capabilityOrigin.appending(path: "busy.html"))
        browser.delegate = recorder
        let view = hostWindowed(browser)
        defer { view.removeFromSuperview() }
        guard await waitUntil({ browser.title == "busy" && !browser.isLoading }) else {
            check("processes: page loads", false, detail: browser.title)
            return
        }

        manager.refresh()
        let tasks = manager.tasks
        check("processes: the browser process is listed first", tasks.first?.kind == .browser,
              detail: tasks.map { "\($0.kind) \($0.title)" }.joined(separator: "; "))
        let task = browser.rendererTask
        check("processes: a browser maps to its renderer task", task?.kind == .renderer && task?.canTerminate == true,
              detail: "\(String(describing: task))")
        let served = task.map { manager.browsers(in: $0.process) } ?? []
        check("processes: the renderer serves the browser", served.contains { $0 === browser },
              detail: "\(served.map(\.identifier)) vs \(browser.identifier); \(manager.tasks.map { "\($0.id)/\($0.process)" })")
        check("processes: memory is measured", await waitUntil(timeout: .seconds(10)) {
            manager.refresh()
            return (browser.rendererTask?.memory ?? 0) > 1_000_000
        }, detail: "\(String(describing: browser.rendererTask?.memory))")
        _ = manager.tasks
        check("processes: reading the tasks keeps them refreshing", manager.isRefreshing)
        check("processes: refreshing stops when nobody reads",
              await waitUntil(timeout: manager.refreshInterval * 3) { !manager.isRefreshing })

        // A page that spins: busy, then unresponsive to input.
        browser.executeJavaScript("setTimeout(spin, 100)")
        check("processes: a busy page's CPU use shows", await waitUntil(timeout: .seconds(10)) {
            manager.refresh()
            return (browser.rendererTask?.cpuUsage ?? 0) > 50
        }, detail: "\(String(describing: browser.rendererTask?.cpuUsage))")
        browser.sendTestInput()
        check("processes: an unresponsive page asks the delegate", await waitUntil(timeout: .seconds(40)) {
            recorder.asked > 0
        }, detail: "asked \(recorder.asked)")
        check("processes: the browser reports it unresponsive", recorder.wasResponsiveWhenAsked == false)
        // The crashed page keeps its title, so wait for the reload to finish.
        check("processes: reloading recovers the page", await waitUntil(timeout: .seconds(20)) {
            recorder.loadsAfterTermination > 0 && browser.title == "busy" && !browser.isLoading
        }, detail: "\(recorder.terminations) terminations, \(browser.title)")
        await expect("processes: the reloaded page runs script and responds") {
            try await browser.evaluateJavaScript("1 + 1").intValue == 2 && browser.isResponsive
        }

        // End Process.
        let before = recorder.terminations
        if let task = browser.rendererTask {
            let ended = manager.terminate(task)
            let reported = await waitUntil(timeout: .seconds(10)) { recorder.terminations > before }
            check("processes: terminate ends the renderer", ended && reported)
        } else {
            check("processes: terminate ends the renderer", false, detail: "no task")
        }
        check("processes: the browser process cannot be ended",
              tasks.first.map { !manager.terminate($0) } ?? false)
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
    }
}

@MainActor
final class HangRecorder: CefBrowserDelegate {
    var asked = 0
    var wasResponsiveWhenAsked: Bool?
    var terminations = 0
    var loadsAfterTermination = 0

    /// Reloads once: a second answer would reload the recovered page again.
    func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision {
        asked += 1
        wasResponsiveWhenAsked = browser.isResponsive
        return asked == 1 ? .reload : .wait
    }

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        terminations += 1
    }

    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {
        if terminations > 0 { loadsAfterTermination += 1 }
    }
}
