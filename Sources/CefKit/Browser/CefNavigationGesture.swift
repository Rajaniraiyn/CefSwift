import AppKit
import Foundation
import ObjectiveC
import QuartzCore

extension CefBrowser {
    /// How a browser shows a back or forward swipe in progress. Set it with
    /// ``CefBrowser/Configuration/navigationGestureIndicator``.
    public enum NavigationGestureIndicator: Sendable, Equatable {
        /// CefSwift's indicator: a chevron in a circle that slides in from the
        /// edge the page is leaving, rubber-bands, and fills with the accent
        /// color once releasing would navigate.
        case automatic
        /// Chromium's own indicator in Chrome-style browsers
        /// (``CefBrowserWindow``); ``automatic`` elsewhere.
        case chromium
        /// No indicator. Draw your own from
        /// ``CefBrowser/navigationGestureProgress``.
        case hidden
    }
}

extension NSView {
    /// Adds, updates or removes the built-in swipe indicator over this host
    /// view, following the browser's options, and returns the indicator
    /// now installed. `isAllowed` is false when the app draws an indicator
    /// of its own.
    func updatedGestureIndicator(
        _ indicator: CefNavigationGestureIndicatorView?, browser: CefBrowser?, isAllowed: Bool
    ) -> CefNavigationGestureIndicatorView? {
        guard isAllowed, let browser, browser.configuration.allowsBackForwardNavigationGestures,
              browser.configuration.navigationGestureIndicator != .hidden
        else {
            indicator?.removeFromSuperview()
            return nil
        }
        let view = indicator ?? CefNavigationGestureIndicatorView()
        view.browser = browser
        if view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .above, relativeTo: nil)
        }
        return view
    }
}

/// The indicator drawn for ``CefBrowser/NavigationGestureIndicator/automatic``.
///
/// It follows a browser's ``CefBrowser/navigationGestureProgress``: hidden at
/// 0, sliding in from the leading edge as the progress moves toward -1
/// (back) or from the trailing edge toward 1 (forward), and highlighted from
/// ±1 on, where releasing navigates. Beyond that it resists, as a
/// rubber band does. Place it over the page; it never takes events.
@MainActor
final class CefNavigationGestureIndicatorView: NSView {
    /// Diameter of the circle.
    private static let diameter: CGFloat = 44
    /// How far the circle's edge travels from the page edge at progress 1.
    private static let travel: CGFloat = 72

    weak var browser: CefBrowser? {
        didSet { observeProgress() }
    }

    /// The progress shown: -1…1 and beyond, as
    /// ``CefBrowser/navigationGestureProgress``.
    private(set) var progress = 0.0

    /// Whether the indicator is showing, for tests.
    var isShowingIndicator: Bool { !circle.isHidden && circle.opacity > 0 }

    private let circle = CALayer()
    private let chevron = CAShapeLayer()
    private var isArmed = false
    /// The direction ``chevron``'s path points, once it has one.
    private var chevronPointsBack: Bool?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        circle.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        circle.cornerRadius = Self.diameter / 2
        circle.shadowOpacity = 0.18
        circle.shadowRadius = 6
        circle.shadowOffset = CGSize(width: 0, height: -1)
        circle.opacity = 0
        chevron.lineWidth = 3
        chevron.lineCap = .round
        chevron.lineJoin = .round
        chevron.fillColor = nil
        chevron.frame = circle.bounds
        circle.addSublayer(chevron)
        layer?.addSublayer(circle)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyColors()
    }

    override func layout() {
        super.layout()
        update(animated: false)
    }

    private func observeProgress() {
        guard let browser else { return }
        let value = withObservationTracking {
            browser.navigationGestureProgress
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeProgress() }
        }
        setProgress(value)
    }

    /// Shows `value` without a browser, for previews and tests.
    func setProgress(_ value: Double) {
        let wasShowing = progress != 0
        progress = value
        update(animated: wasShowing && value == 0)
    }

    /// Positions the circle for the current progress.
    private func update(animated: Bool) {
        let magnitude = abs(progress)
        let armed = magnitude >= 1
        CATransaction.begin()
        CATransaction.setDisableActions(!animated && armed == isArmed)
        CATransaction.setAnimationDuration(animated ? 0.2 : 0.12)
        if progress == 0 {
            circle.opacity = 0
            CATransaction.commit()
            return
        }
        let goesBack = progress < 0
        let offset = Self.rubberBand(magnitude) * Self.travel
        let radius = Self.diameter / 2
        // Starts hidden past the page edge and slides in.
        let x = goesBack ? -radius + offset : bounds.width + radius - offset
        CATransaction.setDisableActions(true)
        circle.position = CGPoint(x: x, y: bounds.midY)
        circle.opacity = Float(min(1, magnitude * 2.5))
        CATransaction.setDisableActions(armed == isArmed)
        if chevronPointsBack != goesBack {
            chevronPointsBack = goesBack
            chevron.path = Self.chevronPath(pointingBack: goesBack, in: circle.bounds)
        }
        if armed != isArmed {
            isArmed = armed
            applyColors()
            circle.transform = armed ? CATransform3DMakeScale(1.08, 1.08, 1) : CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            circle.backgroundColor = (isArmed ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).cgColor
            circle.borderColor = NSColor.separatorColor.cgColor
            circle.borderWidth = isArmed ? 0 : 0.5
            chevron.strokeColor = (isArmed ? NSColor.white : NSColor.secondaryLabelColor).cgColor
        }
    }

    /// Linear up to 1, then increasingly resistant.
    nonisolated static func rubberBand(_ value: Double) -> Double {
        guard value > 1 else { return value }
        let excess = value - 1
        return 1 + (1 - 1 / (excess * 0.55 + 1)) * 0.35
    }

    private static func chevronPath(pointingBack: Bool, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let size: CGFloat = 8
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let direction: CGFloat = pointingBack ? 1 : -1
        // In a layer's unflipped space: tip toward the travel direction.
        path.move(to: CGPoint(x: center.x + direction * size / 2, y: center.y + size))
        path.addLine(to: CGPoint(x: center.x - direction * size / 2, y: center.y))
        path.addLine(to: CGPoint(x: center.x + direction * size / 2, y: center.y - size))
        return path
    }
}

// MARK: - Chrome's history swiping

/// Chrome-style browsers swipe through history natively: Chrome's
/// `ChromeRenderWidgetHostViewMacDelegate` hands scroll events to a
/// `HistorySwiper`, which navigates and draws its progress with a
/// `HistoryOverlayController`. These overrides gate that on
/// ``CefBrowser/Configuration/allowsBackForwardNavigationGestures``, report its
/// progress to ``CefBrowser/navigationGestureProgress``, and hide Chrome's
/// overlay unless the browser asks for ``CefBrowser/NavigationGestureIndicator/chromium``.
///
/// Only windows of a ``CefBrowserWindow`` are affected; windows from
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
            let showsChromium = MainActor.assumeIsolated { browser.configuration.navigationGestureIndicator == .chromium }
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

    /// The browser of the ``CefBrowserWindow`` that shows `view`.
    private static func browser(showing view: NSView) -> CefBrowser? {
        guard let window = view.window else { return nil }
        return CefBrowserWindow.owning(window)?.browser
    }

    /// Starts a swipe on Chrome's own overlay controller as `HistorySwiper`
    /// does, so tests can exercise these overrides without a trackpad.
    /// Returns `nil` when the class is missing.
    static func beginSimulatedSwipe(in browserWindow: CefBrowserWindow, forward: Bool) -> NSObject? {
        guard let cls = NSClassFromString("HistoryOverlayController") as? NSObject.Type,
              let page = browserWindow.browser.nativeView,
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
