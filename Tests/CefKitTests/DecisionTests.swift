import Foundation
import Testing

@_spi(Testing) @testable import CefKit

/// Delegate decisions: an answer is applied exactly when its decision is
/// still pending, and a decision that ended is never applied. Without
/// Chromium.
@MainActor
struct DecisionTests {
    /// A delegate answer the test releases when it chooses.
    @MainActor final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Lets every job queued on the main actor run.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func aConsumedDecisionIsAppliedAtOnce() async {
        let browser = CefBrowser()
        let gate = Gate()
        var applied: [Int] = []
        browser.decide(.page) { _ in
            await gate.wait()
            return 1
        } then: { applied.append($0) }
        await drain()
        #expect(browser.pendingDecisionCount == 1)
        gate.open()
        // Watch for the moment the decision is consumed: it must already
        // have been applied, or a navigation in between could not stop it.
        while browser.pendingDecisionCount > 0 { await Task.yield() }
        #expect(applied == [1])
        browser.cancelDecisions { _ in true }
        await drain()
        #expect(applied == [1])
    }

    @Test func aDecisionEndedBeforeItsAnswerIsNotApplied() async {
        let browser = CefBrowser()
        let gate = Gate()
        var applied = false
        browser.decide(.page) { _ in
            await gate.wait()
            return true
        } then: { applied = $0 }
        await drain()
        browser.cancelDecisions { $0 == .page }
        gate.open()
        await drain()
        #expect(!applied)
        #expect(browser.pendingDecisionCount == 0)
    }

    @Test func anAwaitedDecisionReturnsNilWhenItEnded() async {
        let browser = CefBrowser()
        let gate = Gate()
        async let answer = browser.decision(.page) {
            await gate.wait()
            return 7
        }
        await drain()
        browser.cancelDecisions { _ in true }
        gate.open()
        #expect(await answer == nil)

        let kept = await browser.decision(.page) { 8 }
        #expect(kept == 8)
    }
}
