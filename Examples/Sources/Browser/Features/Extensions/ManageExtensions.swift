import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Window › Extensions: the profile's extensions, with a switch each, their
/// details, Remove, and Load Unpacked, Update and the Chrome Web Store.
@MainActor
enum ManageExtensionsWindow {
    private static var window: NSWindow?
    private static let selection = ExtensionSelection()

    static func show(controller: BrowserController, selecting id: CefExtension.ID? = nil) {
        if let id { selection.id = id }
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extensions"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: ManageExtensionsView(extensions: CefProfile.default.extensions, selection: selection)
                .environment(controller))
        window.setFrameAutosaveName("Extensions")
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}

@MainActor
@Observable
final class ExtensionSelection {
    var id: CefExtension.ID?
}

private struct ManageExtensionsView: View {
    let extensions: CefExtensions
    @Bindable var selection: ExtensionSelection
    @Environment(BrowserController.self) private var controller
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            List(extensions.installed, selection: $selection.id) { item in
                HStack {
                    ExtensionIcon(image: item.icon, size: 20)
                    VStack(alignment: .leading) {
                        Text(item.name).lineLimit(1)
                        Text(item.version).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(item.name, isOn: Binding(
                        get: { item.isEnabled },
                        set: { isOn in run { try await extensions.setEnabled(isOn, for: item.id) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!item.isUserModifiable)
                }
                .tag(item.id)
            }
            .overlay {
                if extensions.installed.isEmpty {
                    ContentUnavailableView(
                        "No Extensions", systemImage: "puzzlepiece.extension",
                        description: Text("Add extensions from the Chrome Web Store."))
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = selection.id, let item = extensions.installed.first(where: { $0.id == id }) {
                ExtensionDetail(item: item, extensions: extensions)
            } else {
                Text("Select an extension").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Chrome Web Store", systemImage: "bag") {
                    controller.openTab(url: ExtensionLinks.webStore)
                }
                Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                    run { try await extensions.checkForUpdates() }
                }
                Button("Load Unpacked…", systemImage: "folder.badge.plus", action: loadUnpacked)
            }
        }
        .alert("Extensions", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task { _ = try? await extensions.refresh() }
    }

    /// Chrome allows loading an unpacked extension in developer mode only;
    /// choosing a folder here turns it on, as Chrome's button needs.
    private func loadUnpacked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose an extension's folder, the one with its manifest.json."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        run {
            if try await !extensions.isDeveloperModeEnabled() { try await extensions.setDeveloperModeEnabled(true) }
            let loaded = try await extensions.loadUnpacked(at: directory)
            selection.id = loaded.id
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await body() } catch { self.error = "\(error)" }
        }
    }
}

private struct ExtensionDetail: View {
    let item: CefExtension
    let extensions: CefExtensions
    @Environment(BrowserController.self) private var controller

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ExtensionIcon(image: item.icon, size: 40)
                    VStack(alignment: .leading) {
                        Text(item.name).font(.title3)
                        Text("Version \(item.version) · \(source)").foregroundStyle(.secondary)
                    }
                }
                if !item.description.isEmpty { Text(item.description) }
                if item.state != .enabled { LabeledContent("State", value: state) }
            }
            if !item.permissionWarnings.isEmpty {
                Section("Permissions") {
                    ForEach(item.permissionWarnings, id: \.self) { Text($0) }
                }
            }
            if item.siteAccess != nil {
                Section("Site Access") {
                    Picker("Allow this extension to read and change site data", selection: Binding(
                        get: { item.siteAccess ?? .onClick },
                        set: { access in Task { try? await extensions.setSiteAccess(access, for: item.id) } })) {
                        Text("When you click the extension").tag(CefExtension.SiteAccess.onClick)
                        Text("On specific sites").tag(CefExtension.SiteAccess.onSpecificSites)
                        Text("On all sites").tag(CefExtension.SiteAccess.onAllSites)
                    }
                }
            }
            Section {
                Toggle("Allow in Private Tabs", isOn: Binding(
                    get: { item.isAllowedInIncognito },
                    set: { isOn in Task { try? await extensions.setAllowedInIncognito(isOn, for: item.id) } }))
                if !item.replacedPages.isEmpty {
                    LabeledContent("Replaces", value: item.replacedPages.keys.map(\.rawValue).sorted().joined(separator: ", "))
                }
                if let shortcut = item.commands.first(where: \.isAction)?.shortcut, !shortcut.isEmpty {
                    LabeledContent("Shortcut", value: shortcut)
                }
            }
            Section {
                HStack {
                    if let options = item.optionsURL {
                        Button("Options") { controller.openTab(url: options) }
                    }
                    Button("Details in Chromium") { controller.openTab(url: ExtensionLinks.details(item.id)) }
                    if let directory = item.directory, item.installSource == .unpacked {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                        Button("Reload") { Task { try? await extensions.reload(item.id) } }
                    }
                    Spacer()
                    if item.isUserModifiable {
                        Button("Remove…", role: .destructive) {
                            Task { await ExtensionRemoval.confirm(item, in: extensions) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var source: String {
        switch item.installSource {
        case .webStore: "Chrome Web Store"
        case .unpacked: "Unpacked"
        case .external: "Installed by the app"
        case .policy: "Installed by your administrator"
        case .installedByDefault: "Installed by default"
        case .other: "Other"
        }
    }

    private var state: String {
        switch item.state {
        case .enabled: "On"
        case .disabled: "Off"
        case .terminated: "Stopped (crashed)"
        case .blocklisted: "Blocked as harmful"
        }
    }
}
