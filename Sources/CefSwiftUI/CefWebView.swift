import AppKit
import CefKit
import SwiftUI

/// A view that displays a ``CefBrowser``.
///
/// ```swift
/// // Self-contained: the view owns its browser.
/// CefWebView(url: URL(string: "https://example.com")!)
///
/// // Model-driven: keep the browser, bind UI to its state.
/// @State private var browser = CefBrowser(url: home)
///
/// CefWebView(browser)
///     .navigationTitle(browser.title)
/// ```
///
/// The browser's ``CefBrowser/Configuration/rendering`` picks how it draws:
/// `.windowed` (the default) embeds Chromium's own native view; `.offscreen`
/// composites the page in a layer so SwiftUI content can overlap it.
///
/// A view created with ``init(_:)`` never closes the browser you gave it —
/// it can leave the hierarchy and come back, or move to another view. Call
/// ``CefBrowser/close(force:)`` when you are done with it. A view created
/// with ``init(url:configuration:)`` closes its browser when it goes away.
public struct CefWebView: View {
    private let source: Source

    private enum Source {
        case browser(CefBrowser)
        case url(URL, CefBrowser.Configuration)
    }

    /// Shows `browser`.
    public init(_ browser: CefBrowser) {
        source = .browser(browser)
    }

    /// Shows `url` in a browser owned by the view.
    public init(url: URL, configuration: CefBrowser.Configuration = .init()) {
        source = .url(url, configuration)
    }

    public var body: some View {
        switch source {
        case .browser(let browser):
            Host(browser: browser, ownsBrowser: false)
        case .url(let url, let configuration):
            OwnedHost(url: url, configuration: configuration)
        }
    }

    /// Keeps the view-owned browser alive across view updates.
    private struct OwnedHost: View {
        let url: URL
        // SwiftUI keeps the first browser and discards the ones later
        // initializers make; a browser does nothing in Chromium until hosted.
        @State private var browser: CefBrowser

        init(url: URL, configuration: CefBrowser.Configuration) {
            self.url = url
            _browser = State(initialValue: CefBrowser(url: url, configuration: configuration))
        }

        var body: some View {
            Host(browser: browser, ownsBrowser: true)
                .onChange(of: url) { _, newURL in browser.load(newURL) }
        }
    }

    private struct Host: View {
        let browser: CefBrowser
        let ownsBrowser: Bool

        var body: some View {
            switch browser.configuration.rendering {
            case .windowed:
                BrowserRepresentable<CefWindowedBrowserView>(browser: browser, ownsBrowser: ownsBrowser)
            case .offscreen:
                BrowserRepresentable<CefOffscreenBrowserView>(browser: browser, ownsBrowser: ownsBrowser)
            }
        }
    }
}

/// The AppKit views `CefWebView` hosts a browser in, one per rendering.
@MainActor
protocol CefBrowserHostView: NSView {
    init(browser: CefBrowser)
    var browser: CefBrowser? { get set }
    var closesBrowserOnTeardown: Bool { get set }
    func tearDown()
}

extension CefWindowedBrowserView: CefBrowserHostView {}
extension CefOffscreenBrowserView: CefBrowserHostView {}

private struct BrowserRepresentable<HostView: CefBrowserHostView>: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView(browser: browser)
        view.closesBrowserOnTeardown = ownsBrowser
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.browser = browser
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tearDown()
    }
}
