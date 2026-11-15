import AppKit
import Foundation

/// An `NSView` showing a windowed page: Chromium's own native view is
/// added as a subview and kept sized to fill it. Chromium handles input,
/// IME and accessibility itself.
///
/// Use it for pages whose ``CefPage/Configuration/rendering`` is
/// `.windowed` (the default). Chromium creates the page once the view is
/// in a window. The view never closes its page: call
/// ``CefPage/close(force:)`` when you are done with it.
///
/// ```swift
/// let page = CefPage(url: URL(string: "https://example.com")!)
/// window.contentView = CefWindowedPageView(page: page)
/// ```
///
/// `CefWebView` in CefSwiftUI hosts its windowed pages in this view.
@MainActor
public final class CefWindowedPageView: NSView {

    /// The page shown in this view. Assigning a page that is already
    /// live moves its native view here; assigning `nil` removes it. The
    /// page assigned before, if still waiting for its profile, is not
    /// created here later.
    ///
    /// It becomes nil when the page moves to another host
    /// (``CefPage/host(windowedIn:)``, another view's `page`) or is
    /// withdrawn from this one (``CefPage/stopHosting(in:)``): a
    /// page shows in one place at a time, and this view no longer
    /// claims its swipes, takes focus for it or hosts it again when it
    /// returns to a window.
    public var page: CefPage? {
        didSet {
            guard page !== oldValue else { return }
            pageDidChange(from: oldValue)
        }
    }

    private var swipeMonitor: Any?
    private var dragMonitor: Any?

    /// Whether ``tearDown()`` closes the page. `CefWebView(url:)` sets
    /// this for the page it owns.
    package var closesPageOnTeardown = false
    private var isTornDown = false

    /// Creates a view showing `page`.
    public init(page: CefPage) {
        self.page = page
        super.init(frame: .zero)
        // The canvas until Chromium's view paints, and where a resize
        // uncovers the view before Chromium's catches up.
        wantsLayer = true
        // Chromium's frame, a frame or two behind an animated size, never
        // draws over the view's neighbours.
        layer?.masksToBounds = true
        pageDidChange(from: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func pageDidChange(from oldValue: CefPage?) {
        // Its native view leaves, and one still waiting for its profile is
        // not created here later.
        oldValue?.stopHosting(in: self)
        layer?.backgroundColor = page?.hostBackgroundColor
        hostPageIfPossible()
        updateSwipeMonitor()
        updateDragMonitor()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Chromium creates a windowed page only in a window; back in
        // one, the view asks again.
        if window == nil { page?.cancelDeferredCreation(in: self) }
        hostPageIfPossible()
        updateSwipeMonitor()
        updateDragMonitor()
    }

    /// Chromium's view takes mouse-downs directly, so a drag that starts
    /// in a region the page marks `-webkit-app-region: drag` is claimed
    /// before it sees it, and moves the window.
    private func updateDragMonitor() {
        let wantsMonitor = !isTornDown && window != nil && page != nil
        guard wantsMonitor != (dragMonitor != nil) else { return }
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
            return
        }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let page = self.page, !page.draggableRegions.isEmpty,
                      let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor
                else { return false }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return false }
                // Regions are in the page's coordinates, top-left origin.
                let pagePoint = CGPoint(x: point.x, y: self.isFlipped ? point.y : self.bounds.height - point.y)
                return page.handleWindowDrag(event, at: pagePoint)
            }
            return claimed ? nil : event
        }
    }

    /// Chromium's view takes scroll events directly, so swipes are claimed
    /// before it sees them, while the view is in a window and the page
    /// allows them.
    private func updateSwipeMonitor() {
        let wantsMonitor = !isTornDown && window != nil
            && page?.configuration.allowsBackForwardNavigationGestures == true
        guard wantsMonitor != (swipeMonitor != nil) else { return }
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
            return
        }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let page = self.page, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return false }
                if event.type == .swipe {
                    return page.handleNavigationSwipe(event)
                }
                return page.beginHistorySwipeIfNeeded(with: event)
            }
            return claimed ? nil : event
        }
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let native = page?.nativeView, native.superview === self { layoutChromiumView(native) }
    }

    /// Sizes Chromium's view to fill this one in whole points, its top
    /// edge on this view's, the fraction past the bottom and trailing
    /// edges clipped.
    ///
    /// Chromium's view keeps the layer that holds its frames sized with
    /// Core Animation's autoresizing, which rounds each change of size: at
    /// the fractional sizes an animation gives a view on every refresh the
    /// rounding adds up, a few points per spring, and that layer ends up
    /// larger than the view, so the page shows shifted up, cut off at the
    /// top, with its background along the bottom. Whole sizes resize it
    /// exactly.
    func layoutChromiumView(_ native: NSView) {
        let size = CGSize(width: bounds.width.rounded(.up), height: bounds.height.rounded(.up))
        let frame = CGRect(x: 0, y: isFlipped ? 0 : bounds.height - size.height, width: size.width, height: size.height)
        if native.frame != frame { native.frame = frame }
    }

    /// A discarded page comes back when its view is shown again.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        hostPageIfPossible()
    }

    /// `page` now shows elsewhere, or was withdrawn from this view.
    func pageDidStopHosting(_ page: CefPage) {
        guard self.page === page else { return }
        self.page = nil
    }

    /// Chromium can only create a windowed page inside a window, so
    /// hosting waits until the view is in one.
    private func hostPageIfPossible() {
        guard !isTornDown, window != nil, let page else { return }
        page.host(windowedIn: self)
    }

    // MARK: Focus

    /// The view stands in the window's key-view loop for its page, so Tab
    /// and Shift-Tab from the app's controls reach it.
    public override var acceptsFirstResponder: Bool {
        page?.state == .live && page?.nativeView?.superview === self
    }

    /// Selected through the key-view loop, it hands focus to the page and
    /// focuses the page's first element (Tab) or last (Shift-Tab).
    public override func becomeFirstResponder() -> Bool {
        guard let page, super.becomeFirstResponder() else { return false }
        let direction = window?.keyViewSelectionDirection ?? .directSelection
        let selectedIn = window
        // Once AppKit has finished selecting this view, and only if it is
        // still selected, in the same window, for the same page: focus
        // that moved on meanwhile must not be taken back.
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, let window = self.window, window === selectedIn,
                  window.firstResponder === self, self.page === page, page.state == .live
            else { return }
            page.hostViewDidBecomeKey(selecting: direction)
        }
        return true
    }

    /// Stops hosting for good: removes the swipe monitor, closes the page
    /// if ``closesPageOnTeardown`` is set, and clears ``page``.
    package func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        updateSwipeMonitor()
        updateDragMonitor()
        if closesPageOnTeardown {
            page?.close(force: true)
        }
        page = nil
    }
}
