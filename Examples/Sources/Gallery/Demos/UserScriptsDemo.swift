import CefSwiftUI
import SwiftUI

/// User scripts run in every document a page loads, before the page's
/// own scripts; `CefUserScript.styleSheet(_:matching:)` adds CSS. They are
/// part of the page's configuration, fixed at creation, so turning one
/// on or off here makes a new page.
struct UserScriptsDemo: Demo {
    let title = "User Scripts and Style Sheets"
    let summary = "A script that runs before the page's own and a style sheet laid over it, chosen when the browser is created."
    let symbol = "text.badge.plus"
    let category = DemoCategory.javaScript

    func makeView() -> some View { UserScriptsView() }
}

private struct UserScriptsView: View {
    @ViewState private var addsBanner = true
    @ViewState private var restyles = true
    @ViewState private var page = UserScriptsView.makePage(addsBanner: true, restyles: true)

    var body: some View {
        CefWebView(page)
            .id(ObjectIdentifier(page))
            .toolbar {
                Toggle("Banner Script", systemImage: "rectangle.topthird.inset.filled", isOn: $addsBanner)
                Toggle("Style Sheet", systemImage: "paintbrush", isOn: $restyles)
            }
            .onChange(of: [addsBanner, restyles]) {
                page.close(force: true)
                page = Self.makePage(addsBanner: addsBanner, restyles: restyles)
            }
            .readyWhenLoaded(page)
            .onDisappear { page.close(force: true) }
    }

    private static func makePage(addsBanner: Bool, restyles: Bool) -> CefPage {
        var configuration = CefPage.Configuration()
        if addsBanner {
            // At document start there is no <body> yet: wait for the parsed document.
            configuration.userScripts.append(CefUserScript(source: """
                const banner = document.createElement('p');
                banner.className = 'card';
                banner.textContent = 'Added by a user script, which also set window.galleryVersion = ' + window.galleryVersion;
                document.body.prepend(banner);
                """, injectionTime: .documentEnd))
            configuration.userScripts.append(CefUserScript(source: "window.galleryVersion = '1.0'"))
        }
        if restyles {
            configuration.userScripts.append(.styleSheet("""
                body { font-family: ui-serif, Georgia, serif; }
                h1, h2 { color: #c0392b; letter-spacing: 0.02em; }
                """, matching: ["gallery://pages/*"]))
        }
        return CefPage(url: SamplePage.article.url, configuration: configuration)
    }
}
