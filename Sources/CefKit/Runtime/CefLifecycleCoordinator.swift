import AppKit
import CCef
import Foundation

extension CefBrowser {
    /// Where a page is in its lifecycle, following the states of the web's
    /// Page Lifecycle (`document.visibilityState`, `document.hasFocus()`).
    ///
    /// | State | Page Lifecycle | When |
    /// |---|---|---|
    /// | ``active`` | active | On screen, in the key window of the active app, and the browser's view has focus. |
    /// | ``passive`` | passive | On screen without focus: another view, window or app has it. |
    /// | ``hidden`` | hidden | Not on screen: its window is covered, minimized or ordered out, the app is hidden, its tab is not selected, its view is hidden or out of a window, or it is not open yet. |
    /// | ``discarded`` | discarded | Its page was discarded to free memory (``CefBrowser/discard()``). |
    ///
    /// The web's frozen state has no counterpart: Chromium's way of
    /// freezing a page from outside (`Page.setWebLifecycleState`) stops its
    /// timers but leaves other script running, and frees no memory;
    /// ``CefBrowser/discard()`` frees the page instead.
    public enum Lifecycle: Sendable, Equatable {
        case active
        case passive
        case hidden
        case discarded

        /// Whether the user can see the page.
        public var isVisible: Bool { self == .active || self == .passive }
    }
}

/// When CefKit spends less energy on its own; set it as
/// ``CefRuntime/energySaver``.
///
/// ```swift
/// CefRuntime.shared.energySaver = .automatic   // the default
/// CefRuntime.shared.energySaver = .off         // full frame rate whatever the conditions
/// ```
///
/// While Low Power Mode is on, or the Mac reports serious or critical
/// thermal pressure, offscreen browsers draw at most
/// ``reducedOffscreenFrameRate`` frames a second: on an animated page that
/// halves the CPU time a browser takes at 60 frames a second. Hidden
/// browsers draw nothing in any case, and windows Chromium draws itself
/// keep the display's rate.
public struct CefEnergySaver: Sendable, Equatable {
    /// The highest frame rate offscreen browsers draw at while energy is
    /// constrained; `nil` keeps each browser's own rate.
    public var reducedOffscreenFrameRate: Int?

    public init(reducedOffscreenFrameRate: Int? = 30) {
        self.reducedOffscreenFrameRate = reducedOffscreenFrameRate.map { max($0, 1) }
    }

    /// Reduces offscreen frame rates to 30 while energy is constrained.
    public static let automatic = CefEnergySaver()

    /// Leaves frame rates alone.
    public static let off = CefEnergySaver(reducedOffscreenFrameRate: nil)
}

/// What the system reports about power and heat.
struct CefEnergyConditions: Equatable {
    var isLowPowerModeEnabled: Bool
    var thermalState: ProcessInfo.ThermalState

    static var current: CefEnergyConditions {
        CefEnergyConditions(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    /// Whether the Mac asks apps to do less.
    var isConstrained: Bool {
        isLowPowerModeEnabled || thermalState == .serious || thermalState == .critical
    }
}

/// Turns window, app and system signals into what Chromium is told, and
/// publishes each browser's ``CefBrowser/lifecycle``.
///
/// - Visibility: Chromium hides a windowed browser's page itself when its
///   window is covered by one of the session's windows, but not when the
///   window is minimized or ordered out or the app is hidden; the
///   coordinator hides Chromium's view whenever the window cannot be seen
///   (`was_hidden` does nothing for windowed browsers). Offscreen views
///   report their own visibility through `was_hidden`; Chrome-style
///   windows are Chromium's.
/// - Energy: offscreen frame rates under ``CefRuntime/energySaver``.
/// - Memory: ``CefRuntime/memorySaver`` hears every visibility change.
///
/// Chromium watches memory pressure and system sleep itself, and turns
/// App Nap off for the browser process (`NSAppSleepDisabled`), so none of
/// those need forwarding.
@MainActor
final class CefLifecycleCoordinator {
    var energySaver = CefEnergySaver.automatic {
        didSet { if energySaver != oldValue { setNeedsUpdate() } }
    }

    /// Replaces the system's power and thermal readings, for tests.
    var simulatedConditions: CefEnergyConditions? {
        didSet { setNeedsUpdate() }
    }

    var conditions: CefEnergyConditions { simulatedConditions ?? .current }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var responderObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var isUpdateScheduled = false

    /// Starts following the signals. Called once Chromium is running.
    func start() {
        guard observers.isEmpty else { return }
        let app: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
            NSApplication.didHideNotification, NSApplication.willUnhideNotification,
            NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification,
            ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
        ]
        let workspace: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
        ]
        for (center, names) in [(NotificationCenter.default, app), (NSWorkspace.shared.notificationCenter, workspace)] {
            for name in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let isUnhiding = notification.name == NSApplication.willUnhideNotification
                    MainActor.assumeIsolated {
                        // Showing Chromium's views before the windows come
                        // back avoids a blank frame.
                        if isUnhiding { self?.update(isAppUnhiding: true) } else { self?.setNeedsUpdate() }
                    }
                }
                observers.append((center, token))
            }
        }
        setNeedsUpdate()
    }

    /// Stops following the signals, as Chromium shuts down.
    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        responderObservations = [:]
    }

    /// Updates every browser on the next turn of the run loop, once.
    func setNeedsUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.isUpdateScheduled = false
                self.update()
            }
        }
    }

    func update(isAppUnhiding: Bool = false) {
        let conditions = conditions
        var windows = Set<ObjectIdentifier>()
        for browser in CefRuntime.shared.browsers {
            let window = browser.lifecycleWindow
            if let window {
                windows.insert(ObjectIdentifier(window))
                observeFirstResponder(of: window)
            }
            applyNativeViewVisibility(browser, window: window, isAppUnhiding: isAppUnhiding)
            let lifecycle = Self.lifecycle(of: browser, in: window)
            if browser.lifecycle != lifecycle { browser.lifecycle = lifecycle }
            applyFrameRate(browser, conditions: conditions)
        }
        responderObservations = responderObservations.filter { windows.contains($0.key) }
        CefRuntime.shared.memorySaverMonitor.visibilityDidChange()
    }

    /// Focus moves without a notification; `firstResponder` is observable.
    private func observeFirstResponder(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard responderObservations[id] == nil else { return }
        responderObservations[id] = window.observe(\.firstResponder, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsUpdate() }
        }
    }

    // MARK: Lifecycle

    static func lifecycle(of browser: CefBrowser, in window: NSWindow?) -> CefBrowser.Lifecycle {
        if browser.isDiscarded { return .discarded }
        guard browser.state == .live, let window, isVisible(browser, in: window) else { return .hidden }
        return hasFocus(browser, in: window) ? .active : .passive
    }

    private static func isVisible(_ browser: CefBrowser, in window: NSWindow) -> Bool {
        guard window.occlusionState.contains(.visible), window.isVisible, !window.isMiniaturized else { return false }
        if browser.isOffscreen {
            guard !browser.isHostViewHidden, let host = browser.hostView else { return false }
            return host.window === window && !host.isHiddenOrHasHiddenAncestor
        }
        if let host = browser.hostView, host.window !== window || host.isHiddenOrHasHiddenAncestor { return false }
        if let native = browser.nativeView, native.window == nil || native.isHiddenOrHasHiddenAncestor { return false }
        return true
    }

    private static func hasFocus(_ browser: CefBrowser, in window: NSWindow) -> Bool {
        guard NSApp.isActive, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        guard let root = browser.isOffscreen ? browser.hostView : browser.nativeView else { return false }
        return responder === root || responder.isDescendant(of: root)
    }

    // MARK: Windowed browsers

    /// Hides Chromium's view in a window that is minimized or ordered out,
    /// or while the app is hidden, which Chromium does not notice for a
    /// view in the app's own window; shows it again after.
    private func applyNativeViewVisibility(_ browser: CefBrowser, window: NSWindow?, isAppUnhiding: Bool) {
        guard browser.isWindowedInAppView, let native = browser.nativeView, let window else { return }
        // Covered windows Chromium mostly notices itself, but not when the
        // cover belongs to another space or app it does not track, and it
        // shows the page again whenever the view moves or shows; so any
        // window that cannot be seen counts.
        let shouldHide = !isAppUnhiding
            && (window.isMiniaturized || !window.isVisible || NSApp.isHidden || !window.occlusionState.contains(.visible))
        if shouldHide, !browser.lifecycleHidNativeView, !native.isHidden {
            if let responder = window.firstResponder as? NSView, responder === native || responder.isDescendant(of: native) {
                browser.responderBeforeLifecycleHide = responder
            }
            native.isHidden = true
            browser.lifecycleHidNativeView = true
        } else if !shouldHide, browser.lifecycleHidNativeView {
            native.isHidden = false
            browser.lifecycleHidNativeView = false
            if let responder = browser.responderBeforeLifecycleHide, window.firstResponder === window {
                window.makeFirstResponder(responder)
            }
            browser.responderBeforeLifecycleHide = nil
        }
    }

    // MARK: Energy

    private func applyFrameRate(_ browser: CefBrowser, conditions: CefEnergyConditions) {
        guard browser.isOffscreen, browser.state == .live, case .offscreen(let requested) = browser.options.rendering
        else { return }
        var rate = requested
        if conditions.isConstrained, let reduced = energySaver.reducedOffscreenFrameRate {
            rate = min(rate, reduced)
        }
        // A rate below the one the browser was created with does not hold:
        // Chromium goes back to it now and then, while still reporting the
        // lower one. It is set again on every update and twice a second.
        let isReduced = rate < requested
        if isReduced { needsFrameRateRefresh = true }
        guard browser.appliedOffscreenFrameRate != rate || isReduced else { return }
        browser.appliedOffscreenFrameRate = rate
        browser.withHost { $0.pointee.set_windowless_frame_rate($0, Int32(rate)) }
    }

    /// Set during an update when some browser runs below its own rate.
    private var needsFrameRateRefresh = false {
        didSet { if needsFrameRateRefresh != oldValue { scheduleFrameRateRefresh() } }
    }
    private var frameRateRefresh: Task<Void, Never>?

    private func scheduleFrameRateRefresh() {
        frameRateRefresh?.cancel()
        frameRateRefresh = nil
        guard needsFrameRateRefresh else { return }
        frameRateRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.needsFrameRateRefresh = false
                self.update()
            }
        }
    }
}

extension CefBrowser {
    /// The window whose state decides whether the browser can be seen.
    var lifecycleWindow: NSWindow? {
        if let window = hostView?.window { return window }
        if let window = CefBrowserWindow.all.first(where: { $0.browser === self })?.window { return window }
        return nativeView?.window
    }

    /// Whether this is an Alloy browser whose Chromium view sits in one of
    /// the app's views.
    var isWindowedInAppView: Bool {
        isEmbeddedView && !isOffscreen && !isChromeStyle
    }
}
