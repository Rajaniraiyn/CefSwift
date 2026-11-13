import CefChromium
import CefSwiftUI
import SwiftUI

/// With CefChromium, `profile.history` is Chromium's browsing history:
/// `search(_:limit:)` finds visits as `chrome://history` does, and
/// `remove(_:)` deletes them. Only Chrome-style browsers record visits, so
/// pages opened in the Chrome-Style Window demo appear here; those in web
/// views do not.
struct HistoryDemo: Demo {
    let title = "History"
    let summary = "The profile's history, searched as you type, with each entry's last visit."
    let symbol = "clock.arrow.circlepath"
    let category = DemoCategory.chromiumData

    func makeView() -> some View { HistoryView() }
}

private struct HistoryView: View {
    private let history = CefProfile.default.history
    @State private var query = ""
    @State private var entries: [CefHistory.Entry] = []
    @Environment(\.demoReadiness) private var readiness

    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title)
                Text("\(entry.url.absoluteString) · \(entry.lastVisitDate.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Remove from History", role: .destructive) {
                    Task {
                        try? await history.remove([entry])
                        await search()
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Pages visited in Chrome-style windows appear here."))
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search History")
        .task(id: query) { await search() }
    }

    private func search() async {
        do {
            entries = try await history.search(query, limit: 50)
            readiness?.ready()
        } catch is CancellationError {
        } catch {
            entries = []
            readiness?.fail("\(error)")
        }
    }
}
