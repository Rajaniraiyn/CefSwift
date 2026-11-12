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
/// The browser's ``CefBrowserOptions/rendering`` picks how it draws:
/// `.windowed` (the default) embeds Chromium's own native view; `.offscreen`
/// composites the page in a layer so SwiftUI content can overlap it.
///
/// A view created with ``init(_:)`` never closes the browser you gave it —
/// it can leave the hierarchy and come back, or move to another view. Call
/// ``CefBrowser/close(force:)`` when you are done with it. A view created
/// with ``init(url:options:)`` closes its browser when it goes away.
public struct CefWebView: View {
    private let source: Source

    private enum Source {
        case browser(CefBrowser)
        case url(URL, CefBrowserOptions)
    }

    /// Shows `browser`.
    public init(_ browser: CefBrowser) {
        source = .browser(browser)
    }

    /// Shows `url` in a browser owned by the view.
    public init(url: URL, options: CefBrowserOptions = .init()) {
        source = .url(url, options)
    }

    public var body: some View {
        switch source {
        case .browser(let browser):
            Host(browser: browser, ownsBrowser: false)
        case .url(let url, let options):
            OwnedHost(url: url, options: options)
        }
    }

    /// Keeps the view-owned browser alive across view updates.
    private struct OwnedHost: View {
        let url: URL
        // SwiftUI keeps the first browser and discards the ones later
        // initializers make; a browser does nothing in Chromium until hosted.
        @State private var browser: CefBrowser

        init(url: URL, options: CefBrowserOptions) {
            self.url = url
            _browser = State(initialValue: CefBrowser(url: url, options: options))
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
            switch browser.options.rendering {
            case .windowed:
                WindowedRepresentable(browser: browser, ownsBrowser: ownsBrowser)
            case .offscreen:
                OffscreenRepresentable(browser: browser, ownsBrowser: ownsBrowser)
            }
        }
    }
}

private struct WindowedRepresentable: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool

    func makeNSView(context: Context) -> CefWindowedBrowserView {
        let view = CefWindowedBrowserView()
        view.closesBrowserOnTeardown = ownsBrowser
        view.browser = browser
        return view
    }

    func updateNSView(_ view: CefWindowedBrowserView, context: Context) {
        view.browser = browser
    }

    static func dismantleNSView(_ view: CefWindowedBrowserView, coordinator: ()) {
        view.tearDown()
    }
}

private struct OffscreenRepresentable: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool

    func makeNSView(context: Context) -> CefOffscreenBrowserView {
        let view = CefOffscreenBrowserView()
        view.closesBrowserOnTeardown = ownsBrowser
        view.browser = browser
        return view
    }

    func updateNSView(_ view: CefOffscreenBrowserView, context: Context) {
        view.browser = browser
    }

    static func dismantleNSView(_ view: CefOffscreenBrowserView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - Windowed host view

/// An `NSView` showing a windowed browser: Chromium's own native view is
/// added as a subview and kept sized to fill it. Chromium handles input,
/// IME and accessibility itself.
///
/// `CefWebView` uses this for `.windowed` browsers; use it directly in
/// AppKit by assigning ``browser``.
@MainActor
public final class CefWindowedBrowserView: NSView {

    /// The browser shown in this view. Assigning a browser that is already
    /// live moves its native view here.
    public var browser: CefBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            if let previous = oldValue?.nativeView, previous.superview === self {
                previous.removeFromSuperview()
            }
            hostBrowserIfPossible()
        }
    }

    /// Whether dismantling the view closes its browser. `CefWebView(url:)`
    /// sets this for the browser it owns.
    var closesBrowserOnTeardown = false
    private var isTornDown = false

    public init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostBrowserIfPossible()
    }

    /// A discarded browser comes back when its view is shown again.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        hostBrowserIfPossible()
    }

    /// Chromium can only create a windowed browser inside a window, so
    /// hosting waits until the view is in one.
    private func hostBrowserIfPossible() {
        guard !isTornDown, window != nil, let browser else { return }
        browser.host(windowedIn: self)
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if closesBrowserOnTeardown {
            browser?.close(force: true)
        }
        browser = nil
    }
}
