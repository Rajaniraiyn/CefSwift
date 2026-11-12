import CCef
import CefBase

/// Work posted to the renderer's main thread (`TID_RENDERER`).
final class CefRendererTask: @unchecked Sendable {
    private let body: @MainActor () -> Void

    private init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    /// Runs `body` on the renderer's main thread as a task of its own.
    static func post(_ body: @escaping @MainActor () -> Void) {
        let task = cefAllocate(cef_task_t.self, owner: CefRendererTask(body))
        task.pointee.execute = { s in
            guard let owner = cefOwner(CefRendererTask.self, s) else { return }
            MainActor.assumeIsolated { owner.body() }
        }
        // cef_post_task consumes the task.
        _ = cef_post_task(TID_RENDERER, task)
    }
}

extension V8Context {
    /// Runs the context's pending promise jobs.
    ///
    /// A message from the browser process arrives inside a scope that
    /// defers promise jobs, and Blink runs a context's jobs only after its
    /// own tasks, so a promise settled while handling a message would wait
    /// for the page's next task. Entering the context from a task of its
    /// own makes CEF's scope the outermost one, which runs the jobs as it
    /// exits.
    func runMicrotasksSoon() {
        CefRendererTask.post { [self] in
            guard isValid else { return }
            entered {}
        }
    }
}
