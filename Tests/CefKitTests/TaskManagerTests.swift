import CCef
import Foundation
import Testing

@testable import CefKit

/// Grouping Chromium's tasks into processes, without Chromium.
struct TaskManagerTests {
    private func raw(_ id: Int64, _ kind: CefTaskManager.Task.Kind, memory: Int64, cpu: Double = 1) -> CefTaskManager.RawTask {
        CefTaskManager.RawTask(
            id: id, kind: kind, title: "\(id)", cpuUsage: cpu, memory: memory, gpuMemory: -1,
            isGPUMemoryAggregate: false, canTerminate: kind != .browser)
    }

    @Test func tasksOfOneRendererShareItsProcess() {
        let tasks = CefTaskManager.assignProcesses([
            raw(1, .browser, memory: 100),
            raw(2, .gpu, memory: 100),
            raw(3, .renderer, memory: 50),
            raw(4, .renderer, memory: 50),
            raw(5, .dedicatedWorker, memory: 50),
            raw(6, .renderer, memory: 70),
            raw(7, .utility, memory: 70),
        ])
        #expect(tasks.map(\.process) == [1, 2, 3, 3, 3, 6, 7])
        let processes = CefTaskManager.processes(of: tasks)
        #expect(processes.map(\.id) == [1, 2, 3, 6, 7])
        #expect(processes[2].tasks.count == 3)
        #expect(CefTaskManager.Process.estimatedTotalMemory(of: processes) == 100 + 100 + 50 + 70 + 70)
    }

    @Test func unmeasuredFiguresAreNil() {
        let tasks = CefTaskManager.assignProcesses([raw(3, .renderer, memory: -1), raw(4, .renderer, memory: -1)])
        #expect(tasks.allSatisfy { $0.memory == nil && $0.gpuMemory == nil })
        // Without figures, two renderers are not taken for one.
        #expect(tasks.map(\.process) == [3, 4])
    }

    @Test func differentFiguresMeanDifferentProcesses() {
        let tasks = CefTaskManager.assignProcesses([raw(3, .renderer, memory: 50, cpu: 1), raw(4, .renderer, memory: 50, cpu: 2)])
        #expect(tasks.map(\.process) == [3, 4])
    }

    @Test func kindsMapFromChromium() {
        #expect(CefTaskManager.Task.Kind(cefValue: CEF_TASK_TYPE_BROWSER) == .browser)
        #expect(CefTaskManager.Task.Kind(cefValue: CEF_TASK_TYPE_RENDERER) == .renderer)
        #expect(CefTaskManager.Task.Kind(cefValue: CEF_TASK_TYPE_SERVICE_WORKER) == .serviceWorker)
        #expect(CefTaskManager.Task.Kind(cefValue: CEF_TASK_TYPE_ZYGOTE) == .unknown)
    }
}
