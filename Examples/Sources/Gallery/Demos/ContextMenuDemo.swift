import CefSwiftUI
import SwiftUI

/// `CefBrowser.Configuration.contextMenu` shapes the menu without a
/// delegate: `customize` receives the menu Chromium built, as a value, and
/// what was clicked; it removes commands by name and adds items of the
/// app's own.
struct ContextMenuDemo: Demo {
    let title = "Context Menu"
    let summary = "A context menu without View Source or Print, with items of the app's own for selected text and links."
    let symbol = "contextualmenu.and.cursorarrow"
    let category = DemoCategory.page

    func makeView() -> some View { ContextMenuView() }
}

private struct ContextMenuView: View {
    @State private var model = ContextMenuModel()

    var body: some View {
        VStack(spacing: 0) {
            CefWebView(model.browser)
            Divider()
            Label(model.lastAction, systemImage: "contextualmenu.and.cursorarrow")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .readyWhenLoaded(model.browser)
        .onDisappear { model.browser.close(force: true) }
    }
}

@MainActor
@Observable
private final class ContextMenuModel {
    var lastAction = "Right-click the page, a link or some selected text."
    @ObservationIgnored lazy var browser = makeBrowser()

    private func makeBrowser() -> CefBrowser {
        var configuration = CefBrowser.Configuration()
        configuration.contextMenu.showsInspectElement = true
        configuration.contextMenu.customize { [weak self] menu, target in
            menu.remove(.viewSource, .print)
            var items: [CefContextMenu.Item] = []
            if !target.selectedText.isEmpty {
                items.append(CefContextMenu.Item("Look Up in Gallery") { _, target in
                    self?.lastAction = "Looked up “\(target.selectedText)”"
                })
            }
            if let link = target.linkURL {
                items.append(CefContextMenu.Item("Copy Link as Markdown") { browser, _ in
                    let markdown = "[\(browser.title)](\(link.absoluteString))"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    self?.lastAction = "Copied \(markdown)"
                })
            }
            menu.appendSection(items)
        }
        return CefBrowser(url: Self.page.url, configuration: configuration)
    }

    static let page = SamplePage("context-menu.html", title: "Context Menu", body: """
        <h1>Context Menu</h1>
        <p>Select a few words of this sentence and right-click them.</p>
        <p>Or right-click <a href="https://www.swift.org">this link to swift.org</a>.</p>
        <p class=muted>View Page Source and Print are gone from the menu; Inspect is added.</p>
        """)
}
