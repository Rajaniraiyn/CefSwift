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
            // Before Chromium starts, as in Xcode's SwiftUI previews, where
            // it never does: a placeholder, replaced by the page once it runs.
            if CefRuntime.shared.state == .notStarted {
                Placeholder(url: browser.url)
            } else {
                switch browser.configuration.rendering {
                case .windowed:
                    BrowserRepresentable<CefWindowedBrowserView>(browser: browser, ownsBrowser: ownsBrowser)
                case .offscreen:
                    BrowserRepresentable<CefOffscreenBrowserView>(browser: browser, ownsBrowser: ownsBrowser)
                }
            }
        }
    }

    private struct Placeholder: View {
        let url: URL?

        var body: some View {
            ContentUnavailableView {
                Label(url?.host() ?? "Web content", systemImage: "globe")
            } description: {
                Text("The page shows when Chromium runs, in the app.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
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
    func apply(_ environment: EnvironmentValues)
}

extension CefWindowedBrowserView: CefBrowserHostView {
    func apply(_ environment: EnvironmentValues) {}
}

extension CefOffscreenBrowserView: CefBrowserHostView {
    func apply(_ environment: EnvironmentValues) {
        resizePolicy = environment.offscreenResizePolicy
        framePlacement = environment.offscreenFramePlacement
        pageSize = environment.offscreenPageSize
    }
}

private struct BrowserRepresentable<HostView: CefBrowserHostView>: NSViewRepresentable {
    let browser: CefBrowser
    let ownsBrowser: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView(browser: browser)
        view.closesBrowserOnTeardown = ownsBrowser
        // A page moving to another CefWebView, as in a matched-geometry
        // transition, leaves its last frame here while this view animates
        // out, rather than a blank view.
        (view as? CefOffscreenBrowserView)?.keepsLastFrameWhenMoved = true
        view.apply(context.environment)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.apply(context.environment)
        view.browser = browser
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - Offscreen geometry

extension EnvironmentValues {
    @Entry var offscreenResizePolicy: CefOffscreenBrowserView.ResizePolicy = .live
    @Entry var offscreenFramePlacement: CefOffscreenBrowserView.FramePlacement = .stretch
    @Entry var offscreenPageSize: CGSize? = nil
}

extension View {
    /// When offscreen pages in this view lay out again while their
    /// `CefWebView`'s size changes, as it does on every display refresh of
    /// a size animation; see ``CefOffscreenBrowserView/resizePolicy``.
    /// Windowed pages always lay out live.
    public func offscreenResizePolicy(_ policy: CefOffscreenBrowserView.ResizePolicy) -> some View {
        environment(\.offscreenResizePolicy, policy)
    }

    /// Where offscreen pages in this view draw a frame whose size differs
    /// from their `CefWebView`'s; see ``CefOffscreenBrowserView/framePlacement``.
    public func offscreenFramePlacement(_ placement: CefOffscreenBrowserView.FramePlacement) -> some View {
        environment(\.offscreenFramePlacement, placement)
    }

    /// Lays offscreen pages in this view out at `size`, in points, shown
    /// in their `CefWebView` as ``offscreenFramePlacement(_:)`` places
    /// them, with input mapped back to the page: thumbnails and live
    /// previews. `nil` follows the view's size. See
    /// ``CefOffscreenBrowserView/pageSize``.
    public func offscreenPageSize(_ size: CGSize?) -> some View {
        environment(\.offscreenPageSize, size)
    }
}
