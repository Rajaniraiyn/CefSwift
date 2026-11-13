import CefBase
/// Callers suspended on one kind of asynchronous browser work: waiting for
/// creation, a script's result, a DevTools reply.
///
/// Each caller is completed exactly once: by its result, by cancellation
/// of its task (with `CancellationError`), or by the event that ends the
/// work (a navigation, the renderer going away, the browser closing),
/// whichever comes first. A result that arrives after that is dropped.
@MainActor
final class CefPendingOperations<Value: Sendable> {
    private var waiting: [Int: CheckedContinuation<Value, Error>] = [:]
    private var nextID = 0

    /// How many callers are waiting.
    var count: Int { waiting.count }

    /// Suspends until the operation is completed. `start` runs once the
    /// caller is registered, with the identifier to complete it by; it may
    /// complete it at once. A task cancelled before or while it waits
    /// throws `CancellationError`.
    func wait(_ start: (_ id: Int) -> Void = { _ in }) async throws -> Value {
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting[id] = continuation
                CefCensus.add(.custom("pending operations"), 1)
                start(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, .failure(CancellationError())) }
        }
    }

    /// Completes one caller. Returns `false` when it was completed already.
    @discardableResult
    func complete(_ id: Int, _ result: Result<Value, Error>) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        CefCensus.add(.custom("pending operations"), -1)
        continuation.resume(with: result)
        return true
    }

    /// Completes every waiting caller, oldest first.
    func completeAll(_ result: Result<Value, Error>) {
        let all = waiting.sorted { $0.key < $1.key }
        waiting = [:]
        CefCensus.add(.custom("pending operations"), -all.count)
        all.forEach { $0.value.resume(with: result) }
    }
}
