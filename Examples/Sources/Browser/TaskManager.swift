import AppKit
import CefSwiftUI
import SwiftUI

/// Window ▸ Task Manager: Chromium's processes, what runs in them and what
/// they use.
@MainActor
enum TaskManagerWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Task Manager"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: TaskManagerView())
        window.setFrameAutosaveName("TaskManager")
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}

struct TaskManagerView: View {
    // Reading `tasks` keeps it refreshing while the window shows it.
    private let manager = CefRuntime.shared.taskManager
    @State private var selection: Set<CefTaskManager.Task.ID> = []

    var body: some View {
        let tasks = manager.tasks
        VStack(spacing: 0) {
            Table(tasks, selection: $selection) {
                TableColumn("Task") { task in
                    Label(task.title, systemImage: Self.symbol(for: task.kind))
                        .lineLimit(1)
                        .padding(.leading, isFirstOfProcess(task, in: tasks) ? 0 : 14)
                }
                TableColumn("Memory") { task in
                    Text(isFirstOfProcess(task, in: tasks) ? Self.bytes(task.memory) : "")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("CPU") { task in
                    Text(isFirstOfProcess(task, in: tasks) ? String(format: "%.1f", task.cpuUsage) : "")
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 60, max: 80)
            }
            Divider()
            HStack {
                Text("Total \(Self.bytes(CefTaskManager.Process.estimatedTotalMemory(of: manager.processes)))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("End Process", action: endSelected)
                    .disabled(!tasks.contains { selection.contains($0.id) && $0.canTerminate })
            }
            .padding(10)
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 240, idealHeight: 380)
    }

    /// Figures belong to processes: shown once, on a process's first task.
    private func isFirstOfProcess(_ task: CefTaskManager.Task, in tasks: [CefTaskManager.Task]) -> Bool {
        guard let index = tasks.firstIndex(of: task), index > 0 else { return true }
        return tasks[index - 1].process != task.process
    }

    private func endSelected() {
        for task in manager.tasks where selection.contains(task.id) { manager.terminate(task) }
        selection = []
    }

    private static func bytes(_ value: Int64?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private static func symbol(for kind: CefTaskManager.Task.Kind) -> String {
        switch kind {
        case .browser: "macwindow"
        case .gpu: "cpu"
        case .renderer, .guest: "doc.richtext"
        case .utility, .sandboxHelper: "gearshape.2"
        case .extension: "puzzlepiece.extension"
        case .dedicatedWorker, .sharedWorker, .serviceWorker: "gearshape"
        case .unknown: "questionmark.square.dashed"
        }
    }
}
