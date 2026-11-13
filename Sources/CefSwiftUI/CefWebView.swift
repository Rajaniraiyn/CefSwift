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
    /// A swipe indicator of the app's own, set by
    /// ``navigationGestureIndicator(_:)``.
    var gestureIndicator: ((Double) -> AnyView)?

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
            Host(browser: browser, ownsBrowser: false, gestureIndicator: gestureIndicator)
        case .url(let url, let configuration):
            OwnedHost(url: url, configuration: configuration, gestureIndicator: gestureIndicator)
        }
    }

    /// Keeps the view-owned browser alive across view updates.
    private struct OwnedHost: View {
        let url: URL
        let gestureIndicator: ((Double) -> AnyView)?
        // SwiftUI keeps the first browser and discards the ones later
        // initializers make; a browser does nothing in Chromium until hosted.
        @State private var browser: CefBrowser

        init(url: URL, configuration: CefBrowser.Configuration, gestureIndicator: ((Double) -> AnyView)?) {
            self.url = url
            self.gestureIndicator = gestureIndicator
            _browser = State(initialValue: CefBrowser(url: url, configuration: configuration))
        }

        var body: some View {
            Host(browser: browser, ownsBrowser: true, gestureIndicator: gestureIndicator)
                .onChange(of: url) { _, newURL in browser.load(newURL) }
        }
    }

    private struct Host: View {
        let browser: CefBrowser
        let ownsBrowser: Bool
        let gestureIndicator: ((Double) -> AnyView)?

        var body: some View {
            let showsBuiltIn = gestureIndicator == nil
            Group {
                switch browser.configuration.rendering {
                case .windowed:
                    BrowserRepresentable<CefWindowedBrowserView>(browser: browser, ownsBrowser: ownsBrowser, showsBuiltInIndicator: showsBuiltIn)
                case .offscreen:
                    BrowserRepresentable<CefOffscreenBrowserView>(browser: browser, ownsBrowser: ownsBrowser, showsBuiltInIndicator: showsBuiltIn)
                }
            }
            .overlay {
                if let gestureIndicator, browser.configuration.allowsBackForwardNavigationGestures {
                    GestureProgressReader(browser: browser, content: gestureIndicator)
                }
            }
        }
    }
}

/// The AppKit views `CefWebView` hosts a browser in, one per rendering.
@MainActor
protocol CefBrowserHostView: NSView {
    init(browser: CefBrowser)
    var browser: CefBrowser? { get set }
    var showsBuiltInGestureIndicator: Bool { get set }
    var closesBrowserOnTeardown: Bool { get set }
    func tearDown()
}

extension CefWindowedBrowserView: CefBrowserHostView {}
extension CefOffscreenBrowserView: CefBrowserHostView {}

private struct BrowserRepresentable<HostView: CefBrowserHostView>: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool
    let showsBuiltInIndicator: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView(browser: browser)
        view.closesBrowserOnTeardown = ownsBrowser
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.showsBuiltInGestureIndicator = showsBuiltInIndicator
        view.browser = browser
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tearDown()
    }
}
