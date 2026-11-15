import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// The task manager and recovering a page that stopped responding.
extension SelfTest {
    static func processChecks() async {
        let manager = CefRuntime.shared.taskManager
        let recorder = HangRecorder()
        let page = CefPage(url: capabilityOrigin.appending(path: "busy.html"))
        page.delegate = recorder
        let view = hostWindowed(page)
        defer { view.removeFromSuperview() }
        guard await loaded(page, title: "busy") else {
            check("processes: page loads", false, detail: page.title)
            return
        }

        manager.refresh()
        let tasks = manager.tasks
        check("processes: the browser process is listed first", tasks.first?.kind == .browser,
              detail: tasks.map { "\($0.kind) \($0.title)" }.joined(separator: "; "))
        let task = manager.task(for: page)
        check("processes: a browser maps to its renderer task", task?.kind == .renderer && task?.canTerminate == true,
              detail: "\(String(describing: task))")
        let served = task.map { manager.pages(in: $0.process) } ?? []
        check("processes: the renderer serves the browser", served.contains { $0 === page },
              detail: "\(served.map(\.identifier)) vs \(page.identifier); \(manager.tasks.map { "\($0.id)/\($0.process)" })")
        check("processes: memory is measured", await waitUntil(timeout: .seconds(10)) {
            manager.refresh()
            return (manager.task(for: page)?.memory ?? 0) > 1_000_000
        }, detail: "\(String(describing: manager.task(for: page)?.memory))")
        _ = manager.tasks
        check("processes: reading the tasks keeps them refreshing", manager.isRefreshing)
        check("processes: refreshing stops when nobody reads",
              // The loop ends at its first wake-up two intervals after the last read;
              // a busy Mac delays wake-ups, so allow twice that.
              await waitUntil(timeout: manager.refreshInterval * 6) { !manager.isRefreshing })

        // A page that spins: busy, then unresponsive to input.
        page.executeJavaScript("setTimeout(spin, 100)")
        check("processes: a busy page's CPU use shows", await waitUntil(timeout: .seconds(10)) {
            manager.refresh()
            return (manager.task(for: page)?.cpuUsage ?? 0) > 50
        }, detail: "\(String(describing: manager.task(for: page)?.cpuUsage))")
        page.sendTestInput()
        check("processes: an unresponsive page asks the delegate", await waitUntil(timeout: .seconds(40)) {
            recorder.asked > 0
        }, detail: "asked \(recorder.asked)")
        check("processes: the browser reports it unresponsive", recorder.wasResponsiveWhenAsked == false)
        // The crashed page keeps its title, so wait for the reload to finish.
        check("processes: reloading recovers the page", await waitUntil(timeout: .seconds(20)) {
            recorder.loadsAfterTermination > 0 && page.title == "busy" && !page.isLoading
        }, detail: "\(recorder.terminations) terminations, \(page.title)")
        await expect("processes: the reloaded page runs script and responds") {
            try await page.evaluateJavaScript("1 + 1").intValue == 2 && page.isResponsive
        }

        // End Process.
        let before = recorder.terminations
        if let task = manager.task(for: page) {
            let ended = manager.terminate(task)
            let reported = await waitUntil(timeout: .seconds(10)) { recorder.terminations > before }
            check("processes: terminate ends the renderer", ended && reported)
        } else {
            check("processes: terminate ends the renderer", false, detail: "no task")
        }
        check("processes: the browser process cannot be ended",
              tasks.first.map { !manager.terminate($0) } ?? false)
        page.close(force: true)
        _ = await waitUntil { page.state == .closed }
    }
}

@MainActor
final class HangRecorder: CefPageDelegate {
    var asked = 0
    var wasResponsiveWhenAsked: Bool?
    var terminations = 0
    var loadsAfterTermination = 0

    /// Reloads once: a second answer would reload the recovered page again.
    func pageIsUnresponsive(_ page: CefPage) async -> CefUnresponsivePageDecision {
        asked += 1
        wasResponsiveWhenAsked = page.isResponsive
        return asked == 1 ? .reload : .wait
    }

    func page(_ page: CefPage, renderProcessDidTerminate reason: CefTerminationReason) {
        terminations += 1
    }

    func page(_ page: CefPage, didFinishLoadWithStatus httpStatus: Int) {
        if terminations > 0 { loadsAfterTermination += 1 }
    }
}
