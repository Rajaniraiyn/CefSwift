import CCef
import CefBase
import Foundation
import Observation

/// Chromium's processes and what runs in them, with their CPU and memory
/// use, as Chrome's Task Manager shows them.
///
/// ```swift
/// Table(CefRuntime.shared.taskManager.tasks) {
///     TableColumn("Task", value: \.title)
///     TableColumn("Memory") { Text($0.memory.map { "\($0 / 1_000_000) MB" } ?? "–") }
/// }
/// ```
///
/// ``tasks`` refreshes every ``refreshInterval`` while something reads it:
/// a SwiftUI view showing it, or code that reads it again within two
/// intervals. When nothing does, refreshing stops; reading it again starts
/// it. ``refresh()`` takes one snapshot at once.
///
/// Memory and CPU figures belong to processes. Tasks that share a process
/// (several tabs of one site in one renderer, workers and their page)
/// report the same figures; add each process once, as
/// ``Process/estimatedTotalMemory(of:)`` does.
///
/// Chromium's task-manager API names no process for a task: it only lists
/// the tasks of one process one after another. ``Task/process`` and
/// ``processes`` are therefore an estimate, made by grouping consecutive
/// renderer-hosted tasks with identical, measured figures. Two separate
/// renderers that happen to report the same figures side by side are
/// grouped as one (their total is then undercounted), and tasks of one
/// process not measured yet stay apart. Use them for display, not to
/// decide which pages share a process.
@MainActor
@Observable
public final class CefTaskManager {
    /// One task: a process, or a page, frame or worker running in one.
    public struct Task: Identifiable, Sendable, Hashable {
        /// What a task is.
        public enum Kind: Sendable, Hashable {
            /// The app's own process.
            case browser
            /// The graphics process.
            case gpu
            /// A utility process, such as the network service.
            case utility
            /// A renderer process showing pages.
            case renderer
            /// An extension's process.
            case `extension`
            /// A guest view's renderer.
            case guest
            /// A sandbox helper process.
            case sandboxHelper
            /// A dedicated worker in a renderer.
            case dedicatedWorker
            /// A shared worker in a renderer.
            case sharedWorker
            /// A service worker in a renderer.
            case serviceWorker
            /// A kind Chromium does not name.
            case unknown
        }

        /// The task's identifier, unique for the app's lifetime.
        public var id: Int64
        public var kind: Kind
        /// Chromium's title for the task, such as “Tab: Example Domain”.
        public var title: String
        /// The process's CPU use, in percent of one core: up to
        /// ``CefTaskManager/processorCount`` × 100.
        public var cpuUsage: Double
        /// The process's memory footprint in bytes; `nil` until Chromium
        /// has measured it.
        public var memory: Int64?
        /// The process's GPU memory in bytes; `nil` until measured.
        public var gpuMemory: Int64?
        /// Whether ``gpuMemory`` counts other processes' resources too, as
        /// the GPU process's does.
        public var isGPUMemoryAggregate: Bool
        /// Whether ``CefTaskManager/terminate(_:)`` can end it.
        public var canTerminate: Bool
        /// The process CefKit estimates the task runs in, among the tasks
        /// of one snapshot; see ``CefTaskManager`` for how it is inferred.
        public var process: Process.ID
    }

    /// A process, as the tasks estimated to run in it: consecutive
    /// renderer-hosted tasks with identical figures. Chromium names no
    /// process, so this can join separate renderers that report the same
    /// figures, or split one whose tasks are not measured yet.
    public struct Process: Identifiable, Sendable, Hashable {
        /// The identifier of the group's first task, stable while the
        /// group keeps it.
        public var id: Int64
        /// The tasks in the process, the process's own first.
        public var tasks: [Task]

        /// The process's memory footprint, counted once.
        public var memory: Int64? { tasks.first?.memory }
        /// The process's CPU use, counted once.
        public var cpuUsage: Double { tasks.first?.cpuUsage ?? 0 }

        /// The memory of `processes` together, each counted once: an
        /// estimate, as the grouping is (it undercounts separate renderers
        /// grouped as one).
        public static func estimatedTotalMemory(of processes: [Process]) -> Int64 {
            processes.reduce(0) { $0 + max(0, $1.memory ?? 0) }
        }
    }

    /// The tasks Chromium tracks, the browser process first, then the GPU
    /// process, with tasks of one process together.
    public var tasks: [Task] {
        access(keyPath: \.tasks)
        keepRefreshing()
        return storedTasks
    }

    /// ``tasks`` grouped by estimated process, in the same order.
    public var processes: [Process] {
        Self.processes(of: tasks)
    }

    /// The number of processors, the scale of ``Task/cpuUsage``.
    public private(set) var processorCount = ProcessInfo.processInfo.activeProcessorCount

    /// How often ``tasks`` refreshes while it is read.
    public var refreshInterval: Duration = .seconds(1)

    @ObservationIgnored private var storedTasks: [Task] = []
    @ObservationIgnored private var readUntil: ContinuousClock.Instant = .now
    @ObservationIgnored private var refreshing: _Concurrency.Task<Void, Never>?
    /// Chromium measures CPU and memory only while a task manager object
    /// is alive, so one is kept while refreshing.
    @ObservationIgnored private var held: CefRef<cef_task_manager_t>?

    nonisolated init() {}

    /// Takes a snapshot now.
    public func refresh() {
        keepRefreshing()
        snapshot()
    }

    private func snapshot() {
        guard let manager = manager() else {
            setTasks([])
            return
        }
        var count = manager.pointee.get_tasks_count(manager)
        var identifiers = [Int64](repeating: 0, count: max(count, 1))
        guard manager.pointee.get_task_ids_list(manager, &count, &identifiers) != 0 else { return }
        var raw: [RawTask] = []
        for identifier in identifiers.prefix(count) {
            var info = cef_task_info_t()
            info.size = MemoryLayout<cef_task_info_t>.stride
            guard manager.pointee.get_task_info(manager, identifier, &info) != 0 else { continue }
            defer { cef_string_utf16_clear(&info.title) }
            if info.number_of_processors > 0 { processorCount = Int(info.number_of_processors) }
            raw.append(RawTask(
                id: info.id, kind: Task.Kind(cefValue: info.type), title: CefStringUtil.string(from: info.title),
                cpuUsage: info.cpu_usage, memory: info.memory, gpuMemory: info.gpu_memory,
                isGPUMemoryAggregate: info.is_gpu_memory_inflated != 0, canTerminate: info.is_killable != 0))
        }
        setTasks(Self.assignProcesses(raw))
    }

    /// The main task of `browser`: the renderer showing its page.
    public func task(for browser: CefBrowser) -> Task? {
        keepRefreshing()
        guard browser.identifier >= 0, let manager = manager() else { return nil }
        let identifier = manager.pointee.get_task_id_for_browser_id(manager, browser.identifier)
        guard identifier >= 0 else { return nil }
        if let task = tasks.first(where: { $0.id == identifier }) { return task }
        snapshot()
        return storedTasks.first { $0.id == identifier }
    }

    /// The browsers whose main task is in the group `process` names. Several
    /// browsers can share one renderer, whose memory is theirs together;
    /// since the grouping is an estimate, the list can also include a
    /// browser of a separate renderer that reported the same figures.
    public func browsers(in process: Process.ID) -> [CefBrowser] {
        keepRefreshing()
        guard let manager = manager() else { return [] }
        let identifiers = Set(storedTasks.filter { $0.process == process }.map(\.id))
        return CefRuntime.shared.browsers.filter { browser in
            browser.identifier >= 0
                && identifiers.contains(manager.pointee.get_task_id_for_browser_id(manager, browser.identifier))
        }
    }

    /// Ends `task`'s process, as Chrome's End Process does. Pages it showed
    /// report ``CefBrowserDelegate/browser(_:renderProcessDidTerminate:)``.
    /// Returns whether Chromium ended it; it does not end the browser
    /// process or tasks whose ``Task/canTerminate`` is `false`.
    @discardableResult
    public func terminate(_ task: Task) -> Bool {
        keepRefreshing()
        guard task.canTerminate, let manager = manager() else { return false }
        let ended = manager.pointee.kill_task(manager, task.id) != 0
        if ended { snapshot() }
        return ended
    }

    // MARK: Refreshing while read

    private func setTasks(_ tasks: [Task]) {
        withMutation(keyPath: \.tasks) { storedTasks = tasks }
    }

    /// Keeps a refresh loop running for two intervals after each read.
    private func keepRefreshing() {
        readUntil = .now + refreshInterval * 2
        guard refreshing == nil else { return }
        // Not refreshed here: a read can come from a view being drawn.
        refreshing = _Concurrency.Task { [weak self] in
            while let self, !_Concurrency.Task.isCancelled, CefRuntime.shared.isRunning {
                self.snapshot()
                try? await _Concurrency.Task.sleep(for: self.refreshInterval)
                guard ContinuousClock.now < self.readUntil else { break }
            }
            self?.refreshing = nil
            self?.held = nil
        }
    }

    /// Lets go of Chromium's task manager before Chromium shuts down.
    func releaseForShutdown() {
        refreshing?.cancel()
        refreshing = nil
        held = nil
    }

    /// Whether a refresh loop is running, for tests.
    @_spi(Testing) public var isRefreshing: Bool { refreshing != nil }

    // MARK: Grouping

    /// A task before its process is known.
    struct RawTask: Equatable {
        var id: Int64
        var kind: Task.Kind
        var title: String
        var cpuUsage: Double
        var memory: Int64
        var gpuMemory: Int64
        var isGPUMemoryAggregate: Bool
        var canTerminate: Bool
    }

    /// Gives each task its estimated process. Chromium lists a process's
    /// tasks one after another and reports the process's figures for each;
    /// its API (`cef_task_info_t`, `cef_task_manager_t` at CEF 156) gives no
    /// process identifier, so a task is put with the one before it when it
    /// is a renderer-hosted task with the same measured figures, as the
    /// tasks of one process always have. The converse does not hold:
    /// separate renderers with equal figures side by side are joined.
    nonisolated static func assignProcesses(_ raw: [RawTask]) -> [Task] {
        var result: [Task] = []
        var process: Int64 = -1
        var previous: RawTask?
        for task in raw {
            let sameProcess = previous.map { previous in
                task.kind.runsInRenderer && previous.kind.runsInRenderer
                    && task.memory == previous.memory && task.cpuUsage == previous.cpuUsage
                    && task.gpuMemory == previous.gpuMemory && task.memory > 0
            } ?? false
            if !sameProcess { process = task.id }
            result.append(Task(
                id: task.id, kind: task.kind, title: task.title, cpuUsage: max(0, task.cpuUsage),
                memory: task.memory >= 0 ? task.memory : nil, gpuMemory: task.gpuMemory >= 0 ? task.gpuMemory : nil,
                isGPUMemoryAggregate: task.isGPUMemoryAggregate, canTerminate: task.canTerminate, process: process))
            previous = task
        }
        return result
    }

    nonisolated static func processes(of tasks: [Task]) -> [Process] {
        var processes: [Process] = []
        for task in tasks {
            if let last = processes.last, last.id == task.process {
                processes[processes.count - 1].tasks.append(task)
            } else {
                processes.append(Process(id: task.process, tasks: [task]))
            }
        }
        return processes
    }

    /// The task manager, kept for two refresh intervals after each use;
    /// `nil` before start-up.
    private func manager() -> UnsafeMutablePointer<cef_task_manager_t>? {
        guard CefRuntime.shared.isRunning else { return nil }
        if held == nil { held = CefRef(adopting: cef_task_manager_get()) }
        return held?.pointer
    }
}

extension CefTaskManager.Task.Kind {
    init(cefValue: cef_task_type_t) {
        switch cefValue {
        case CEF_TASK_TYPE_BROWSER: self = .browser
        case CEF_TASK_TYPE_GPU: self = .gpu
        case CEF_TASK_TYPE_UTILITY: self = .utility
        case CEF_TASK_TYPE_RENDERER: self = .renderer
        case CEF_TASK_TYPE_EXTENSION: self = .extension
        case CEF_TASK_TYPE_GUEST: self = .guest
        case CEF_TASK_TYPE_SANDBOX_HELPER: self = .sandboxHelper
        case CEF_TASK_TYPE_DEDICATED_WORKER: self = .dedicatedWorker
        case CEF_TASK_TYPE_SHARED_WORKER: self = .sharedWorker
        case CEF_TASK_TYPE_SERVICE_WORKER: self = .serviceWorker
        default: self = .unknown
        }
    }

    /// Whether tasks of this kind run inside a renderer process and can
    /// share it.
    var runsInRenderer: Bool {
        switch self {
        case .renderer, .extension, .guest, .dedicatedWorker, .sharedWorker, .serviceWorker: true
        default: false
        }
    }
}

extension CefRuntime {
    /// Chromium's processes and their resource use.
    public var taskManager: CefTaskManager { CefTaskManager.shared }
}

extension CefTaskManager {
    static let shared = CefTaskManager()
}

extension CefBrowser {
    /// The task of the renderer showing this browser's page: its CPU and
    /// memory, shared with any browser in the same process
    /// (``CefTaskManager/browsers(in:)``).
    public var rendererTask: CefTaskManager.Task? { CefRuntime.shared.taskManager.task(for: self) }
}
