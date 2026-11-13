import CefKit
import SwiftUI

/// How a demo tells the gallery it is up, for `Gallery -smoke`. Outside
/// smoke mode nothing waits on it.
///
/// Demos report through a modifier: `.readyWhenLoaded(browser)` for a page,
/// or `.reportReady { … }` for work of their own.
@MainActor
final class DemoReadiness {
    private(set) var outcome: Result<Void, DemoFailure>?
    private var waiters: [CheckedContinuation<Result<Void, DemoFailure>, Never>] = []

    func ready() { finish(.success(())) }

    func fail(_ reason: String) { finish(.failure(DemoFailure(reason: reason))) }

    /// The first report, or a failure once `timeout` runs out.
    func wait(timeout: Duration) async -> Result<Void, DemoFailure> {
        if let outcome { return outcome }
        let timer = Task {
            try await Task.sleep(for: timeout)
            fail("no report within \(timeout)")
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(_ result: Result<Void, DemoFailure>) {
        guard outcome == nil else { return }
        outcome = result
        waiters.forEach { $0.resume(returning: result) }
        waiters = []
    }
}

struct DemoFailure: Error {
    var reason: String
}

extension EnvironmentValues {
    @Entry var demoReadiness: DemoReadiness?
}

extension View {
    /// Reports the demo ready when `work` returns, or failed with what it
    /// throws.
    func reportReady(after work: @escaping @MainActor () async throws -> Void) -> some View {
        modifier(ReportReady(work: work))
    }

    /// Reports the demo ready once each browser has loaded its page.
    func readyWhenLoaded(_ browsers: CefBrowser...) -> some View {
        reportReady {
            for browser in browsers {
                try await browser.waitUntilLoaded(timeout: .seconds(30))
            }
        }
    }
}

private struct ReportReady: ViewModifier {
    let work: @MainActor () async throws -> Void
    @Environment(\.demoReadiness) private var readiness

    func body(content: Content) -> some View {
        content.task {
            do {
                try await work()
                readiness?.ready()
            } catch is CancellationError {
            } catch {
                readiness?.fail("\(error)")
            }
        }
    }
}
