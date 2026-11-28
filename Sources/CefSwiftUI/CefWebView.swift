import AppKit
import CefKit
import SwiftUI

/// A view that displays a ``CefPage``.
///
/// ```swift
/// // Self-contained: the view owns its page.
/// CefWebView(url: URL(string: "https://example.com")!)
///
/// // Model-driven: keep the page, bind UI to its state.
/// @State private var page = CefPage(url: home)
///
/// CefWebView(page)
///     .navigationTitle(page.title)
/// ```
///
/// The page's ``CefPage/Configuration/rendering`` picks how it draws:
/// `.windowed` (the default) embeds Chromium's own native view; `.offscreen`
/// composites the page in a layer so SwiftUI content can overlap it.
///
/// A view created with ``init(_:)`` never closes the page you gave it, so
/// the page can leave the hierarchy and come back, or move to another view. Call
/// ``CefPage/close(force:)`` when you are done with it. A view created
/// with ``init(url:configuration:)`` closes its page when it goes away.
public struct CefWebView: View {
    private let source: Source

    private enum Source {
        case page(CefPage)
        case url(URL, CefPage.Configuration)
    }

    /// Shows `page`.
    public init(_ page: CefPage) {
        source = .page(page)
    }

    /// Shows `url` in a page owned by the view.
    public init(url: URL, configuration: CefPage.Configuration = .init()) {
        source = .url(url, configuration)
    }

    public var body: some View {
        switch source {
        case .page(let page):
            Host(page: page, ownsPage: false)
        case .url(let url, let configuration):
            OwnedHost(url: url, configuration: configuration)
        }
    }

    /// Keeps the view-owned page alive across view updates.
    private struct OwnedHost: View {
        let url: URL
        // SwiftUI keeps the first page and discards the ones later
        // initializers make; a page does nothing in Chromium until hosted.
        @ViewState private var page: CefPage

        init(url: URL, configuration: CefPage.Configuration) {
            self.url = url
            _page = State(initialValue: CefPage(url: url, configuration: configuration))
        }

        var body: some View {
            Host(page: page, ownsPage: true)
                .onChange(of: url) { _, newURL in page.load(newURL) }
        }
    }

    private struct Host: View {
        let page: CefPage
        let ownsPage: Bool

        var body: some View {
            // Before Chromium starts, as in Xcode's SwiftUI previews, where
            // it never does: a placeholder, replaced by the page once it runs.
            if CefRuntime.shared.state == .notStarted {
                Placeholder(url: page.url)
            } else {
                switch page.configuration.rendering {
                case .windowed:
                    PageRepresentable<CefWindowedPageView>(page: page, ownsPage: ownsPage)
                case .offscreen:
                    PageRepresentable<CefOffscreenPageView>(page: page, ownsPage: ownsPage)
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

/// The AppKit views `CefWebView` hosts a page in, one per rendering.
@MainActor
protocol CefPageHostView: NSView {
    init(page: CefPage)
    var page: CefPage? { get set }
    var closesPageOnTeardown: Bool { get set }
    func tearDown()
    func apply(_ environment: EnvironmentValues)
}

extension CefWindowedPageView: CefPageHostView {
    func apply(_ environment: EnvironmentValues) {}
}

extension CefOffscreenPageView: CefPageHostView {
    func apply(_ environment: EnvironmentValues) {
        resizePolicy = environment.offscreenResizePolicy
        framePlacement = environment.offscreenFramePlacement
        pageSize = environment.offscreenPageSize
    }
}

private struct PageRepresentable<HostView: CefPageHostView>: NSViewRepresentable {
    let page: CefPage
    let ownsPage: Bool

    func makeNSView(context: Context) -> HostView {
        let view = HostView(page: page)
        view.closesPageOnTeardown = ownsPage
        // A page moving to another CefWebView, as in a matched-geometry
        // transition, leaves its last frame here while this view animates
        // out, rather than a blank view.
        (view as? CefOffscreenPageView)?.keepsLastFrameWhenMoved = true
        view.apply(context.environment)
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.apply(context.environment)
        view.page = page
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - Offscreen geometry

// Written out rather than with `@Entry`, whose macro plugin comes with
// Xcode, not with the Command Line Tools.
private struct OffscreenResizePolicyKey: EnvironmentKey {
    static let defaultValue: CefOffscreenPageView.ResizePolicy = .live
}

private struct OffscreenFramePlacementKey: EnvironmentKey {
    static let defaultValue: CefOffscreenPageView.FramePlacement = .stretch
}

private struct OffscreenPageSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    var offscreenResizePolicy: CefOffscreenPageView.ResizePolicy {
        get { self[OffscreenResizePolicyKey.self] }
        set { self[OffscreenResizePolicyKey.self] = newValue }
    }
    var offscreenFramePlacement: CefOffscreenPageView.FramePlacement {
        get { self[OffscreenFramePlacementKey.self] }
        set { self[OffscreenFramePlacementKey.self] = newValue }
    }
    var offscreenPageSize: CGSize? {
        get { self[OffscreenPageSizeKey.self] }
        set { self[OffscreenPageSizeKey.self] = newValue }
    }
}

extension View {
    /// When offscreen pages in this view lay out again while their
    /// `CefWebView`'s size changes, as it does on every display refresh of
    /// a size animation; see ``CefOffscreenPageView/resizePolicy``.
    /// Windowed pages always lay out live.
    public func offscreenResizePolicy(_ policy: CefOffscreenPageView.ResizePolicy) -> some View {
        environment(\.offscreenResizePolicy, policy)
    }

    /// Where offscreen pages in this view draw a frame whose size differs
    /// from their `CefWebView`'s; see ``CefOffscreenPageView/framePlacement``.
    public func offscreenFramePlacement(_ placement: CefOffscreenPageView.FramePlacement) -> some View {
        environment(\.offscreenFramePlacement, placement)
    }

    /// Lays offscreen pages in this view out at `size`, in points, shown
    /// in their `CefWebView` as ``offscreenFramePlacement(_:)`` places
    /// them, with input mapped back to the page: thumbnails and live
    /// previews. `nil` follows the view's size. See
    /// ``CefOffscreenPageView/pageSize``.
    public func offscreenPageSize(_ size: CGSize?) -> some View {
        environment(\.offscreenPageSize, size)
    }
}
