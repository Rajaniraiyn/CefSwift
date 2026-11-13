import CefSwiftUI
import SwiftUI

/// User scripts run in every document a browser loads, before the page's
/// own scripts; `CefUserScript.styleSheet(_:matching:)` adds CSS. They are
/// part of the browser's configuration, fixed at creation, so turning one
/// on or off here makes a new browser.
struct UserScriptsDemo: Demo {
    let title = "User Scripts and Style Sheets"
    let summary = "A script that runs before the page's own and a style sheet laid over it, chosen when the browser is created."
    let symbol = "text.badge.plus"
    let category = DemoCategory.javaScript

    func makeView() -> some View { UserScriptsView() }
}

private struct UserScriptsView: View {
    @State private var addsBanner = true
    @State private var restyles = true
    @State private var browser = UserScriptsView.makeBrowser(addsBanner: true, restyles: true)

    var body: some View {
        CefWebView(browser)
            .id(ObjectIdentifier(browser))
            .toolbar {
                Toggle("Banner Script", systemImage: "rectangle.topthird.inset.filled", isOn: $addsBanner)
                Toggle("Style Sheet", systemImage: "paintbrush", isOn: $restyles)
            }
            .onChange(of: [addsBanner, restyles]) {
                browser.close(force: true)
                browser = Self.makeBrowser(addsBanner: addsBanner, restyles: restyles)
            }
            .readyWhenLoaded(browser)
            .onDisappear { browser.close(force: true) }
    }

    private static func makeBrowser(addsBanner: Bool, restyles: Bool) -> CefBrowser {
        var configuration = CefBrowser.Configuration()
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
                """, matching: "gallery://pages/*"))
        }
        return CefBrowser(url: SamplePage.article.url, configuration: configuration)
    }
}
