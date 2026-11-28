import CefSwiftUI
import SwiftUI

/// A request filter that rewrites the HTML of a page before Chromium parses
/// it: `.rewriteResponse(_:)` with a `CefResponseRewriter`, which sees the
/// response's headers and returns the rewrite for its body. The filter is
/// the page's configuration, fixed at creation, so turning it on or off
/// here makes a new page.
struct ResponseRewritingDemo: Demo {
    let title = "Response Rewriting"
    let summary = "A request filter that rewrites a page's HTML as it arrives: a banner added and the headings retitled, before any script runs."
    let symbol = "doc.text.magnifyingglass"
    let category = DemoCategory.network

    func makeView() -> some View { ResponseRewritingView() }
}

private struct ResponseRewritingView: View {
    @State private var rewrites = true
    @State private var page = ResponseRewritingView.makePage(rewrites: true)

    var body: some View {
        CefWebView(page)
            .id(ObjectIdentifier(page))
            .toolbar {
                Toggle("Rewrite HTML", systemImage: "doc.text.magnifyingglass", isOn: $rewrites)
            }
            .onChange(of: rewrites) {
                page.close(force: true)
                page = Self.makePage(rewrites: rewrites)
            }
            .readyWhenLoaded(page)
            .onDisappear { page.close(force: true) }
    }

    private static func makePage(rewrites: Bool) -> CefPage {
        var configuration = CefPage.Configuration()
        if rewrites {
            configuration.requestFilter = CefRequestFilter(resourceTypes: [.mainFrame]) { _ in
                .rewriteResponse(CefResponseRewriter { response in
                    // Only HTML; anything else passes through untouched.
                    guard response.mimeType == "text/html" else { return nil }
                    return { body in
                        let html = String(decoding: body, as: UTF8.self)
                            .replacingOccurrences(of: "<h1>", with: "<h1>Rewritten: ")
                            .replacingOccurrences(
                                of: "</style>",
                                with: "</style><p class=card>This banner was added to the HTML by a request filter, before Chromium parsed it.</p>")
                        return Data(html.utf8)
                    }
                })
            }
        }
        return CefPage(url: SamplePage.article.localURL, configuration: configuration)
    }
}
