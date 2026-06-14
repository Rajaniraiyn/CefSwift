import AppKit
import CefKit
import CefSwiftUI
import SwiftUI

// MARK: - Launcher catalog view

/// The launcher catalog: a clean list of demos, each with a title, one-line
/// description, and a Launch affordance.
struct LauncherView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(LauncherChromeController.self) private var chrome
    @State private var selection: LauncherDemo.ID?

    var body: some View {
        NavigationSplitView {
            List(LauncherDemo.catalog, selection: $selection) { demo in
                LauncherRow(demo: demo) { launch(demo) }
                    .tag(demo.id)
            }
            .navigationTitle("Demos")
            .frame(minWidth: 280)
        } detail: {
            DetailPane(
                demo: LauncherDemo.catalog.first { $0.id == selection },
                launch: { demo in launch(demo) })
        }
    }

    private func launch(_ demo: LauncherDemo) {
        switch demo.kind {
        case .chromeRuntime(let url):
            chrome.open(url: url)
        default:
            openWindow(id: "demo", value: demo.id)
        }
    }
}

private struct LauncherRow: View {
    let demo: LauncherDemo
    let launch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: demo.symbol)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(demo.title).font(.headline)
                Text(demo.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Launch", action: launch)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct DetailPane: View {
    let demo: LauncherDemo?
    let launch: (LauncherDemo) -> Void

    var body: some View {
        if let demo {
            VStack(spacing: 18) {
                Image(systemName: demo.symbol)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text(demo.title).font(.largeTitle.bold())
                Text(demo.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    launch(demo)
                } label: {
                    Label("Launch", systemImage: "play.fill").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "CefSwift Launcher",
                systemImage: "square.grid.2x2",
                description: Text("Pick a demo on the left, then Launch it. Each opens its own window — open them one after another to compare the hosting modes."))
        }
    }
}

// MARK: - Demo window

/// Hosts one demo: builds the right web view for the demo's hosting mode and
/// wires the relevant delegate hooks (window-open, downloads, context menu).
struct DemoWindow: View {
    let demo: LauncherDemo
    @State private var model: CefWebViewModel
    @State private var log: [String] = []

    init(demo: LauncherDemo) {
        self.demo = demo
        _model = State(initialValue: Self.makeModel(for: demo))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if !log.isEmpty {
                Divider()
                StatusLog(lines: log)
            }
        }
        .onAppear { configureHooks() }
    }

    @ViewBuilder private var content: some View {
        switch demo.kind {
        case .windowedAlloy, .jsBridge, .dialogsAndPermissions, .downloads:
            CefWebView(model: model)
        case .osrMetal, .incognitoProfile, .persistentProfile, .popups:
            CefMetalWebView(model: model)
        case .chromeRuntime:
            // Handled by LauncherChromeController; never built here.
            ContentUnavailableView("Opens its own window", systemImage: "macwindow")
        }
    }

    private static func makeModel(for demo: LauncherDemo) -> CefWebViewModel {
        var options = CefBrowserOptions()
        let url: URL?
        switch demo.kind {
        case .windowedAlloy(let u):
            options.runtimeStyle = .alloy
            url = u
        case .osrMetal(let u):
            url = u
        case .popups:
            url = LauncherDemoPage.url("popups")
        case .incognitoProfile(let u):
            options.profile = .incognito()
            url = u
        case .persistentProfile(let u, let name):
            options.profile = .persistent(name: name)
            url = u
        case .jsBridge:
            options.runtimeStyle = .alloy
            url = LauncherDemoPage.url("bridge")
        case .dialogsAndPermissions:
            options.runtimeStyle = .alloy
            url = LauncherDemoPage.url("dialogs")
        case .downloads:
            options.runtimeStyle = .alloy
            url = LauncherDemoPage.url("downloads")
        case .chromeRuntime:
            url = nil
        }
        return CefWebViewModel(url: url, options: options)
    }

    private func configureHooks() {
        // Window-open: demonstrate the disposition handler. For these embedded
        // demos we load in the current view (OSR-safe) and record the intent.
        model.onWindowOpen = { request in
            let where_ = request.disposition.prefersForeground ? "foreground" : "background"
            append("window-open: \(request.disposition) (\(where_)) → \(request.targetURL?.absoluteString ?? "—")")
            return .openInCurrentBrowser
        }
        // Downloads: record + save to ~/Downloads (the default destination).
        model.onDownloadProgress = { dl in
            if dl.isComplete { append("download complete: \(dl.fullPath?.path ?? "(unknown)")") }
        }
        model.onDownloadDecision = { _, name in
            append("download started: \(name)")
            return .allow(destination: nil)
        }
        model.onConsoleMessage = { append("console: \($0)") }

        // Context-menu customization: add "Open DevTools" always, and
        // "Open Link Here" when right-clicking a link.
        let openDevToolsCmd = CefMenuModel.userCommandIDFirst
        let openLinkCmd = CefMenuModel.userCommandIDFirst + 1
        model.onConfigureContextMenu = { menu, params in
            menu.addSeparator()
            if params.linkURL != nil {
                menu.addItem(commandID: openLinkCmd, title: "Open Link in This View")
            }
            menu.addItem(commandID: openDevToolsCmd, title: "Open DevTools")
        }
        model.onContextMenuCommand = { commandID, params in
            switch commandID {
            case openDevToolsCmd:
                model.browser?.showDevTools()
                append("context menu: Open DevTools")
                return true
            case openLinkCmd:
                if let link = params.linkURL {
                    let req = CefWindowOpenRequest(
                        targetURL: link, disposition: .currentTab, userGesture: true,
                        isSourceOffscreen: model.browser?.isOffscreen ?? false)
                    if case .openInCurrentBrowser = CefWindowOpenPolicy.resolve(.openInCurrentBrowser, for: req) {
                        model.load(link)
                    }
                    append("context menu: Open Link → \(link.absoluteString)")
                }
                return true
            default:
                return false
            }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 80 { log.removeFirst() }
    }
}

private struct StatusLog: View {
    let lines: [String]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .frame(height: 110)
        .background(.quaternary.opacity(0.4))
    }
}
