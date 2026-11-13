import CefSwiftUI
import SwiftUI

/// `CefBrowser.Configuration.contextMenu` shapes the menu without a
/// delegate: it hides Chromium's commands, adds items of the app's own that
/// appear depending on what was clicked, and can add Inspect Element.
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
        configuration.contextMenu.hiddenCommands = [.viewSource, .print]
        configuration.contextMenu.showsInspectElement = true
        configuration.contextMenu.items = [
            CefContextMenuItem("Look Up in Gallery", isVisible: { !$0.selectedText.isEmpty }) { [weak self] _, target in
                self?.lastAction = "Looked up “\(target.selectedText)”"
            },
            CefContextMenuItem("Copy Link as Markdown", isVisible: { $0.linkURL != nil }) { [weak self] browser, target in
                let markdown = "[\(browser.title)](\(target.linkURL?.absoluteString ?? ""))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                self?.lastAction = "Copied \(markdown)"
            },
        ]
        return CefBrowser(url: Self.page.url, configuration: configuration)
    }

    static let page = SamplePage("context-menu.html", title: "Context Menu", body: """
        <h1>Context Menu</h1>
        <p>Select a few words of this sentence and right-click them.</p>
        <p>Or right-click <a href="https://www.swift.org">this link to swift.org</a>.</p>
        <p class=muted>View Page Source and Print are gone from the menu; Inspect is added.</p>
        """)
}
