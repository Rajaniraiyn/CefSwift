import Foundation
import Testing

@testable import CefKit

/// `withDeadline`, the single deadline over a service call and its host's
/// start-up.
@MainActor
struct DeadlineTests {
    struct TimedOut: Error {}

    /// An await that ignores cancellation, as a browser's `ready()` does
    /// while Chromium never creates the browser.
    @MainActor final class Stuck {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func returnsTheOperationsResult() async throws {
        let value = try await withDeadline(.seconds(5), timeoutError: TimedOut()) { 42 }
        #expect(value == 42)
    }

    @Test func passesTheOperationsError() async {
        await #expect(throws: CefError.self) {
            try await withDeadline(.seconds(5), timeoutError: TimedOut()) { () async throws -> Int in
                throw CefError.browserClosed
            }
        }
    }

    @Test func aSuspendedAwaitDoesNotDefeatTheDeadline() async {
        let stuck = Stuck()
        var timedOut = false
        let start = ContinuousClock.now
        await #expect(throws: TimedOut.self) {
            try await withDeadline(.milliseconds(100), timeoutError: TimedOut(), onTimeout: { timedOut = true }) {
                // The start-up, then the call itself.
                await stuck.wait()
                return 1
            }
        }
        #expect(timedOut)
        #expect(ContinuousClock.now - start < .seconds(2))
        stuck.release()
    }

    @Test func theDeadlineCancelsTheOperation() async {
        var cancelled = false
        await #expect(throws: TimedOut.self) {
            try await withDeadline(.milliseconds(50), timeoutError: TimedOut()) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled = Task.isCancelled
                }
                return 0
            }
        }
        // The operation's task sees the cancellation once it runs again.
        for _ in 0..<100 where !cancelled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
    }

    @Test func cancellingTheCallerEndsTheCall() async {
        let stuck = Stuck()
        let call = Task { @MainActor in
            try await withDeadline(.seconds(30), timeoutError: TimedOut()) {
                await stuck.wait()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        stuck.release()
    }
}
