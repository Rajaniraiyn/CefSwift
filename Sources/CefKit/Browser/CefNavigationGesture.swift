import AppKit
import Foundation
import ObjectiveC

// MARK: - Chrome's history swiping

/// Chrome-style browsers swipe through history natively: Chrome's
/// `ChromeRenderWidgetHostViewMacDelegate` hands scroll events to a
/// `HistorySwiper`, which navigates and draws its progress with a
/// `HistoryOverlayController`. These overrides gate that on
/// ``CefBrowser/Configuration/allowsBackForwardNavigationGestures``, report its
/// progress to ``CefBrowser/navigationGestureProgress``, and hide Chrome's
/// overlay unless the browser
/// ``CefBrowser/Configuration/showsChromiumNavigationGestureIndicator``.
///
/// Only windows of a ``CefWindow`` are affected; windows from
/// ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)`` keep
/// Chrome's behavior.
@MainActor
enum CefHistorySwipeHooks {
    private nonisolated(unsafe) static var browserKey = 0
    private nonisolated(unsafe) static var modeKey = 0

    /// `HistoryOverlayMode`: back is 0, forward 1.
    private static let forwardMode: Int32 = 1

    private final class WeakBrowser {
        weak var browser: CefBrowser?
        init(_ browser: CefBrowser) { self.browser = browser }
    }

    private typealias BoolGetter = @convention(c) (NSObject, Selector) -> Bool
    private typealias InitForMode = @convention(c) (NSObject, Selector, Int32) -> NSObject?
    private typealias ShowPanel = @convention(c) (NSObject, Selector, NSView) -> Void
    private typealias SetProgress = @convention(c) (NSObject, Selector, Double, Bool) -> Void
    private typealias Dismiss = @convention(c) (NSObject, Selector) -> Void

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Gate swiping on the browser's option.
        let allowSelector = NSSelectorFromString("shouldAllowHistorySwiping")
        let nsViewSelector = NSSelectorFromString("nsView")
        var allowOriginal: BoolGetter?
        let allow: @convention(block) (NSObject) -> Bool = { delegate in
            let allowed = allowOriginal?(delegate, allowSelector) ?? false
            guard allowed, delegate.responds(to: nsViewSelector),
                  let view = delegate.perform(nsViewSelector)?.takeUnretainedValue() as? NSView
            else { return allowed }
            return MainActor.assumeIsolated {
                guard let browser = browser(showing: view) else { return allowed }
                return browser.configuration.allowsBackForwardNavigationGestures
            }
        }
        let delegate = "ChromeRenderWidgetHostViewMacDelegate"
        CefObjCHook.installFeature(
            "swipe gating", requires: [.init(delegate, nsViewSelector, types: "@@:")],
            overrides: [
                .init(method: .init(delegate, allowSelector, types: "B@:"), block: allow) {
                    allowOriginal = unsafeBitCast($0, to: BoolGetter.self)
                },
            ])

        let controller = "HistoryOverlayController"

        // Remember each overlay's direction.
        let initSelector = NSSelectorFromString("initForMode:")
        var initOriginal: InitForMode?
        let initForMode: @convention(block) (NSObject, Int32) -> NSObject? = { overlay, mode in
            let result = initOriginal?(overlay, initSelector, mode)
            if let result {
                objc_setAssociatedObject(result, &modeKey, NSNumber(value: mode), .OBJC_ASSOCIATION_RETAIN)
            }
            return result
        }

        // Find the browser, and show Chrome's overlay only when asked to.
        let showSelector = NSSelectorFromString("showPanelForView:")
        var showOriginal: ShowPanel?
        let show: @convention(block) (NSObject, NSView) -> Void = { overlay, view in
            let browser = MainActor.assumeIsolated { Self.browser(showing: view) }
            guard let browser else {
                showOriginal?(overlay, showSelector, view)
                return
            }
            objc_setAssociatedObject(overlay, &browserKey, WeakBrowser(browser), .OBJC_ASSOCIATION_RETAIN)
            let showsChromium = MainActor.assumeIsolated { browser.configuration.showsChromiumNavigationGestureIndicator }
            if showsChromium { showOriginal?(overlay, showSelector, view) }
        }

        // Report progress. Chrome's overlay methods do nothing when its view
        // was never shown.
        let progressSelector = NSSelectorFromString("setProgress:finished:")
        var progressOriginal: SetProgress?
        let setProgress: @convention(block) (NSObject, Double, Bool) -> Void = { overlay, amount, finished in
            progressOriginal?(overlay, progressSelector, amount, finished)
            guard let box = objc_getAssociatedObject(overlay, &browserKey) as? WeakBrowser else { return }
            let mode = (objc_getAssociatedObject(overlay, &modeKey) as? NSNumber)?.int32Value ?? 0
            // `finished` is Chrome's "releasing now navigates"; ±1 is that
            // threshold in navigationGestureProgress.
            let magnitude = finished ? max(abs(amount), 1) : min(abs(amount), 0.99)
            MainActor.assumeIsolated {
                box.browser?.navigationGestureProgress = mode == forwardMode ? magnitude : -magnitude
            }
        }

        let dismissSelector = NSSelectorFromString("dismiss")
        var dismissOriginal: Dismiss?
        let dismiss: @convention(block) (NSObject) -> Void = { overlay in
            dismissOriginal?(overlay, dismissSelector)
            guard let box = objc_getAssociatedObject(overlay, &browserKey) as? WeakBrowser else { return }
            MainActor.assumeIsolated { box.browser?.navigationGestureProgress = 0 }
        }

        // The overlay's hooks share state (its browser and direction): all
        // of them or none.
        CefObjCHook.installFeature("swipe indicator", overrides: [
            .init(method: .init(controller, initSelector, types: "@@:i"), block: initForMode) {
                initOriginal = unsafeBitCast($0, to: InitForMode.self)
            },
            .init(method: .init(controller, showSelector, types: "v@:@"), block: show) {
                showOriginal = unsafeBitCast($0, to: ShowPanel.self)
            },
            .init(method: .init(controller, progressSelector, types: "v@:dB"), block: setProgress) {
                progressOriginal = unsafeBitCast($0, to: SetProgress.self)
            },
            .init(method: .init(controller, dismissSelector, types: "v@:"), block: dismiss) {
                dismissOriginal = unsafeBitCast($0, to: Dismiss.self)
            },
        ])
    }

    /// The browser of the ``CefWindow`` that shows `view`.
    private static func browser(showing view: NSView) -> CefBrowser? {
        guard let window = view.window else { return nil }
        return CefWindow.owning(window)?.browser
    }

    /// Starts a swipe on Chrome's own overlay controller as `HistorySwiper`
    /// does, so tests can exercise these overrides without a trackpad.
    /// Returns `nil` when the class is missing.
    static func beginSimulatedSwipe(in window: CefWindow, forward: Bool) -> NSObject? {
        guard let cls = NSClassFromString("HistoryOverlayController") as? NSObject.Type,
              let page = window.browser.nativeView,
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let initImp = class_getMethodImplementation(cls, NSSelectorFromString("initForMode:")),
              let showImp = class_getMethodImplementation(cls, NSSelectorFromString("showPanelForView:")),
              let overlay = unsafeBitCast(initImp, to: InitForMode.self)(
                  allocated, NSSelectorFromString("initForMode:"), forward ? forwardMode : 0)
        else { return nil }
        unsafeBitCast(showImp, to: ShowPanel.self)(overlay, NSSelectorFromString("showPanelForView:"), page)
        return overlay
    }

    static func updateSimulatedSwipe(_ overlay: NSObject, amount: Double, finished: Bool) {
        guard let imp = class_getMethodImplementation(type(of: overlay), NSSelectorFromString("setProgress:finished:"))
        else { return }
        unsafeBitCast(imp, to: SetProgress.self)(overlay, NSSelectorFromString("setProgress:finished:"), amount, finished)
    }

    static func endSimulatedSwipe(_ overlay: NSObject) {
        guard let imp = class_getMethodImplementation(type(of: overlay), NSSelectorFromString("dismiss")) else { return }
        unsafeBitCast(imp, to: Dismiss.self)(overlay, NSSelectorFromString("dismiss"))
    }
}

// MARK: - Swipes in views

extension CefBrowser {
    /// Starts AppKit's fluid two-finger history swipe when a scroll gesture
    /// begins sideways and there is history in that direction, updating
    /// ``navigationGestureProgress`` and navigating when the swipe
    /// completes. Returns whether the gesture was claimed; a claimed event
    /// must not also scroll the page.
    ///
    /// For views that host the browser; Chrome-style browsers swipe
    /// natively.
    func beginHistorySwipeIfNeeded(with event: NSEvent) -> Bool {
        guard configuration.allowsBackForwardNavigationGestures,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.phase == .began,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return false }
        let goesBack = event.scrollingDeltaX > 0
        guard goesBack ? canGoBack : canGoForward else { return false }
        event.trackSwipeEvent(options: .lockDirection, dampenAmountThresholdMin: -1, max: 1) { [weak self] amount, phase, isComplete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // AppKit reports positive amounts for "back".
                self.navigationGestureProgress = isComplete ? 0 : -Double(amount)
                guard phase == .ended, abs(amount) >= 1 else { return }
                if goesBack { self.goBack() } else { self.goForward() }
            }
        }
        return true
    }

    /// Handles the dedicated navigation swipe (three fingers, or as set in
    /// System Settings). Returns whether it navigated.
    @discardableResult
    func handleNavigationSwipe(_ event: NSEvent) -> Bool {
        guard configuration.allowsBackForwardNavigationGestures else { return false }
        if event.deltaX > 0, canGoBack {
            goBack()
            return true
        } else if event.deltaX < 0, canGoForward {
            goForward()
            return true
        }
        return false
    }
}
