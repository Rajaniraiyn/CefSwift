import CefChromium
import CefSwiftUI
import SwiftUI

/// With CefChromium, `profile.extensions` is Chromium's own list of the
/// profile's extensions: `installed` stays current as extensions are added
/// from the Chrome Web Store, loaded, turned off or removed, here or in
/// `chrome://extensions`. "Load Sample" writes a two-file extension, which
/// colours every page's background, to a temporary folder and loads it
/// unpacked, as Chrome's developer mode does.
struct ExtensionsDemo: Demo {
    let title = "Extensions"
    let summary = "The profile's extensions as Chromium keeps them: turn them on and off, remove them, or load a sample one unpacked."
    let symbol = "puzzlepiece.extension"
    let category = DemoCategory.chromiumData

    func makeView() -> some View { ExtensionsView() }
}

private struct ExtensionsView: View {
    private let extensions = CefProfile.default.extensions
    @State private var error: String?
    @State private var page: CefWindow?

    var body: some View {
        List(extensions.installed) { item in
            HStack(spacing: 10) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "puzzlepiece.extension").resizable()
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text("\(item.version) · \(item.permissionWarnings.first ?? "No special permissions")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(item.name, isOn: Binding(
                    get: { item.isEnabled },
                    set: { isOn in run { try await extensions.setEnabled(isOn, for: item.id) } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .contextMenu {
                if item.isUserModifiable {
                    Button("Remove", role: .destructive) { run { try await extensions.uninstall(item.id) } }
                }
            }
        }
        .overlay {
            if extensions.installed.isEmpty {
                ContentUnavailableView(
                    "No Extensions", systemImage: "puzzlepiece.extension",
                    description: Text(error ?? "Load the sample, or add one from the Chrome Web Store."))
            }
        }
        .toolbar {
            Button("Load Sample", systemImage: "plus") { run(loadSample) }
            Button("Try It", systemImage: "macwindow") { showPage() }
            Button("Chrome Web Store", systemImage: "bag") {
                showPage(URL(string: "https://chromewebstore.google.com/category/extensions")!)
            }
        }
        .reportReady { _ = try await extensions.refresh() }
        .onDisappear { page?.close() }
    }

    /// A page in a Chrome-style window, where extensions run.
    private func showPage(_ url: URL = SamplePage.tour[0].url) {
        page?.close()
        let window = CefWindow(browser: CefBrowser(url: url))
        window.show()
        page = window
    }

    private func loadSample() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GallerySampleExtension")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
            {"manifest_version": 3, "name": "Gallery Sample", "version": "1.0",
             "description": "Tints every page, to show a content script running.",
             "content_scripts": [{"matches": ["<all_urls>"], "js": ["tint.js"]}]}
            """.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.style.background = '#e8f0ff';".utf8)
            .write(to: directory.appendingPathComponent("tint.js"))
        // Chromium loads unpacked extensions in developer mode only.
        try await extensions.setDeveloperModeEnabled(true)
        try await extensions.loadUnpacked(at: directory)
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await body()
                error = nil
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
