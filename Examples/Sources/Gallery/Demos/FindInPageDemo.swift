import CefSwiftUI
import SwiftUI

/// Every browser has a `findSession`, an observable model for a find bar
/// of the app's own: setting `text` searches as the user types,
/// `matchCount` and `activeMatch` follow Chromium's results, and `next()`,
/// `previous()` and `end()` move between matches and clear them.
struct FindInPageDemo: Demo {
    let title = "Find in Page"
    let summary = "Searching the page from the window's search field through the browser's CefFindSession."
    let symbol = "text.magnifyingglass"
    let category = DemoCategory.page

    func makeView() -> some View { FindInPageView() }
}

private struct FindInPageView: View {
    @State private var browser = CefBrowser(url: SamplePage.article.url)

    var body: some View {
        FindBar(session: browser.findSession) {
            CefWebView(browser)
        }
        .readyWhenLoaded(browser)
        .onDisappear { browser.close(force: true) }
    }
}

private struct FindBar<Content: View>: View {
    @Bindable var session: CefFindSession
    @ViewBuilder var content: Content

    var body: some View {
        content
            .searchable(text: $session.text, placement: .toolbar, prompt: "Find in Page")
            .onSubmit(of: .search) { session.next() }
            .toolbar {
                if !session.text.isEmpty {
                    Text(session.matchCount == 0 ? "Not found" : "\(session.activeMatch) of \(session.matchCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ControlGroup {
                        Button("Previous", systemImage: "chevron.up", action: session.previous)
                        Button("Next", systemImage: "chevron.down", action: session.next)
                    }
                    .disabled(session.matchCount == 0)
                }
            }
    }
}
