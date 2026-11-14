import CefSwiftUI
import SwiftUI

extension TabDiscarding {
    func start(_ controller: BrowserController) {
        MemorySaver.current.apply()
    }

    var settings: some View {
        MemorySaverSetting()
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .trailing { SleepingTabsButton() }
    }
}

/// The Memory Saver setting: when tabs in the background are put to sleep.
enum MemorySaver: String, CaseIterable {
    case off, underPressure, after15Minutes, after1Hour

    static let key = "memorySaver"

    static var current: MemorySaver {
        MemorySaver(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .after1Hour
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .underPressure: "When Memory Is Low"
        case .after15Minutes: "After 15 Minutes in the Background"
        case .after1Hour: "After an Hour in the Background"
        }
    }

    var policy: TabDiscarding.Policy {
        switch self {
        case .off: .disabled
        case .underPressure: .init(discardsUnderMemoryPressure: true)
        case .after15Minutes: .init(hiddenDuration: .seconds(15 * 60), discardsUnderMemoryPressure: true)
        case .after1Hour: .init(hiddenDuration: .seconds(60 * 60), discardsUnderMemoryPressure: true)
        }
    }

    @MainActor func apply() {
        TabDiscarding.Discarder.shared.policy = policy
    }
}

private struct MemorySaverSetting: View {
    @AppStorage(MemorySaver.key) private var memorySaver = MemorySaver.current.rawValue

    var body: some View {
        Picker(selection: $memorySaver) {
            ForEach(MemorySaver.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        } label: {
            Text("Put tabs to sleep")
            Text("Sleeping tabs free their memory and reload when you return to them.")
        }
        .onChange(of: memorySaver) { MemorySaver.current.apply() }
    }
}

/// Says how many tabs Memory Saver has put to sleep, and wakes them.
private struct SleepingTabsButton: View {
    @Environment(BrowserController.self) private var controller

    var body: some View {
        let sleeping = controller.allTabs.compactMap(\.browser).filter(\.isDiscarded)
        if !sleeping.isEmpty {
            Menu {
                Text("^[\(sleeping.count) tab](inflect: true) asleep to save memory")
                Button("Wake All Tabs") { sleeping.forEach { $0.restore() } }
            } label: {
                Label("Sleeping Tabs", systemImage: "moon.zzz")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("^[\(sleeping.count) tab](inflect: true) asleep to save memory")
        }
    }
}
