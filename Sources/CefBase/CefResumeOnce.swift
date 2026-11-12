import os

/// A continuation that resumes exactly once: with the first value given,
/// or, if none was, with `fallback` when the box goes away (CEF released
/// the callback without calling it). Safe from any thread.
package final class CefResumeOnce<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>
    private let fallback: Value

    package init(_ continuation: CheckedContinuation<Value, Never>, fallback: Value) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        self.fallback = fallback
    }

    deinit {
        resume(returning: fallback)
    }

    /// Resumes with `value` unless resumed already.
    package func resume(returning value: Value) {
        continuation.withLock { pending in
            defer { pending = nil }
            return pending
        }?.resume(returning: value)
    }
}
