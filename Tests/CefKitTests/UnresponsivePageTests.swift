import CCef
import CefBase
import Foundation
import Testing

@_spi(Testing) @testable import CefKit

/// Unresponsive-page questions: a new notification replaces the open one,
/// a late answer to a replaced question does nothing, and a reload belongs
/// to the renderer it was asked about. Without Chromium.
@MainActor
struct UnresponsivePageTests {
    /// What CEF's callback was told.
    final class FakeCallback {
        var calls: [String] = []
    }

    private func makeCallback(_ fake: FakeCallback) -> CefRef<cef_unresponsive_process_callback_t> {
        let raw = cefAllocate(cef_unresponsive_process_callback_t.self, owner: fake)
        raw.pointee.wait = { s in cefOwner(FakeCallback.self, s)?.calls.append("wait") }
        raw.pointee.terminate = { s in cefOwner(FakeCallback.self, s)?.calls.append("terminate") }
        return CefRef(adopting: raw)
    }

    /// Answers each question when the test says so.
    @MainActor final class Delegate: CefBrowserDelegate {
        var asked = 0
        var cancelled = 0
        private var answers: [Int: CheckedContinuation<CefUnresponsivePageDecision, Never>] = [:]

        func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision {
            asked += 1
            let question = asked
            let answer = await withCheckedContinuation { answers[question] = $0 }
            if Task.isCancelled { cancelled += 1 }
            return answer
        }

        func answer(_ question: Int, _ decision: CefUnresponsivePageDecision) {
            answers.removeValue(forKey: question)?.resume(returning: decision)
        }
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aSecondNotificationReplacesTheFirst() async {
        let browser = CefBrowser()
        let delegate = Delegate()
        browser.delegate = delegate
        let first = FakeCallback(), second = FakeCallback()
        #expect(browser.renderProcessBecameUnresponsive(makeCallback(first)))
        await drain()
        #expect(browser.renderProcessBecameUnresponsive(makeCallback(second)))
        await drain()
        #expect(delegate.asked == 2)
        #expect(browser.pendingDecisionCount == 1)

        // The replaced question's late reload does nothing at all.
        delegate.answer(1, .reload)
        await drain()
        #expect(first.calls.isEmpty)
        #expect(!browser.reloadsWhenRendererEnds)

        delegate.answer(2, .wait)
        await drain()
        #expect(second.calls == ["wait"])
        #expect(!browser.reloadsWhenRendererEnds)
        #expect(browser.pendingDecisionCount == 0)
    }

    @Test func aReloadBelongsToItsRenderer() async {
        let browser = CefBrowser()
        let delegate = Delegate()
        browser.delegate = delegate
        let callback = FakeCallback()
        _ = browser.renderProcessBecameUnresponsive(makeCallback(callback))
        await drain()
        delegate.answer(1, .reload)
        await drain()
        #expect(callback.calls == ["terminate"])
        #expect(browser.reloadsWhenRendererEnds)
        // Its renderer ends: the reload is used up.
        browser.renderProcessEnded()
        #expect(!browser.reloadsWhenRendererEnds)
    }

    @Test func respondingNavigatingOrClosingClearsAReload() async {
        for end in ["responsive", "navigation", "close"] {
            let browser = CefBrowser()
            let delegate = Delegate()
            browser.delegate = delegate
            _ = browser.renderProcessBecameUnresponsive(makeCallback(FakeCallback()))
            await drain()
            delegate.answer(1, .reload)
            await drain()
            #expect(browser.reloadsWhenRendererEnds, "\(end)")
            switch end {
            case "responsive": browser.renderProcessBecameResponsive()
            case "navigation": browser.mainFrameDidStartLoading(nil)
            default: browser.handleClosed()
            }
            #expect(!browser.reloadsWhenRendererEnds, "\(end)")
        }
    }

    @Test func respondingWithdrawsTheQuestion() async {
        let browser = CefBrowser()
        let delegate = Delegate()
        browser.delegate = delegate
        let callback = FakeCallback()
        _ = browser.renderProcessBecameUnresponsive(makeCallback(callback))
        await drain()
        browser.renderProcessBecameResponsive()
        delegate.answer(1, .reload)
        await drain()
        #expect(callback.calls.isEmpty)
        #expect(delegate.cancelled == 1)
        #expect(!browser.reloadsWhenRendererEnds)
        #expect(browser.isResponsive)
    }
}
