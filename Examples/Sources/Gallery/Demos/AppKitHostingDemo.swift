// This file uses CefKit alone: an app with AppKit views hosts a page in
// CefKit's NSViews, and SwiftUI reaches them through NSViewRepresentable.
import CefKit
import SwiftUI

/// `CefWindowedPageView` and `CefOffscreenPageView` are the AppKit
/// views every CefSwift host is built on. A view never closes its page:
/// the owner does, here when the demo goes away.
struct AppKitHostingDemo: Demo {
    let title = "AppKit Hosting"
    let summary = "A CefWindowedPageView, CefKit's AppKit view, wrapped in an NSViewRepresentable without CefSwiftUI."
    let symbol = "macwindow"
    let category = DemoCategory.webViews

    func makeView() -> some View { AppKitHostingView() }
}

private struct AppKitHostingView: View {
    @ViewState private var page = CefPage(url: SamplePage.tour[0].url)

    var body: some View {
        WindowedPageView(page: page)
            .readyWhenLoaded(page)
            .onDisappear { page.close(force: true) }
    }
}

/// Shows `page` in a `CefWindowedPageView`. Assigning another
/// page to the view's `page` shows that one instead.
private struct WindowedPageView: NSViewRepresentable {
    let page: CefPage

    func makeNSView(context: Context) -> CefWindowedPageView {
        CefWindowedPageView(page: page)
    }

    func updateNSView(_ view: CefWindowedPageView, context: Context) {
        if view.page !== page { view.page = page }
    }
}
