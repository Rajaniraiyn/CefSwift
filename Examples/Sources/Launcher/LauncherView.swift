import CefKit
import CefSwiftUI
import SwiftUI

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
            // Open (or focus) a dedicated SwiftUI window for this demo.
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
