import CefChromium
import CefSwiftUI
import SwiftUI

/// With CefChromium, `profile.autocomplete.results(for:)` streams what
/// Chrome's address bar would suggest for some typed text, ranked, from
/// history, bookmarks, open tabs and search, as Chromium's providers
/// answer. Query on every keystroke: a newer query stops the one still
/// running, and `.task(id:)` ends the stream of the text it replaces.
/// Experimental, as it uses Chromium's `chrome://omnibox` debugging page.
struct SuggestionsDemo: Demo {
    let title = "Address Suggestions"
    let summary = "Chromium's ranked address-bar suggestions for what you type, each with its kind and inline completion."
    let symbol = "text.cursor"
    let category = DemoCategory.chromiumData

    func makeView() -> some View { SuggestionsView() }
}

private struct SuggestionsView: View {
    private let autocomplete = CefProfile.default.autocomplete
    @State private var text = "gallery"
    @State private var suggestions: [CefAutocomplete.Suggestion] = []
    @Environment(\.demoReadiness) private var readiness

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type an address or search", text: $text)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(suggestions) { suggestion in
                HStack {
                    Image(systemName: suggestion.isSearch ? "magnifyingglass" : suggestion.isBookmarked ? "bookmark" : "globe")
                    VStack(alignment: .leading) {
                        Text(suggestion.text) + Text(suggestion.inlineCompletion).foregroundStyle(.tint)
                        if !suggestion.detail.isEmpty {
                            Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(String(describing: suggestion.kind)) · \(suggestion.relevance)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: text) {
            do {
                for try await result in autocomplete.results(for: text) {
                    suggestions = result.suggestions
                    if result.isComplete { readiness?.ready() }
                }
            } catch {
                readiness?.fail("\(error)")
            }
        }
    }
}
