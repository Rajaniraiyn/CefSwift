import CefChromium
import CefSwiftUI
import SwiftUI

/// With CefChromium, `profile.bookmarks` is Chromium's bookmark store,
/// the one Chrome's bookmark pages edit: a tree of folders, with
/// `add(_:title:)`, `remove(_:)` and a `changes` stream that also reports
/// edits made in Chromium's own interface.
struct BookmarksDemo: Demo {
    let title = "Bookmarks"
    let summary = "The profile's bookmarks as Chromium keeps them, as an outline that follows every change."
    let symbol = "bookmark"
    let category = DemoCategory.chromiumData

    func makeView() -> some View { BookmarksView() }
}

private struct BookmarksView: View {
    private let bookmarks = CefProfile.default.bookmarks
    @State private var roots: [CefBookmark] = []
    @State private var error: String?

    var body: some View {
        List {
            OutlineGroup(roots, children: \.children) { bookmark in
                Label(bookmark.title.isEmpty ? (bookmark.url?.absoluteString ?? "Untitled") : bookmark.title,
                      systemImage: bookmark.isFolder ? "folder" : "bookmark")
                    .contextMenu {
                        if bookmark.isEditable {
                            Button("Delete", role: .destructive) { Task { try? await bookmarks.remove(bookmark.id) } }
                        }
                    }
            }
        }
        .overlay { if let error { Text(error).foregroundStyle(.secondary) } }
        .toolbar {
            Button("Bookmark a Sample Page", systemImage: "bookmark.fill") {
                let page = SamplePage.tour.randomElement()!
                Task { try? await bookmarks.add(page.url, title: "Gallery \(page.path)") }
            }
        }
        .reportReady {
            try await reload()
            // Each change, made here or in Chromium's interface, arrives as a signal to read again.
            Task {
                for await _ in bookmarks.changes { try? await reload() }
            }
        }
    }

    private func reload() async throws {
        do {
            roots = try await bookmarks.tree()
            error = nil
        } catch {
            self.error = "\(error)"
            throw error
        }
    }
}
