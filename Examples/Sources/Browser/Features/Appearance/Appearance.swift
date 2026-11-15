import AppKit
import CefSwiftUI
import SwiftUI

/// Settings › Appearance (`-appearance light|dark|system`): the app's
/// windows, and the pages' `prefers-color-scheme` through
/// `CefProfile.setColorScheme`.
struct Appearance: BrowserFeature {
    enum Choice: String, CaseIterable {
        case system, light, dark

        static let key = "appearance"

        static var current: Choice {
            Choice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        @MainActor func apply() {
            switch self {
            case .system:
                NSApp.appearance = nil
                CefProfile.default.setColorScheme(.system)
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
                CefProfile.default.setColorScheme(.light)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
                CefProfile.default.setColorScheme(.dark)
            }
        }
    }

    func start(_ controller: BrowserController) {
        Choice.current.apply()
    }

    var settings: some View {
        Setting()
    }

    private struct Setting: View {
        @AppStorage(Choice.key) private var appearance = Choice.system.rawValue

        var body: some View {
            Picker("Appearance", selection: $appearance) {
                ForEach(Choice.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: appearance) { Choice.current.apply() }
        }
    }
}
