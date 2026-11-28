import CefSwiftUI
import SwiftUI

/// A `CefPage` is an `@Observable` model: views read its title,
/// address, progress and history and update as they change. `load(_:)`
/// returns the navigation it starts, which `waitUntilLoaded(timeout:)`
/// awaits.
struct ObservableStateDemo: Demo {
    let title = "Observable State"
    let summary = "A web view whose toolbar and status bar are bound to the browser's observable state, and a load awaited until it finishes."
    let symbol = "globe"
    let category = DemoCategory.webViews

    func makeView() -> some View { ObservableStateView() }
}

private struct ObservableStateView: View {
    @ViewState private var page = CefPage(url: SamplePage.tour[0].url)
    @ViewState private var lastLoad = "Choose a page from the menu to await its load."

    var body: some View {
        VStack(spacing: 0) {
            CefWebView(page)
            Divider()
            HStack {
                Text(page.url?.absoluteString ?? "–").lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(lastLoad).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: page.goBack)
                    .disabled(!page.canGoBack)
                Button("Forward", systemImage: "chevron.right", action: page.goForward)
                    .disabled(!page.canGoForward)
            }
            ToolbarItem(placement: .principal) {
                Text(page.title.isEmpty ? "Untitled" : page.title).lineLimit(1)
            }
            ToolbarItemGroup {
                if page.isLoading {
                    ProgressView(value: page.estimatedProgress).frame(width: 80)
                    Button("Stop", systemImage: "xmark", action: page.stopLoading)
                } else {
                    Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                }
                Menu("Go To", systemImage: "list.bullet") {
                    ForEach(SamplePage.tour, id: \.path) { sample in
                        Button(sample.path) { Task { await open(sample.url) } }
                    }
                }
            }
        }
        .readyWhenLoaded(page)
        .onDisappear { page.close(force: true) }
    }

    /// Loads `url` and reports how its navigation ended.
    private func open(_ url: URL) async {
        let start = ContinuousClock.now
        do {
            let result = try await page.load(url).waitUntilLoaded(timeout: .seconds(10))
            let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
            lastLoad = "Loaded with status \(result.httpStatus ?? 0) in \(elapsed)"
        } catch {
            lastLoad = "Did not load: \(error)"
        }
    }
}
