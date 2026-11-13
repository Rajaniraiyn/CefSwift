import AppKit
import CefKit
import Testing

/// The host views through CefKit's public API alone: an AppKit app hosts a
/// browser without importing SwiftUI or CefSwiftUI.
@MainActor
struct AppKitHostingTests {
    @Test func windowedViewShowsItsBrowser() {
        let browser = CefBrowser(url: URL(string: "about:blank")!)
        let view = CefWindowedBrowserView(browser: browser)
        #expect(view.browser === browser)

        let other = CefBrowser(url: URL(string: "about:blank")!)
        view.browser = other
        #expect(view.browser === other)
        view.browser = nil
        #expect(view.browser == nil)
    }

    @Test func offscreenViewShowsItsBrowser() {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "about:blank")!, configuration: configuration)
        let view = CefOffscreenBrowserView(browser: browser)
        #expect(view.browser === browser)
        #expect(view.isFlipped)

        // Not in a window, so Chromium is never asked to create the browser.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        container.addSubview(view)
        #expect(view.window == nil)
        view.browser = nil
        #expect(view.browser == nil)
    }
}
