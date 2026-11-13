import AppKit
import CefKit
import SwiftUI

extension CefWebView {
    /// Replaces the built-in swipe indicator with a view of your own, laid
    /// over the page. `content` receives
    /// ``CefBrowser/navigationGestureProgress``: 0 at rest, toward -1 while
    /// swiping back and toward 1 while swiping forward; at ±1 and beyond,
    /// releasing navigates.
    ///
    /// ```swift
    /// CefWebView(browser)
    ///     .navigationGestureIndicator { progress in
    ///         Image(systemName: progress < 0 ? "arrow.backward.circle.fill" : "arrow.forward.circle.fill")
    ///             .font(.largeTitle)
    ///             .frame(maxWidth: .infinity, alignment: progress < 0 ? .leading : .trailing)
    ///             .opacity(min(1, abs(progress)))
    ///     }
    /// ```
    public func navigationGestureIndicator(
        @ViewBuilder _ content: @escaping (Double) -> some View
    ) -> CefWebView {
        var copy = self
        copy.gestureIndicator = { AnyView(content($0)) }
        return copy
    }
}

extension CefBrowserWindow {
    /// Replaces the built-in swipe indicator with a SwiftUI view, laid over
    /// the page. `content` receives ``CefBrowser/navigationGestureProgress``
    /// and is redrawn as it changes; it is shown at rest too, with a
    /// progress of 0, so draw nothing then.
    public func setNavigationGestureIndicator(@ViewBuilder _ content: @escaping (Double) -> some View) {
        let hosting = NSHostingView(rootView: GestureProgressReader(browser: browser, content: { AnyView(content($0)) }))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        navigationGestureIndicatorView = PassthroughHostingContainer(hosting)
    }
}

/// Reads the browser's swipe progress in `body`, so SwiftUI redraws the
/// indicator as it changes.
struct GestureProgressReader: View {
    let browser: CefBrowser
    let content: (Double) -> AnyView

    var body: some View {
        content(browser.navigationGestureProgress)
            .allowsHitTesting(false)
    }
}

/// Holds a hosting view and lets every event through to the page.
final class PassthroughHostingContainer: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
