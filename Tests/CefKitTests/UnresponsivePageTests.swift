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
    @MainActor final class Delegate: CefPageDelegate {
        var asked = 0
        var cancelled = 0
        private var answers: [Int: CheckedContinuation<CefUnresponsivePageDecision, Never>] = [:]

        func pageIsUnresponsive(_ page: CefPage) async -> CefUnresponsivePageDecision {
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
        let page = CefPage()
        let delegate = Delegate()
        page.delegate = delegate
        let first = FakeCallback(), second = FakeCallback()
        #expect(page.renderProcessBecameUnresponsive(makeCallback(first)))
        await drain()
        #expect(page.renderProcessBecameUnresponsive(makeCallback(second)))
        await drain()
        #expect(delegate.asked == 2)
        #expect(page.pendingDecisionCount == 1)

        // The replaced question's late reload does nothing at all.
        delegate.answer(1, .reload)
        await drain()
        #expect(first.calls.isEmpty)
        #expect(!page.reloadsWhenRendererEnds)

        delegate.answer(2, .wait)
        await drain()
        #expect(second.calls == ["wait"])
        #expect(!page.reloadsWhenRendererEnds)
        #expect(page.pendingDecisionCount == 0)
    }

    @Test func aReloadBelongsToItsRenderer() async {
        let page = CefPage()
        let delegate = Delegate()
        page.delegate = delegate
        let callback = FakeCallback()
        _ = page.renderProcessBecameUnresponsive(makeCallback(callback))
        await drain()
        delegate.answer(1, .reload)
        await drain()
        #expect(callback.calls == ["terminate"])
        #expect(page.reloadsWhenRendererEnds)
        // Its renderer ends: the reload is used up.
        page.renderProcessEnded()
        #expect(!page.reloadsWhenRendererEnds)
    }

    @Test func respondingNavigatingOrClosingClearsAReload() async {
        for end in ["responsive", "navigation", "close"] {
            let page = CefPage()
            let delegate = Delegate()
            page.delegate = delegate
            _ = page.renderProcessBecameUnresponsive(makeCallback(FakeCallback()))
            await drain()
            delegate.answer(1, .reload)
            await drain()
            #expect(page.reloadsWhenRendererEnds, "\(end)")
            switch end {
            case "responsive": page.renderProcessBecameResponsive()
            case "navigation": page.mainFrameDidStartLoading(nil)
            default: page.handleClosed()
            }
            #expect(!page.reloadsWhenRendererEnds, "\(end)")
        }
    }

    @Test func respondingWithdrawsTheQuestion() async {
        let page = CefPage()
        let delegate = Delegate()
        page.delegate = delegate
        let callback = FakeCallback()
        _ = page.renderProcessBecameUnresponsive(makeCallback(callback))
        await drain()
        page.renderProcessBecameResponsive()
        delegate.answer(1, .reload)
        await drain()
        #expect(callback.calls.isEmpty)
        #expect(delegate.cancelled == 1)
        #expect(!page.reloadsWhenRendererEnds)
        #expect(page.isResponsive)
    }
}
