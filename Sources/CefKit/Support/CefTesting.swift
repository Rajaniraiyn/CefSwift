import AppKit

/// Hooks for CefSwift's own end-to-end tests (the SelfTest example), which
/// drive what a test cannot produce with real input. Not for apps.
@_spi(Testing)
@MainActor
public enum CefTesting {
    /// Each feature built on overrides of Chromium's AppKit classes, with
    /// the `Class -selector` methods it lacks in this CEF build: CefKit's,
    /// and those of modules that have installed theirs (CefChromium's
    /// surfaces, once it is used). A feature with an empty list is
    /// installed; one with missing methods is not installed at all.
    public static var runtimeHookFeatures: [(name: String, missing: [String])] {
        CefHistorySwipeHooks.install()
        return CefObjCHook.features
    }

    /// Starts a history swipe on Chrome's own overlay controller, as
    /// Chrome's `HistorySwiper` does for a trackpad swipe. `nil` when the
    /// class is missing.
    public static func beginChromeSwipe(in window: CefWindow, forward: Bool) -> AnyObject? {
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
}
