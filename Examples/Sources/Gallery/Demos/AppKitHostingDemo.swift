// This file uses CefKit alone: an app with AppKit views hosts a browser in
// CefKit's NSViews, and SwiftUI reaches them through NSViewRepresentable.
import CefKit
import SwiftUI

/// `CefWindowedBrowserView` and `CefOffscreenBrowserView` are the AppKit
/// views every CefSwift host is built on. A view never closes its browser:
/// the owner does, here when the demo goes away.
struct AppKitHostingDemo: Demo {
    let title = "AppKit Hosting"
    let summary = "A CefWindowedBrowserView, CefKit's AppKit view, wrapped in an NSViewRepresentable without CefSwiftUI."
    let symbol = "macwindow"
    let category = DemoCategory.webViews

    func makeView() -> some View { AppKitHostingView() }
}

private struct AppKitHostingView: View {
    @State private var browser = CefBrowser(url: SamplePage.tour[0].url)

    var body: some View {
        WindowedBrowserView(browser: browser)
            .readyWhenLoaded(browser)
            .onDisappear { browser.close(force: true) }
    }
}

/// Shows `browser` in a `CefWindowedBrowserView`. Assigning another
/// browser to the view's `browser` shows that one instead.
private struct WindowedBrowserView: NSViewRepresentable {
    let browser: CefBrowser

    func makeNSView(context: Context) -> CefWindowedBrowserView {
        CefWindowedBrowserView(browser: browser)
    }

    func updateNSView(_ view: CefWindowedBrowserView, context: Context) {
        if view.browser !== browser { view.browser = browser }
    }
}
