import os

/// A continuation that resumes exactly once: with the first value given,
/// with `CancellationError` when its task is cancelled first (for one made
/// by ``cancellable(fallback:_:)``), or, if neither happened, with
/// `fallback` when the box goes away (CEF released the callback without
/// calling it). A value given after that is dropped. Safe from any thread.
package final class CefResumeOnce<Value: Sendable>: Sendable {
    private let resumer: OSAllocatedUnfairLock<(@Sendable (Result<Value, any Error>) -> Void)?>
    private let fallback: Value

    package init(_ continuation: CheckedContinuation<Value, Never>, fallback: Value) {
        resumer = OSAllocatedUnfairLock(initialState: { result in
            // Only `cancel()` fails, and only boxes of a throwing
            // continuation are cancelled.
            if case .success(let value) = result { continuation.resume(returning: value) }
        })
        self.fallback = fallback
    }

    package init(_ continuation: CheckedContinuation<Value, any Error>, fallback: Value) {
        resumer = OSAllocatedUnfairLock(initialState: { continuation.resume(with: $0) })
        self.fallback = fallback
    }

    deinit {
        resume(returning: fallback)
    }

    /// Resumes with `value` unless resumed already; returns whether it
    /// did, so that a late result that holds something (a casting route)
    /// can be undone.
    @discardableResult
    package func resume(returning value: Value) -> Bool {
        guard let resume = take() else { return false }
        resume(.success(value))
        return true
    }

    /// Whether the box has resumed: with a value, or cancelled.
    package var isFinished: Bool {
        resumer.withLock { $0 == nil }
    }

    /// Resumes with `CancellationError` unless resumed already.
    package func cancel() {
        take()?(.failure(CancellationError()))
    }

    private func take() -> (@Sendable (Result<Value, any Error>) -> Void)? {
        resumer.withLock { pending in
            defer { pending = nil }
            return pending
        }
    }

    /// Suspends until the box `start` is given is resumed, which `start`
    /// hands to whatever completes the work (a CEF callback), or until the
    /// task is cancelled: then this throws `CancellationError` at once,
    /// and the work's result, when it comes, is dropped. `start` is not
    /// called for a task already cancelled.
    package static func cancellable(
        isolation: isolated (any Actor)? = #isolation,
        fallback: Value, _ start: (CefResumeOnce<Value>) -> Void
    ) async throws -> Value {
        let slot = Slot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let box = CefResumeOnce(continuation, fallback: fallback)
                guard slot.install(box) else { return box.cancel() }
                start(box)
            }
        } onCancel: {
            slot.cancel()
        }
    }

    /// Where the cancellation handler finds the box. It holds the box
    /// weakly, so that the box still resumes with its fallback when CEF
    /// drops the callback holding it.
    private final class Slot: Sendable {
        private struct State {
            weak var box: CefResumeOnce<Value>?
            var isCancelled = false
        }
        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        /// Whether `box` may start; false once cancelled.
        func install(_ box: CefResumeOnce<Value>) -> Bool {
            state.withLockUnchecked { state in
                guard !state.isCancelled else { return false }
                state.box = box
                return true
            }
        }

        func cancel() {
            let box = state.withLockUnchecked { state -> CefResumeOnce<Value>? in
                state.isCancelled = true
                return state.box
            }
            box?.cancel()
        }
    }
}
