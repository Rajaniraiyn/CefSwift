import CefChromium
import CefSwiftUI
import SwiftUI

/// Chromium's own tabs, drawn by the app: a `CefChromeWindow` beside the
/// gallery, its tabs listed here from the model (`window.tabs`), every
/// button a command to Chromium. The same model drives the Browser
/// example's tab rail; here it is a plain list, a "tab overview".
struct TabStripDemo: Demo {
    let title = "Chromium's Tabs"
    let summary = "A window of Chromium's own tabs, listed and driven from SwiftUI: select, pin, group, mute and close them; the window can hide Chrome's strip and show the app's bar instead."
    let symbol = "square.on.square"
    let category = DemoCategory.windows

    func makeView() -> some View { TabOverview() }
}

private struct TabOverview: View {
    @State private var window: CefChromeWindow?

    var body: some View {
        List {
            if let window {
                Section {
                    Toggle("Hide Chrome's tab strip and toolbar", isOn: Binding(
                        get: { !window.showsChromeUI }, set: { window.showsChromeUI = !$0 }))
                    Button("New Tab", systemImage: "plus") {
                        Task { try? await window.openTab(SamplePage.tour[window.tabs.count % 3].url) }
                    }
                }
                Section("Tabs") {
                    ForEach(window.tabs) { tab in TabRow(tab: tab) }
                }
                ForEach(window.groups) { group in
                    Section(group.title.isEmpty ? "Group" : group.title) {
                        Text("^[\(group.tabs.count) tab](inflect: true)\(group.isCollapsed ? ", collapsed" : "")")
                        Button("Ungroup") { Task { try? await group.ungroup() } }
                    }
                }
            }
        }
        .reportReady {
            let window = try await CefChromeWindow.open(url: SamplePage.tour[0].url)
            window.setTopBar { AppBar(window: window) }
            self.window = window
            _ = try await window.openTab(SamplePage.tour[1].url)
        }
        .onDisappear { window?.close() }
    }
}

/// One tab, with its commands.
private struct TabRow: View {
    let tab: CefTab

    var body: some View {
        HStack {
            if let favicon = tab.favicon { Image(nsImage: favicon).resizable().frame(width: 16, height: 16) }
            Text(tab.title.isEmpty ? "New Tab" : tab.title).fontWeight(tab.isActive ? .semibold : .regular).lineLimit(1)
            if tab.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
            Spacer()
            Button("Show") { Task { try? await tab.select() } }
            Button(tab.isPinned ? "Unpin" : "Pin") { Task { try? await tab.pin(!tab.isPinned) } }
            Button(tab.group == nil ? "Group" : "Ungroup") {
                Task {
                    if let group = tab.group { try? await group.ungroup() } else { _ = try? await tab.window?.strip.group([tab]) }
                }
            }
            Button(tab.isMuted ? "Unmute" : "Mute") { tab.setMuted(!tab.isMuted) }
            Button("Close", role: .destructive) { tab.close() }
        }
        .buttonStyle(.borderless)
    }
}

/// The app's bar over Chrome's, while Chrome's is hidden: the tabs as a
/// segmented control.
private struct AppBar: View {
    let window: CefChromeWindow

    var body: some View {
        HStack {
            Spacer().frame(width: 80)
            Picker("Tab", selection: Binding(
                get: { window.activeTab?.id },
                set: { id in Task { try? await window.tabs.first { $0.id == id }?.select() } })) {
                ForEach(window.tabs) { tab in Text(tab.title.isEmpty ? "New Tab" : tab.title).tag(Optional(tab.id)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
        }
        .padding(.horizontal)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
