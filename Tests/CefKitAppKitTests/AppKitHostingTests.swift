import AppKit
import CefKit
import Testing

/// The host views through CefKit's public API alone: an AppKit app hosts a
/// page without importing SwiftUI or CefSwiftUI.
@MainActor
struct AppKitHostingTests {
    @Test func windowedViewShowsItsPage() {
        let page = CefPage(url: URL(string: "about:blank")!)
        let view = CefWindowedPageView(page: page)
        #expect(view.page === page)

        let other = CefPage(url: URL(string: "about:blank")!)
        view.page = other
        #expect(view.page === other)
        view.page = nil
        #expect(view.page == nil)
    }

    @Test func offscreenViewShowsItsPage() {
        var configuration = CefPage.Configuration()
        configuration.rendering = .offscreen
        let page = CefPage(url: URL(string: "about:blank")!, configuration: configuration)
        let view = CefOffscreenPageView(page: page)
        #expect(view.page === page)
        #expect(view.isFlipped)

        // Not in a window, so Chromium is never asked to create the page.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        container.addSubview(view)
        #expect(view.window == nil)
        view.page = nil
        #expect(view.page == nil)
    }
}
