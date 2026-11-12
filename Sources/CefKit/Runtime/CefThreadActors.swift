import CCef
import CefBase
import Dispatch
import os

/// A global actor whose code runs on Chromium's IO thread in the browser
/// process, the thread that carries network requests and IPC.
///
/// CEF calls request filters (``CefRequestFilter``) and parts of scheme
/// handling on this thread. Code isolated to this actor runs there too, so
/// state such a filter keeps needs no lock and no hop to the main thread:
///
/// ```swift
/// @CefIOActor var blockedCount = 0
///
/// options.requestFilter = { @CefIOActor request in
///     guard request.url?.host() == "ads.example" else { return .allow }
///     blockedCount += 1
///     return .block
/// }
/// ```
///
/// Never block this thread: no file or network I/O, no waiting on locks
/// another thread holds for long. Blocking work belongs on ``CefFileActor``.
///
/// Before Chromium starts, and after it shuts down, the actor's jobs run
/// on a serial queue of its own, so work sent to it never waits forever;
/// code there must not call into CEF.
@globalActor
public actor CefIOActor {
    public static let shared = CefIOActor()

    private init() {}

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        CefThreadExecutor.io.asUnownedSerialExecutor()
    }

    public static var sharedUnownedExecutor: UnownedSerialExecutor {
        CefThreadExecutor.io.asUnownedSerialExecutor()
    }

    /// Runs `operation` synchronously as code isolated to this actor, from
    /// code that is on Chromium's IO thread without the compiler knowing,
    /// such as a CEF callback. Stops the program when called elsewhere.
    ///
    /// Unlike `Actor.assumeIsolated(_:)`, this works on macOS 14, which
    /// cannot ask an executor whether it owns the current thread.
    public static func assumeIsolated<T: Sendable>(
        _ operation: @CefIOActor () throws -> T, file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> T {
        precondition(CefThreadExecutor.io.isCurrent, "Expected to run on Chromium's IO thread.", file: file, line: line)
        // As MainActor.assumeIsolated does: the check above stands in for
        // the static isolation the closure's type asks for.
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }
}

/// A global actor whose code runs on Chromium's sequence for blocking work
/// that affects what the user sees (`TID_FILE_USER_VISIBLE`), such as
/// reading files a page is waiting for.
///
/// Its jobs run one at a time, in order, on threads of Chromium's pool
/// that may block. ``CefDirectorySchemeHandler`` reads files here.
///
/// Before Chromium starts, and after it shuts down, the actor's jobs run
/// on a serial queue of its own; code there must not call into CEF.
@globalActor
public actor CefFileActor {
    public static let shared = CefFileActor()

    private init() {}

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        CefThreadExecutor.file.asUnownedSerialExecutor()
    }

    public static var sharedUnownedExecutor: UnownedSerialExecutor {
        CefThreadExecutor.file.asUnownedSerialExecutor()
    }

    /// Runs `operation` synchronously as code isolated to this actor, from
    /// code that runs on its sequence without the compiler knowing. Stops
    /// the program when called elsewhere.
    public static func assumeIsolated<T: Sendable>(
        _ operation: @CefFileActor () throws -> T, file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> T {
        precondition(CefThreadExecutor.file.isCurrent, "Expected to run on Chromium's file sequence.", file: file, line: line)
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }
}

// MARK: - Executor

/// A serial executor backed by one of CEF's browser-process task runners.
///
/// Jobs go to Chromium with `cef_post_task`. Isolation checks
/// (`checkIsolated()`, `isIsolatingCurrentContext()`) ask
/// `cef_currently_on`, so code that CEF calls on the thread is recognized
/// as isolated to the executor without a hop.
///
/// Chromium's task runners exist only between context initialization and
/// `cef_shutdown()`. Outside that span jobs run on a private serial queue:
/// before start-up at once, and after shutdown once Chromium's threads have
/// stopped. Start-up waits for that queue to empty before jobs go to
/// Chromium, so the executor never runs two jobs at the same time.
final class CefThreadExecutor: SerialExecutor, Sendable {
    static let io = CefThreadExecutor(thread: TID_IO, label: "io")
    static let file = CefThreadExecutor(thread: TID_FILE_USER_VISIBLE, label: "file")
    static let all = [io, file]

    private enum Phase {
        /// Before Chromium's context is initialized: jobs run on the queue.
        case notStarted
        /// Waiting for the queue to empty; jobs are held.
        case starting
        /// Jobs go to Chromium.
        case running
        /// Chromium is shutting down; jobs are held until it has.
        case stopping
        /// After `cef_shutdown()`: jobs run on the queue.
        case stopped
    }

    private struct State {
        var phase = Phase.notStarted
        /// Jobs waiting for a phase change, in order.
        var held: [UnownedJob] = []
    }

    let thread: cef_thread_id_t
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(thread: cef_thread_id_t, label: String) {
        self.thread = thread
        queue = DispatchQueue(label: "CefSwift.\(label)-fallback")
        queue.setSpecific(key: queueKey, value: 1)
    }

    // MARK: Lifecycle

    /// Chromium's context is initialized: from now on jobs go to Chromium.
    /// Called on the main thread.
    func start() {
        state.withLock { $0.phase = .starting }
        // Jobs already on the queue finish first.
        queue.sync {}
        state.withLock { state in
            state.phase = .running
            for job in state.held { post(job) }
            state.held = []
        }
    }

    /// Chromium is about to shut down. Jobs sent from now on wait until
    /// ``didStop()``.
    func willStop() {
        state.withLock { $0.phase = .stopping }
    }

    /// `cef_shutdown()` has returned and Chromium's threads are gone.
    func didStop() {
        let held = state.withLock { state in
            state.phase = .stopped
            defer { state.held = [] }
            return state.held
        }
        for job in held { runOnQueue(job) }
    }

    // MARK: SerialExecutor

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let runsOnQueue = state.withLock { state -> Bool in
            switch state.phase {
            case .notStarted, .stopped:
                return true
            case .starting, .stopping:
                state.held.append(job)
            case .running:
                post(job)
            }
            return false
        }
        if runsOnQueue { runOnQueue(job) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Called by the runtime, on macOS 15 and later, when code checks that
    /// it is isolated to an actor on this executor from outside one of its
    /// jobs, as in `assumeIsolated` inside a CEF callback.
    func checkIsolated() {
        precondition(isCurrent, "Expected to run on CEF thread \(thread.rawValue).")
    }

    func isIsolatingCurrentContext() -> Bool? {
        isCurrent
    }

    /// Whether the calling thread runs this executor's jobs: Chromium's
    /// thread or sequence while it runs, the private queue otherwise.
    var isCurrent: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return true }
        let phase = state.withLock { $0.phase }
        guard phase == .running || phase == .stopping || phase == .starting, ccef_is_framework_loaded() != 0
        else { return false }
        return cef_currently_on(thread) != 0
    }

    // MARK: Running jobs

    /// Posts `job` to Chromium. Called with the state locked, so a post
    /// never races `willStop()`.
    private func post(_ job: UnownedJob) {
        let task = cefAllocate(cef_task_t.self, owner: PostedJob(job, executor: self))
        task.pointee.execute = { s in
            cefOwner(PostedJob.self, s)?.run()
        }
        // Consumes the task. A task Chromium drops without running is
        // handed back by PostedJob's deinit.
        _ = cef_post_task(thread, task)
    }

    private func runOnQueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    /// A job Chromium destroyed without running it, which only happens
    /// while it shuts down. It runs on the queue once Chromium has stopped.
    fileprivate func jobWasDropped(_ job: UnownedJob) {
        let runsNow = state.withLock { state -> Bool in
            guard state.phase == .stopped else {
                state.held.append(job)
                return false
            }
            return true
        }
        if runsNow { runOnQueue(job) }
    }
}

/// One job posted to Chromium.
private final class PostedJob: Sendable {
    private let job: OSAllocatedUnfairLock<UnownedJob?>
    private let executor: CefThreadExecutor

    init(_ job: UnownedJob, executor: CefThreadExecutor) {
        self.job = OSAllocatedUnfairLock(initialState: job)
        self.executor = executor
    }

    func run() {
        guard let job = job.withLock({ $0.take() }) else { return }
        job.runSynchronously(on: executor.asUnownedSerialExecutor())
    }

    deinit {
        if let job = job.withLock({ $0.take() }) {
            executor.jobWasDropped(job)
        }
    }
}
