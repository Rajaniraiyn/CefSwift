import AppKit
import Foundation

extension CefBrowser {
    /// The page's tooltip: the text of a `title` attribute under the
    /// pointer (``CefBrowser/tooltip``).
    ///
    /// Chromium reports only this text. Tooltips a page draws itself (a
    /// `popover`, an `interestfor` target, CSS) are page content and
    /// already show in the page; tooltips of Chromium's own interface,
    /// such as the toolbar buttons of a `CefWindow`, are Chromium's.
    public struct Tooltip: Sendable, Equatable {
        /// The text, as the page gives it: it can run over several lines.
        public var text: String
        /// Where the pointer was when the tooltip changed, in the host
        /// view's points with a top-left origin (Chromium's view
        /// coordinates). Chromium gives no anchor of its own.
        public var location: CGPoint

        /// Creates a value of your own, for previews and tests.
        public init(text: String, location: CGPoint) {
            self.text = text
            self.location = location
        }
    }

    /// Who shows the page's tooltips.
    public enum TooltipPolicy: Sendable, Equatable {
        /// As macOS shows a view's tooltip: Chromium's own in a windowed
        /// or Chrome-style browser, the view's `toolTip` in a
        /// ``CefOffscreenBrowserView``. ``CefBrowser/tooltip`` still says
        /// what shows.
        case automatic
        /// The app shows ``CefBrowser/tooltip`` itself, for example with
        /// `CefWebView.pageTooltip(_:)` in CefSwiftUI; nothing else shows.
        case custom
    }

    /// Chromium reported `text` as the page's tooltip, empty for none.
    /// Returns whether Chromium must show nothing itself.
    func tooltipDidChange(_ text: String) -> Bool {
        if text.isEmpty {
            hideTooltip()
        } else {
            let value = Tooltip(text: text, location: pointerLocationInHost)
            if tooltip != value { tooltip = value }
        }
        return tooltipPolicy == .custom
    }

    /// Hides the tooltip: the pointer left, the user scrolled or typed, the
    /// page changed, the browser lost focus, closed or was discarded.
    func hideTooltip() {
        guard tooltip != nil else { return }
        tooltip = nil
        client?.offscreenHost?.offscreenDidChangeToolTip(nil)
    }

    /// The pointer in the host view, top-left origin: the last point sent
    /// to an offscreen browser, the mouse's position over a windowed one.
    var pointerLocationInHost: CGPoint {
        if isOffscreen { return lastPointerLocation }
        guard let view = hostView, let window = view.window else { return .zero }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
    }
}
