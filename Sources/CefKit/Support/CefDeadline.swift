import Foundation

/// Runs `operation` with one deadline over all of it.
///
/// The caller gets an answer by `timeout` whatever `operation` awaits: when
/// the deadline passes first, `operation`'s task is cancelled, `onTimeout`
/// runs, and the call throws `timeoutError` at once, even if `operation`
/// stays suspended in an await that ignores cancellation. Cancelling the
/// calling task cancels `operation` and throws `CancellationError`.
@MainActor
func withDeadline<T>(
    _ timeout: Duration,
    timeoutError: any Error,
    onTimeout: @escaping @MainActor () -> Void = {},
    _ operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            race.work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.timer = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, race.isPending else { return }
                race.work?.cancel()
                onTimeout()
                race.finish(.failure(timeoutError))
            }
        }
    } onCancel: {
        Task { @MainActor in
            race.work?.cancel()
            race.finish(.failure(CancellationError()))
        }
    }
    // Kept on the main actor, so `T` need not be `Sendable`.
    guard let value = race.value else { throw CancellationError() }
    return value
}

@MainActor
private final class DeadlineRace<T> {
    var continuation: CheckedContinuation<Void, any Error>?
    var value: T?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    var isPending: Bool { continuation != nil }

    func finish(_ result: Result<T, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        switch result {
        case .success(let value):
            self.value = value
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
