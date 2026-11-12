import AppKit

/// Hooks for CefSwift's own end-to-end tests (the SelfTest example), which
/// drive what a test cannot produce with real input. Not for apps.
@_spi(Testing)
@MainActor
public enum CefTesting {
    /// The overrides of Chromium's AppKit classes that could not be
    /// installed in this CEF build, as `Class -selector` strings. Empty
    /// when bubble anchoring and Chrome-style swipe integration work.
    public static var missingRuntimeHooks: [String] {
        CefBubbleTracker.install()
        CefHistorySwipeHooks.install()
        return CefObjCHook.missingHooks
    }

    /// Sets ``CefBrowser/navigationGestureProgress`` as a swipe would.
    public static func setNavigationGestureProgress(_ progress: Double, for browser: CefBrowser) {
        browser.navigationGestureProgress = progress
    }

    /// Starts a history swipe on Chrome's own overlay controller, as
    /// Chrome's `HistorySwiper` does for a trackpad swipe. `nil` when the
    /// class is missing.
    public static func beginChromeSwipe(in window: CefBrowserWindow, forward: Bool) -> AnyObject? {
        CefHistorySwipeHooks.beginSimulatedSwipe(in: window, forward: forward)
    }

    /// Reports swipe progress to an overlay from ``beginChromeSwipe(in:forward:)``.
    public static func updateChromeSwipe(_ overlay: AnyObject, amount: Double, finished: Bool) {
        guard let overlay = overlay as? NSObject else { return }
        CefHistorySwipeHooks.updateSimulatedSwipe(overlay, amount: amount, finished: finished)
    }

    /// Ends a swipe from ``beginChromeSwipe(in:forward:)``.
    public static func endChromeSwipe(_ overlay: AnyObject) {
        guard let overlay = overlay as? NSObject else { return }
        CefHistorySwipeHooks.endSimulatedSwipe(overlay)
    }

    /// Whether `view` or a view inside it is CefSwift's built-in swipe
    /// indicator, and whether that indicator is showing.
    public static func gestureIndicator(in view: NSView) -> (isInstalled: Bool, isShowing: Bool) {
        guard let indicator = find(CefNavigationGestureIndicatorView.self, in: view) else { return (false, false) }
        return (true, indicator.isShowingIndicator)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
