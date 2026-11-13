import CefSwiftUI
import SwiftUI

/// `CefRuntime.shared.taskManager` is Chromium's task manager as an
/// observable list: each task with its kind, CPU and memory. It refreshes
/// every second while something reads `tasks`, and stops when nothing does.
struct TaskManagerDemo: Demo {
    let title = "Task Manager"
    let summary = "Chromium's processes and what runs in them, with CPU and memory, refreshed while the table shows them."
    let symbol = "cpu"
    let category = DemoCategory.runtime

    func makeView() -> some View { TaskManagerView() }
}

private struct TaskManagerView: View {
    private let manager = CefRuntime.shared.taskManager
    @State private var selection: CefTaskManager.Task.ID?
    @Environment(\.demoReadiness) private var readiness

    var body: some View {
        let tasks = manager.tasks
        Table(tasks, selection: $selection) {
            TableColumn("Task") { task in
                Text(task.title).lineLimit(1)
            }
            TableColumn("Kind") { task in
                Text(String(describing: task.kind))
            }
            .width(min: 70, ideal: 90)
            TableColumn("CPU") { task in
                Text(task.cpuUsage, format: .number.precision(.fractionLength(1))).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Memory") { task in
                Text(task.memory?.formatted(.byteCount(style: .memory)) ?? "–").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .toolbar {
            Text("Total \(CefTaskManager.Process.estimatedTotalMemory(of: manager.processes).formatted(.byteCount(style: .memory)))")
                .foregroundStyle(.secondary)
            Button("End Process", systemImage: "xmark.octagon") {
                if let task = tasks.first(where: { $0.id == selection }) { manager.terminate(task) }
            }
            .disabled(!(tasks.first { $0.id == selection }?.canTerminate ?? false))
        }
        .onChange(of: tasks.isEmpty, initial: true) {
            if !tasks.isEmpty { readiness?.ready() }
        }
    }
}
