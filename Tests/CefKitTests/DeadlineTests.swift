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
        // A defeated deadline never returns; the bound only has to tell that
        // from a main actor kept busy by other tests under a sanitizer.
        #expect(ContinuousClock.now - start < .seconds(60))
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

    /// Cancelled from the main thread, as a superseded query is, the caller
    /// resumes in the same turn rather than after a hop through a new task.
    @Test func cancellingFromTheMainThreadResumesTheCallerAtOnce() async {
        let stuck = Stuck()
        var resumed = false
        let call = Task { @MainActor in
            defer { resumed = true }
            return try await withDeadline(.seconds(30), timeoutError: TimedOut()) {
                await stuck.wait()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        call.cancel()
        // The continuation resumed already: the caller runs on its next
        // turns, without waiting for the stuck operation.
        for _ in 0..<100 where !resumed { await Task.yield() }
        #expect(resumed)
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        stuck.release()
    }
}

/// `CefPendingOperations`: callers waiting for a script's result, a
/// DevTools reply, a browser's creation.
@MainActor
struct PendingOperationsTests {
    @Test func aCancelledWaiterResumesAtOnceAndItsLateResultIsDropped() async {
        let pending = CefPendingOperations<Int>()
        var id = 0
        let waiter = Task { @MainActor in try await pending.wait { id = $0 } }
        while id == 0 { await Task.yield() }
        #expect(pending.count == 1)
        waiter.cancel()
        // Cancelled on the main thread: no longer waiting, before any hop.
        #expect(pending.count == 0)
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
        // The result arriving afterwards finds no one and is dropped.
        pending.complete(id, .success(1))
        #expect(pending.count == 0)
    }

    @Test func aWaiterCancelledBeforeItWaitsNeverRegisters() async {
        let pending = CefPendingOperations<Int>()
        var started = false
        let waiter = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pending.wait { _ in started = true }
        }
        let result = await waiter.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!started && pending.count == 0)
    }

    @Test func completingAllResumesEveryWaiter() async {
        let pending = CefPendingOperations<Int>()
        let waiters = (0..<100).map { _ in Task { @MainActor in try await pending.wait() } }
        while pending.count < 100 { await Task.yield() }
        pending.completeAll(.failure(CefError.browserClosed))
        for waiter in waiters {
            let result = await waiter.result
            #expect(throws: CefError.self) { try result.get() }
        }
        #expect(pending.count == 0)
    }
}
