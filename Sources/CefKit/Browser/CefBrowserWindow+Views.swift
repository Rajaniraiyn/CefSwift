import AppKit
import CCef
import Foundation
import Observation
import CefBase

// MARK: - Content frame

/// Paints the window background everywhere except a rounded rectangle over
/// the page, and lets every event through to Chromium beneath it.
final class ContentFrameView: NSView {
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    private let cutout = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        cutout.fillRule = .evenOdd
        layer?.mask = cutout
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        // AppKit's y axis points up, so the top inset comes off maxY.
        let page = CGRect(
            x: insets.left, y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom)
        let path = CGMutablePath()
        path.addRect(bounds)
        if page.width > 0, page.height > 0 {
            let radius = min(cornerRadius, page.width / 2, page.height / 2)
            path.addRoundedRect(in: page, cornerWidth: radius, cornerHeight: radius)
        }
        cutout.frame = bounds
        cutout.path = path
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Holds views over the page's rectangle — the swipe indicator, the app's
/// status bubble — clipped to its rounded corners, and lets every event
/// through.
final class PageOverlayView: NSView {
    var insets = NSEdgeInsets() { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    private let clip = NSView()

    init() {
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `views`, bottom to top, each filling the page.
    func setViews(_ views: [NSView]) {
        guard clip.subviews != views else { return }
        clip.subviews.forEach { $0.removeFromSuperview() }
        for view in views {
            view.frame = clip.bounds
            view.autoresizingMask = [.width, .height]
            clip.addSubview(view)
        }
    }

    override func layout() {
        super.layout()
        clip.frame = CGRect(
            x: insets.left, y: insets.bottom,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom))
        clip.layer?.cornerRadius = cornerRadius
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Views delegates

/// Owner of a `cef_browser_view_delegate_t`. Popups opened from the view get
/// a delegate of their own showing Chrome's location bar.
final class BrowserViewDelegate: Sendable {
    let toolbar: CefBrowserWindow.Toolbar
    /// The window whose page may open popups; UI thread only.
    private let windowReference: CefWeak<CefBrowserWindow>
    private var window: CefBrowserWindow? { windowReference.object }

    init(toolbar: CefBrowserWindow.Toolbar, window: CefBrowserWindow?) {
        self.toolbar = toolbar
        windowReference = CefWeak(window)
    }

    func makeDelegate() -> UnsafeMutablePointer<cef_browser_view_delegate_t> {
        let d = cefAllocate(cef_browser_view_delegate_t.self, owner: self)
        // The browser itself is tracked through the life span handler.
        d.pointee.on_browser_created = { _, view, browser in
            cefRelease(view)
            cefRelease(browser)
        }
        d.pointee.on_browser_destroyed = { _, view, browser in
            cefRelease(view)
            cefRelease(browser)
        }
        d.pointee.get_delegate_for_popup_browser_view = { s, view, _, client, isDevTools in
            cefRelease(view)
            cefRelease(client)
            // A popup the app will host keeps the opener's toolbar choice;
            // one Chromium hosts shows its location bar.
            guard isDevTools == 0, let owner = cefOwner(BrowserViewDelegate.self, s) else {
                return BrowserViewDelegate(toolbar: .location, window: nil).makeDelegate()
            }
            return MainActor.assumeIsolated {
                let hosted = owner.window?.onPopup != nil
                return CefRef(adopting: BrowserViewDelegate(
                    toolbar: hosted ? owner.toolbar : .location, window: nil).makeDelegate())
            }.retainedPointer()
        }
        d.pointee.on_popup_browser_view_created = { s, view, popupView, isDevTools in
            cefRelease(view)
            // Adopted before anything can return early.
            let popupView = CefRef(adopting: popupView)
            guard isDevTools == 0, let popupView, let owner = cefOwner(BrowserViewDelegate.self, s)
            else { return 0 }
            // Non-zero tells CEF the app is giving the popup a window.
            return MainActor.assumeIsolated { owner.window?.adoptPopup(popupView) == true ? 1 : 0 }
        }
        d.pointee.get_chrome_toolbar_type = { s, view in
            cefRelease(view)
            switch cefOwner(BrowserViewDelegate.self, s)?.toolbar {
            case .chrome: return CEF_CTT_NORMAL
            case .location: return CEF_CTT_LOCATION
            case .none?, nil: return CEF_CTT_NONE
            }
        }
        d.pointee.get_browser_runtime_style = { _ in CEF_RUNTIME_STYLE_CHROME }
        return d
    }
}

/// Owner of a `cef_window_delegate_t`. Callbacks arrive on the UI thread.
final class WindowDelegate: Sendable {
    private let ownerReference: CefWeak<CefBrowserWindow>
    private var owner: CefBrowserWindow? { ownerReference.object }

    @MainActor
    init(owner: CefBrowserWindow) {
        ownerReference = CefWeak(owner)
    }

    private static func with<S, R: Sendable>(
        _ delegateSelf: UnsafeMutablePointer<S>?,
        _ window: UnsafeMutablePointer<cef_window_t>?,
        default fallback: R,
        _ body: @MainActor (CefBrowserWindow) -> R
    ) -> R {
        defer { cefRelease(window) }
        guard let delegate = cefOwner(WindowDelegate.self, delegateSelf) else { return fallback }
        return MainActor.assumeIsolated {
            guard let owner = delegate.owner else { return fallback }
            return body(owner)
        }
    }

    func makeDelegate() -> UnsafeMutablePointer<cef_window_delegate_t> {
        let d = cefAllocate(cef_window_delegate_t.self, owner: self)
        d.pointee.on_window_created = { s, window in
            guard let window else { return }
            nonisolated(unsafe) let created = window
            WindowDelegate.with(s, window, default: ()) { $0.windowCreated(created) }
        }
        d.pointee.on_window_destroyed = { s, window in
            WindowDelegate.with(s, window, default: ()) { $0.windowDestroyed() }
        }
        d.pointee.can_close = { s, window in
            // Routed through the browser so `beforeunload` can object.
            WindowDelegate.with(s, window, default: 1) { $0.browser.tryClose() ? 1 : 0 }
        }
        d.pointee.is_frameless = { s, window in
            WindowDelegate.with(s, window, default: 0) { $0.configuration.isFrameless ? 1 : 0 }
        }
        d.pointee.with_standard_window_buttons = { s, window in
            WindowDelegate.with(s, window, default: 1) { $0.configuration.isFrameless ? 0 : 1 }
        }
        d.pointee.get_initial_bounds = { s, window in
            WindowDelegate.with(s, window, default: cef_rect_t()) {
                $0.configuration.frame.map { cef_rect_t(screenRect: $0) } ?? cef_rect_t()
            }
        }
        d.pointee.get_initial_show_state = { _, window in
            cefRelease(window)
            return CEF_SHOW_STATE_HIDDEN
        }
        d.pointee.get_window_runtime_style = { _ in CEF_RUNTIME_STYLE_CHROME }
        return d
    }
}
