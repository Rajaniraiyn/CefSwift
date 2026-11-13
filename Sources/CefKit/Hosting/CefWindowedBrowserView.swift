import AppKit
import Foundation

/// An `NSView` showing a windowed browser: Chromium's own native view is
/// added as a subview and kept sized to fill it. Chromium handles input,
/// IME and accessibility itself.
///
/// Use it for browsers whose ``CefBrowser/Configuration/rendering`` is
/// `.windowed` (the default). Chromium creates the browser once the view is
/// in a window. The view never closes its browser: call
/// ``CefBrowser/close(force:)`` when you are done with it.
///
/// ```swift
/// let browser = CefBrowser(url: URL(string: "https://example.com")!)
/// window.contentView = CefWindowedBrowserView(browser: browser)
/// ```
///
/// `CefWebView` in CefSwiftUI hosts its windowed browsers in this view.
@MainActor
public final class CefWindowedBrowserView: NSView {

    /// The browser shown in this view. Assigning a browser that is already
    /// live moves its native view here; assigning `nil` removes it.
    public var browser: CefBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            browserDidChange(from: oldValue)
        }
    }

    private var swipeMonitor: Any?

    /// Whether ``tearDown()`` closes the browser. `CefWebView(url:)` sets
    /// this for the browser it owns.
    package var closesBrowserOnTeardown = false
    private var isTornDown = false

    /// Creates a view showing `browser`.
    public init(browser: CefBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        // The canvas until Chromium's view paints, and where a resize
        // uncovers the view before Chromium's catches up.
        wantsLayer = true
        browserDidChange(from: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func browserDidChange(from oldValue: CefBrowser?) {
        if let previous = oldValue?.nativeView, previous.superview === self {
            previous.removeFromSuperview()
        }
        layer?.backgroundColor = browser?.hostBackgroundColor
        hostBrowserIfPossible()
        updateSwipeMonitor()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostBrowserIfPossible()
        updateSwipeMonitor()
    }

    /// Chromium's view takes scroll events directly, so swipes are claimed
    /// before it sees them, while the view is in a window and the browser
    /// allows them.
    private func updateSwipeMonitor() {
        let wantsMonitor = !isTornDown && window != nil
            && browser?.configuration.allowsBackForwardNavigationGestures == true
        guard wantsMonitor != (swipeMonitor != nil) else { return }
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
            return
        }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let browser = self.browser, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return false }
                if event.type == .swipe {
                    return browser.handleNavigationSwipe(event)
                }
                return browser.beginHistorySwipeIfNeeded(with: event)
            }
            return claimed ? nil : event
        }
    }

    /// A discarded browser comes back when its view is shown again.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        hostBrowserIfPossible()
    }

    /// Chromium can only create a windowed browser inside a window, so
    /// hosting waits until the view is in one.
    private func hostBrowserIfPossible() {
        guard !isTornDown, window != nil, let browser else { return }
        browser.host(windowedIn: self)
    }

    // MARK: Focus

    /// The view stands in the window's key-view loop for its page, so Tab
    /// and Shift-Tab from the app's controls reach it.
    public override var acceptsFirstResponder: Bool {
        browser?.state == .live && browser?.nativeView?.superview === self
    }

    /// Selected through the key-view loop, it hands focus to the page and
    /// focuses the page's first element (Tab) or last (Shift-Tab).
    public override func becomeFirstResponder() -> Bool {
        guard let browser, super.becomeFirstResponder() else { return false }
        let direction = window?.keyViewSelectionDirection ?? .directSelection
        let selectedIn = window
        // Once AppKit has finished selecting this view, and only if it is
        // still selected, in the same window, for the same browser: focus
        // that moved on meanwhile must not be taken back.
        DispatchQueue.main.async { [weak self, weak browser] in
            guard let self, let browser, let window = self.window, window === selectedIn,
                  window.firstResponder === self, self.browser === browser, browser.state == .live
            else { return }
            browser.hostViewDidBecomeKey(selecting: direction)
        }
        return true
    }

    /// Stops hosting for good: removes the swipe monitor, closes the browser
    /// if ``closesBrowserOnTeardown`` is set, and clears ``browser``.
    package func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        updateSwipeMonitor()
        if closesBrowserOnTeardown {
            browser?.close(force: true)
        }
        browser = nil
    }
}
