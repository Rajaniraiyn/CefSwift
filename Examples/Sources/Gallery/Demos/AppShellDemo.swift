import CefChromium
import CefSwiftUI
import SwiftUI

/// An app shell, not a browser: one window of Chromium's tabs used as the
/// app's sections, with fixed app chrome and no tab interface at all. Each
/// section keeps its page alive in the background, as a tab does, and the
/// app switches between them by command.
struct AppShellDemo: Demo {
    let title = "App Shell"
    let summary = "A window whose Chromium tabs are an app's sections: fixed chrome of the app's own, no tabs shown, sections switched by command and kept loaded in the background."
    let symbol = "rectangle.3.group"
    let category = DemoCategory.windows

    func makeView() -> some View { AppShell() }
}

private struct AppShell: View {
    @State private var window: CefChromeWindow?
    private let sections = ["Home", "Library", "Search"]

    var body: some View {
        ContentUnavailableView {
            Label("App Shell", systemImage: "rectangle.3.group")
        } description: {
            Text("The window beside the gallery shows three sections, each a Chromium tab; its bar is the app's.")
        }
        .reportReady {
            let window = try await CefChromeWindow.open(url: SamplePage.tour[0].url)
            window.showsChromeUI = false
            for page in SamplePage.tour.dropFirst() { _ = try await window.openTab(page.url, isActive: false) }
            window.setTopBar { ShellBar(window: window, sections: sections) }
            self.window = window
        }
        .onDisappear { window?.close() }
    }
}

private struct ShellBar: View {
    let window: CefChromeWindow
    let sections: [String]

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 72)
            ForEach(Array(window.tabs.prefix(sections.count).enumerated()), id: \.element.id) { offset, tab in
                Button(sections[offset]) { Task { try? await tab.select() } }
                    .buttonStyle(.borderless)
                    .fontWeight(tab.isActive ? .semibold : .regular)
                    .foregroundStyle(tab.isActive ? .primary : .secondary)
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
