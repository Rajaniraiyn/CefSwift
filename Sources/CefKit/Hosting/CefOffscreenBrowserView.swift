import AppKit
import Foundation

/// An `NSView` showing an offscreen-rendered browser.
///
/// Chromium paints into a shared `IOSurface`, which this view copies on the
/// GPU into a surface of its own and sets as the contents of a layer, so
/// the page is an ordinary layer-backed subview:
/// native views can sit over it, and it clips, animates and composites like
/// any other. In exchange the view does what a Chromium window would do —
/// forwarding mouse, keyboard, scroll, IME and drag input, applying cursors,
/// and presenting context menus.
///
/// The page follows SwiftUI and AppKit animations of the view: input lands
/// where a transformed view shows the page, ``resizePolicy`` says when the
/// page lays out while the size animates, ``pageSize`` lays it out at a
/// size of its own, and ``framePlacement`` places a frame of another size
/// than the view.
///
/// Chromium paints at the browser's frame rate while the view can be seen.
/// When its window is occluded or miniaturized, or the view is hidden, the
/// view tells the browser it is hidden, and Chromium stops painting.
///
/// Use it for browsers whose ``CefBrowser/Configuration/rendering`` is
/// `.offscreen`. Chromium creates the browser once the view is in a window.
/// The view never closes its browser: call ``CefBrowser/close(force:)`` when
/// you are done with it.
///
/// ```swift
/// var configuration = CefBrowser.Configuration()
/// configuration.rendering = .offscreen
/// let browser = CefBrowser(url: URL(string: "https://example.com")!, configuration: configuration)
/// window.contentView = CefOffscreenBrowserView(browser: browser)
/// ```
///
/// `CefWebView` in CefSwiftUI hosts its offscreen browsers in this view.
@MainActor
public final class CefOffscreenBrowserView: NSView, CefOffscreenHost {

    /// The browser shown in this view. Assigning a browser that is already
    /// live moves it here from wherever it was shown before; assigning `nil`
    /// stops showing it. The browser assigned before, if still waiting for
    /// its profile or discarded, is not created here later.
    ///
    /// It becomes nil when the browser moves to another host or is
    /// withdrawn from this one (``CefOffscreenHost/offscreenDidStopHosting(_:)``):
    /// the view then sends it no input, geometry or accessibility
    /// requests, and does not host it again when it returns to a window.
    public var browser: CefBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            browserDidChange(from: oldValue, keepingFrame: isKeepingFrame)
        }
    }
    /// Set while the browser leaves for another host and the view keeps
    /// its last frame (``keepsLastFrameWhenMoved``).
    private var isKeepingFrame = false
    /// The browser whose frame the content layer shows.
    private weak var frameBrowser: CefBrowser?

    /// The page's accessibility elements.
    lazy var accessibilityBridge = CefOffscreenAccessibilityBridge(view: self)

    /// Whether ``tearDown()`` closes the browser. `CefWebView(url:)` sets
    /// this for the browser it owns.
    package var closesBrowserOnTeardown = false
    private var isTornDown = false

    /// Displays the page.
    private let contentLayer = CALayer()
    /// Displays popup widgets such as an open `<select>`, above the page.
    private let popupLayer = CALayer()
    /// The surfaces each layer shows Chromium's frames in.
    private let contentCompositor = CefOffscreenCompositor()
    private let popupCompositor = CefOffscreenCompositor()

    /// The cursor the page last requested. AppKit resets the cursor as the
    /// mouse moves, so it is re-applied from `cursorUpdate(with:)`.
    private var currentCursor: NSCursor = .arrow

    /// Whether the browser was last told it is visible.
    private var isDisplaying = false

    private var windowObservers: [NSObjectProtocol] = []

    /// The fractional part of scroll deltas not yet sent. Chromium takes
    /// whole-point wheel deltas; carrying the remainder keeps slow trackpad
    /// scrolls smooth.
    var scrollResidual: CGPoint = .zero

    /// The most recent caret rect from IME composition bounds, in view
    /// coordinates. Kept after the composition ends so the candidate window,
    /// emoji palette and accent popup stay anchored at the caret.
    var lastKnownCaretRect: CGRect?
    var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    var currentSelectedTextRange = NSRange(location: NSNotFound, length: 0)

    /// Text input gathered while `interpretKeyEvents(_:)` runs inside
    /// `keyDown(with:)`. The `NSTextInputClient` methods only record into
    /// this; `keyDown` then decides whether the keystroke goes to Chromium
    /// as a key event (so the page sees `keydown`/`keypress`) or as IME text.
    struct KeyInputState {
        var handlingKeyDown = false
        var textToBeInserted = ""
        var hasMarkedTextFlag = false
        var oldHasMarkedText = false
        var markedTextValue = ""
        var markedSelectionRange = NSRange(location: NSNotFound, length: 0)
        var setMarkedReplacement: NSRange?
        var unmarkTextCalled = false
    }
    var keyInput = KeyInputState()

    /// The operations allowed for the page-initiated drag in progress.
    var currentDragAllowedOperations: CefDragOperation = .none

    // MARK: Geometry

    /// When the page lays out again while the view's size changes.
    public enum ResizePolicy: Sendable, Hashable {
        /// The page lays out at every size the view takes, at most once
        /// per pass of the main run loop: during an animation, once per
        /// display refresh. Its frames trail the view by a frame or two,
        /// shown meanwhile as ``framePlacement`` places them.
        case live
        /// While the size keeps changing, the page keeps its layout and
        /// its last frame is placed in the view by ``framePlacement``; it
        /// lays out again once the size has been still for a few display
        /// refreshes, and at most four times a second until then. A size
        /// change on its own, not part of a run of them, applies at once.
        case scaleThenSettle
    }

    /// When the page lays out again while the view's size changes, as it
    /// does on every refresh of a SwiftUI or AppKit size animation and of a
    /// window's live resize. The default is ``ResizePolicy/live``, as a
    /// windowed browser and `WKWebView` behave.
    public var resizePolicy: ResizePolicy = .live {
        didSet { if resizePolicy != oldValue { commitPageSize(force: false) } }
    }

    /// Where a frame whose size differs from the view's is drawn.
    public enum FramePlacement: Sendable, Hashable {
        /// Stretched to fill the view.
        case stretch
        /// Scaled to fit the view, keeping its aspect ratio, and centred.
        case aspectFit
        /// Scaled to fill the view, keeping its aspect ratio, centred and
        /// cropped.
        case aspectFill
        /// At its own size from the view's top-leading corner, cropped
        /// where it is larger and showing the view's background where it
        /// is smaller, as Safari keeps a page during a live resize.
        case topLeading
    }

    /// Where a frame whose size differs from the view's is drawn: a frame
    /// that has not caught up with a resize yet, one of a page laid out at
    /// ``pageSize``, or one kept by ``ResizePolicy/scaleThenSettle``. Input,
    /// the IME candidate window, popup widgets, context menus and
    /// accessibility frames follow the frame. The default is
    /// ``FramePlacement/stretch``.
    public var framePlacement: FramePlacement = .stretch {
        didSet { if framePlacement != oldValue { updateContentFrame() } }
    }

    /// The size the page lays out at, in points, or `nil` (the default) for
    /// the view's size. A page laid out at one size and shown at another,
    /// placed by ``framePlacement``, is a thumbnail or a live preview whose
    /// input still lands where it is clicked; set it to the size a view is
    /// animating to, with ``FramePlacement/topLeading``, to lay the page
    /// out once at its final size and reveal it as the view grows.
    public var pageSize: CGSize? {
        didSet {
            guard pageSize != oldValue else { return }
            commitPageSize(force: true)
        }
    }

    /// Whether the view goes on showing its last frame when its browser
    /// moves to another host, until it is given another browser. Off by
    /// default; `CefWebView` turns it on, so a page moving between two
    /// views in a SwiftUI transition does not leave a blank view behind
    /// while the old one animates out. The view sends the page nothing
    /// once the browser has moved.
    public var keepsLastFrameWhenMoved = false

    /// The size Chromium was last told, through
    /// ``CefOffscreenHost/offscreenViewInfo``.
    private var committedPageSize: CGSize = .zero
    /// The page size of the frame the content layer shows, in points.
    private var presentedFrameSize: CGSize?
    /// The popup widget's rect, in page points.
    private var popupPageRect: CGRect = .zero
    private var commitScheduled = false
    private var settleTimer: Timer?
    private var lastSizeChange: CFTimeInterval = 0
    private var lastCommit: CFTimeInterval = 0
    /// How long the size must stay still before ``ResizePolicy/scaleThenSettle``
    /// lays the page out, and how often it does while it does not.
    private static let settleDelay: CFTimeInterval = 0.05
    private static let settleInterval: CFTimeInterval = 0.25

    /// For SelfTest's `animation` benchmark: tell Chromium about every
    /// frame change at once, as an earlier design did, instead of once per
    /// run-loop pass.
    @_spi(Testing) public static var resizesOnEveryFrameChange = false
    /// For SelfTest: called with each frame's size in pixels as it becomes
    /// the content layer's contents, and the part the page fills when
    /// Chromium letterboxed it.
    @_spi(Testing) public var didPresentFrame: ((CGSize, CGRect?) -> Void)?
    /// For SelfTest: the content layer's frame, in view points.
    @_spi(Testing) public var contentFrame: CGRect { contentLayer.frame }
    /// For SelfTest: the page point a point in the window falls on, and
    /// the page size of the frame shown.
    @_spi(Testing) public func testingPagePoint(fromWindow point: NSPoint) -> (point: CGPoint, frameSize: CGSize) {
        (pagePoint(fromWindow: point), shownPageSize)
    }

    // MARK: Initialization

    /// Creates a view showing `browser`, whose
    /// ``CefBrowser/Configuration/rendering`` must be `.offscreen`.
    public init(browser: CefBrowser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = CALayer()
        // The canvas until Chromium's first frame, and behind see-through
        // pages; Chromium paints its own.
        root.backgroundColor = browser.hostBackgroundColor
        contentLayer.contentsGravity = .resize
        popupLayer.contentsGravity = .resize
        popupLayer.isHidden = true
        root.addSublayer(contentLayer)
        root.addSublayer(popupLayer)
        layer = root

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil))
        allowedTouchTypes = [.indirect]
        registerDragTypes()
        for compositor in [contentCompositor, popupCompositor] {
            compositor.requestFrame = { [weak self] in self?.browser?.setNeedsDisplay() }
        }
        browserDidChange(from: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func browserDidChange(from oldValue: CefBrowser?, keepingFrame: Bool = false) {
        // It stops painting here, and one still waiting for its profile,
        // or discarded, is not created here later.
        oldValue?.stopHosting(in: self)
        // A live page moving here from another view shows that view's last
        // frame until it paints here, instead of a blank view.
        let adopted = browser.flatMap { browser in
            (browser.hostView as? CefOffscreenBrowserView).flatMap { $0 !== self ? $0.shownFrame : nil }
        }
        // The compositor never writes into a surface it no longer holds,
        // so a frame kept on screen stays as it is, and the next frame is
        // copied whole.
        contentCompositor.reset()
        popupCompositor.reset()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if oldValue != nil || browser !== frameBrowser {
            popupLayer.contents = nil
            popupLayer.isHidden = true
            toolTip = nil
        }
        if let adopted {
            contentLayer.contents = adopted.contents
            contentLayer.contentsRect = adopted.contentsRect
            presentedFrameSize = adopted.size
            frameBrowser = browser
        } else if !keepingFrame, browser !== frameBrowser || oldValue != nil {
            // Nothing of the last page stays up.
            contentLayer.contents = nil
            contentLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            presentedFrameSize = nil
            frameBrowser = nil
        }
        CATransaction.commit()
        updateContentFrame()
        if let browser { layer?.backgroundColor = browser.hostBackgroundColor }
        hostBrowserIfPossible()
        updateVisibility(notifyingBrowser: true)
        accessibilityBridge.browserDidChange()
    }

    /// The frame the content layer shows and its page size, for a view the
    /// browser moves to.
    private var shownFrame: (contents: Any, size: CGSize, contentsRect: CGRect)? {
        guard let contents = contentLayer.contents, let presentedFrameSize else { return nil }
        return (contents, presentedFrameSize, contentLayer.contentsRect)
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    // MARK: Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if window != nil {
            hostBrowserIfPossible()
            updateScale()
            installWindowObservers()
        } else {
            // Back in a window, the view asks again.
            browser?.cancelDeferredCreation(in: self)
        }
        updateVisibility(notifyingBrowser: window != nil)
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibility()
    }

    // AppKit calls this on every display refresh of a SwiftUI
    // `scaleEffect` or `rotationEffect`, without a change of scale or
    // screen; Chromium hears only of real changes.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale(onlyIfChanged: true)
    }

    public override func layout() {
        super.layout()
        geometryDidChange()
    }

    // SwiftUI and AppKit animate a view's size by setting its frame on
    // every display refresh, several times per refresh, on the main
    // thread. Resizing the content layer here, without animation, keeps
    // the last frame over the view until Chromium paints at the new size.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometryDidChange()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        geometryDidChange()
        commitPageSize(force: true)
        browser?.setNeedsDisplay()
    }

    private func updateScale(onlyIfChanged: Bool = false) {
        guard let window else { return }
        let scale = window.backingScaleFactor
        let screen = window.screen.map(ObjectIdentifier.init)
        guard !onlyIfChanged || scale != lastBackingScale || screen != lastScreen else { return }
        lastBackingScale = scale
        lastScreen = screen
        contentLayer.contentsScale = scale
        popupLayer.contentsScale = scale
        browser?.hostViewDidChangeBackingProperties()
        commitPageSize(force: true)
    }
    private var lastBackingScale: CGFloat = 0
    private var lastScreen: ObjectIdentifier?

    private func hostBrowserIfPossible() {
        guard !isTornDown, window != nil, let browser else { return }
        let size = targetPageSize
        committedPageSize = size
        browser.host(offscreenIn: self, size: size == .zero ? CGSize(width: 800, height: 600) : size)
    }

    // MARK: Page geometry

    /// The size the page should lay out at.
    private var targetPageSize: CGSize { pageSize ?? bounds.size }

    /// The view's size changed: place the frame, and tell Chromium as the
    /// resize policy says.
    private func geometryDidChange() {
        updateContentFrame()
        guard targetPageSize != committedPageSize else { return }
        if Self.resizesOnEveryFrameChange {
            commitPageSize(force: true)
            return
        }
        switch resizePolicy {
        case .live:
            // Once per pass of the run loop, after its last frame change:
            // SwiftUI sets a frame several times per display refresh.
            guard !commitScheduled else { return }
            commitScheduled = true
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.commitScheduled = false
                    self.commitPageSize(force: false)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        case .scaleThenSettle:
            let now = CACurrentMediaTime()
            let isAlone = settleTimer == nil && now - lastSizeChange > Self.settleDelay
            lastSizeChange = now
            if isAlone { commitPageSize(force: false) }
            startSettleTimer()
        }
    }

    /// Checks on every display refresh whether the size has settled.
    private func startSettleTimer() {
        guard settleTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func settleTimerFired() {
        let now = CACurrentMediaTime()
        if now - lastSizeChange >= Self.settleDelay {
            settleTimer?.invalidate()
            settleTimer = nil
            commitPageSize(force: false)
        } else if now - lastCommit >= Self.settleInterval {
            commitPageSize(force: false)
        }
    }

    /// Tells Chromium the page's size, if it changed or `force` is set.
    private func commitPageSize(force: Bool) {
        let size = targetPageSize
        guard force || size != committedPageSize else { return }
        committedPageSize = size
        lastCommit = CACurrentMediaTime()
        browser?.hostViewDidResize()
    }

    /// Places the content and popup layers for the frame shown.
    private func updateContentFrame() {
        let frame = Self.rect(placing: presentedFrameSize ?? targetPageSize, in: bounds, framePlacement)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if contentLayer.frame != frame { contentLayer.frame = frame }
        // A frame placed larger than the view is cropped to it; otherwise
        // a popup widget may reach past the view, as Chromium places it.
        let crops = !bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
        if layer?.masksToBounds != crops { layer?.masksToBounds = crops }
        let popup = viewRect(fromPage: popupPageRect)
        if popupLayer.frame != popup { popupLayer.frame = popup }
        CATransaction.commit()
    }

    /// Where a frame of page size `size` is drawn in `bounds`.
    static func rect(placing size: CGSize, in bounds: CGRect, _ placement: FramePlacement) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        switch placement {
        case .stretch:
            return bounds
        case .topLeading:
            return CGRect(origin: bounds.origin, size: size)
        case .aspectFit, .aspectFill:
            let x = bounds.width / size.width, y = bounds.height / size.height
            let scale = placement == .aspectFit ? min(x, y) : max(x, y)
            let width = size.width * scale, height = size.height * scale
            return CGRect(
                x: bounds.minX + (bounds.width - width) / 2, y: bounds.minY + (bounds.height - height) / 2,
                width: width, height: height)
        }
    }

    /// The page size of the frame shown, or the size the page lays out at.
    private var shownPageSize: CGSize { presentedFrameSize ?? committedPageSize }

    /// A point in page points (top-left origin), in view coordinates.
    func viewPoint(fromPage point: CGPoint) -> CGPoint {
        let size = shownPageSize, frame = contentLayer.frame
        guard size.width > 0, size.height > 0 else { return point }
        return CGPoint(
            x: frame.minX + point.x * frame.width / size.width,
            y: frame.minY + point.y * frame.height / size.height)
    }

    /// A point in view coordinates, in page points.
    func pagePoint(fromView point: CGPoint) -> CGPoint {
        let size = shownPageSize, frame = contentLayer.frame
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return point }
        return CGPoint(
            x: (point.x - frame.minX) * size.width / frame.width,
            y: (point.y - frame.minY) * size.height / frame.height)
    }

    /// A rect in page points, in view coordinates.
    func viewRect(fromPage rect: CGRect) -> CGRect {
        guard !rect.isNull else { return rect }
        let origin = viewPoint(fromPage: rect.origin)
        let corner = viewPoint(fromPage: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    /// The window's root view, when a layer between it and this view has
    /// a transform: SwiftUI's `scaleEffect`, `rotationEffect` and
    /// `rotation3DEffect`, or a transform an app sets on a layer. Points
    /// are then converted through the layers, which apply transforms,
    /// rather than through the views, which on some macOS releases do not
    /// and never apply a 3D one.
    private var transformedRoot: NSView? {
        guard let window, let layer, let root = window.contentView?.superview ?? window.contentView,
              let rootLayer = root.layer
        else { return nil }
        var transformed = false
        var current: CALayer? = layer
        while let each = current, each !== rootLayer {
            if !CATransform3DIsIdentity(each.transform) || !CATransform3DIsIdentity(each.sublayerTransform) {
                transformed = true
            }
            current = each.superlayer
        }
        // Only within the window's own layer tree.
        return transformed && current === rootLayer ? root : nil
    }

    /// A point in the window's base coordinates, in view coordinates,
    /// through any transform the view is shown with.
    func viewPoint(fromWindow point: NSPoint) -> CGPoint {
        guard let root = transformedRoot, let rootLayer = root.layer, let layer else {
            return convert(point, from: nil)
        }
        var inRoot = root.convert(point, from: nil)
        if rootLayer.contentsAreFlipped() != root.isFlipped { inRoot.y = root.bounds.height - inRoot.y }
        var inView = layer.convert(inRoot, from: rootLayer)
        if layer.contentsAreFlipped() != isFlipped { inView.y = bounds.height - inView.y }
        return inView
    }

    /// A point in view coordinates, in the window's base coordinates,
    /// through any transform the view is shown with.
    func windowPoint(fromView point: CGPoint) -> NSPoint {
        guard let root = transformedRoot, let rootLayer = root.layer, let layer else {
            return convert(point, to: nil)
        }
        var inLayer = point
        if layer.contentsAreFlipped() != isFlipped { inLayer.y = bounds.height - inLayer.y }
        var inRoot = rootLayer.convert(inLayer, from: layer)
        if rootLayer.contentsAreFlipped() != root.isFlipped { inRoot.y = root.bounds.height - inRoot.y }
        return root.convert(inRoot, to: nil)
    }

    /// A point in the window's base coordinates, in page points.
    func pagePoint(fromWindow point: NSPoint) -> CGPoint {
        pagePoint(fromView: viewPoint(fromWindow: point))
    }

    /// A rect in page points, in screen coordinates: the smallest rect
    /// around it as it is shown.
    func screenRect(fromPage rect: CGRect) -> NSRect {
        guard let window else { return .zero }
        let view = viewRect(fromPage: rect)
        let corners = [
            CGPoint(x: view.minX, y: view.minY), CGPoint(x: view.maxX, y: view.minY),
            CGPoint(x: view.minX, y: view.maxY), CGPoint(x: view.maxX, y: view.maxY),
        ].map { windowPoint(fromView: $0) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let inWindow = NSRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return window.convertToScreen(inWindow)
    }

    /// Under a 3D transform AppKit hit-tests the view's untransformed
    /// frame; the view claims only points it shows.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard transformedRoot != nil, let superview, !isHiddenOrHasHiddenAncestor else { return super.hitTest(point) }
        let inView = viewPoint(fromWindow: superview.convert(point, to: nil))
        return bounds.contains(inView) ? self : nil
    }

    /// Stops hosting for good: stops observing the window, closes the
    /// browser if ``closesBrowserOnTeardown`` is set, and clears ``browser``.
    package func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        removeWindowObservers()
        updateVisibility()
        if closesBrowserOnTeardown {
            browser?.close(force: true)
        }
        browser = nil
    }

    // MARK: Visibility

    private var canBeSeen: Bool {
        guard !isTornDown, !isHiddenOrHasHiddenAncestor, let window else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Tells the browser when whether the view can be seen changes — or
    /// regardless, when `notifyingBrowser` is set because the browser has
    /// just been hosted. A hidden browser stops painting.
    private func updateVisibility(notifyingBrowser: Bool = false) {
        let visible = canBeSeen
        guard visible != isDisplaying || notifyingBrowser else { return }
        isDisplaying = visible
        if !visible {
            // The last frame stays up; the spare copies are not needed
            // until Chromium paints again.
            contentCompositor.trim()
            popupCompositor.trim()
        }
        // A browser that has moved to another view is that view's to manage.
        if let browser, browser.hostView === self {
            if visible { browser.hostViewDidUnhide() } else { browser.hostViewDidHide() }
        }
    }

    // MARK: Window observation

    private func installWindowObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        // The page's focus follows the window's key state while this view
        // is first responder, so its caret and focus ring behave as in a
        // browser window.
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowKeyStateDidChange(isKey: true) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowKeyStateDidChange(isKey: false) }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            },
            // Pages read the window's position (window.screenX and the like).
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidMove() }
            },
        ]
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
    }

    private func windowDidMove() {
        guard let browser, browser.hostView === self else { return }
        browser.hostViewDidMove()
    }

    private func windowKeyStateDidChange(isKey: Bool) {
        // A drag or selection in progress loses its pointer with the window.
        if !isKey, NSEvent.pressedMouseButtons != 0, let browser, browser.hostView === self {
            browser.sendCaptureLostEvent()
        }
        guard window?.firstResponder === self else { return }
        if isKey { browser?.hostViewDidBecomeKey() } else { browser?.hostViewDidResignKey() }
    }

    // MARK: CefOffscreenHost

    /// The view, its window and its screen, as a windowed browser in the
    /// same window would report them.
    public var offscreenViewInfo: CefOffscreenViewInfo {
        var info = CefOffscreenViewInfo(
            size: Self.nonEmpty(committedPageSize == .zero ? targetPageSize : committedPageSize),
            deviceScaleFactor: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        guard let window, let screen = window.screen ?? NSScreen.main else { return info }
        // Chromium's screen coordinates have their origin at the top-left
        // corner of the primary display; AppKit's at its bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        func chromium(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        let onScreen = chromium(window.convertToScreen(convert(bounds, to: nil)))
        info.screenOrigin = onScreen.origin
        info.screenFrame = chromium(screen.frame)
        info.screenVisibleFrame = chromium(screen.visibleFrame)
        info.windowFrame = chromium(window.frame)
        // As Chromium reports a windowed browser's screen (ui/display/mac).
        info.screenColorDepth = screen.canRepresent(.p3) ? 30 : 24
        return info
    }

    private static func nonEmpty(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// For SelfTest's `compositor` benchmark: copy every frame whole, as an
    /// earlier design did, instead of only its damage.
    @_spi(Testing) public static var copiesWholeFrames: Bool {
        get { CefOffscreenCompositor.copiesWholeFrames }
        set { CefOffscreenCompositor.copiesWholeFrames = newValue }
    }

    public func offscreenDidPaint(_ frame: CefOffscreenFrame, element: CefOffscreenPaintElement) {
        let size: CGSize
        if case let .accelerated(_, frameSize) = frame { size = frameSize } else { size = .zero }
        offscreenDidPaint(frame, element: element, details: CefOffscreenPaintDetails(damage: CGRect(origin: .zero, size: size)))
    }

    public func offscreenDidPaint(_ frame: CefOffscreenFrame, element: CefOffscreenPaintElement, details: CefOffscreenPaintDetails) {
        let target = element == .popup ? popupLayer : contentLayer
        let contents: Any
        let pixels: CGSize
        switch frame {
        case let .accelerated(surface, _):
            pixels = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            // Chromium paints the next frames into the same few surfaces,
            // so the layer shows a copy the view owns, updated where the
            // frame changed.
            let compositor = element == .popup ? popupCompositor : contentCompositor
            guard let copy = compositor.copy(surface, damage: details.damage, sequence: details.sequence) else { return }
            contents = copy
        case let .cpu(buffer, width, height, _):
            // The buffer is only valid during this call; the image copies it.
            // Chromium's dimensions are checked before they size a copy.
            let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
            let (count, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
            guard width > 0, height > 0, !rowOverflow, !countOverflow,
                  let image = Self.bgraImage(
                      Data(bytes: buffer, count: count), width: width, height: height, bytesPerRow: bytesPerRow)
            else { return }
            contents = image
            pixels = CGSize(width: width, height: height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.contents = contents
        CATransaction.commit()
        guard element == .view else { return }
        frameBrowser = browser
        // A frame captured while a resize is in flight holds the page at
        // its old size, letterboxed in black: show only the page.
        let content = details.contentRect ?? CGRect(origin: .zero, size: pixels)
        let unit = CGRect(
            x: content.minX / pixels.width, y: content.minY / pixels.height,
            width: content.width / pixels.width, height: content.height / pixels.height)
        // The page's size in the frame: what Chromium captured, which it
        // scales into a surface of another size, as when the page lays out
        // larger than the view (`pageSize`).
        let scale = contentLayer.contentsScale > 0 ? contentLayer.contentsScale : 1
        let source = details.sourceSize ?? content.size
        let size = CGSize(width: source.width / scale, height: source.height / scale)
        if unit != contentLayer.contentsRect {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contentsRect = unit
            CATransaction.commit()
        }
        if size != presentedFrameSize {
            presentedFrameSize = size
            updateContentFrame()
        }
        didPresentFrame?(pixels, details.contentRect)
    }

    public func offscreenSnapshot() -> CGImage? {
        guard let frame = Self.image(of: contentLayer.contents) else { return nil }
        // The page alone, without a letterbox.
        let crop = CGRect(
            x: contentLayer.contentsRect.minX * CGFloat(frame.width), y: contentLayer.contentsRect.minY * CGFloat(frame.height),
            width: contentLayer.contentsRect.width * CGFloat(frame.width),
            height: contentLayer.contentsRect.height * CGFloat(frame.height)).integral
        let page = crop.size == CGSize(width: frame.width, height: frame.height) ? frame : frame.cropping(to: crop) ?? frame
        guard !popupLayer.isHidden, let popup = Self.image(of: popupLayer.contents),
              let context = CGContext(
                  data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: page.colorSpace ?? Self.sRGB, bitmapInfo: Self.bgraBitmapInfo.rawValue)
        else { return page }
        // Page points, origin at the top left, to image pixels, origin at
        // the bottom left.
        let scale = CGFloat(page.width) / max(shownPageSize.width, 1)
        let rect = popupPageRect
        context.draw(page, in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
        context.draw(popup, in: CGRect(
            x: rect.minX * scale, y: CGFloat(page.height) - rect.maxY * scale,
            width: rect.width * scale, height: rect.height * scale))
        return context.makeImage() ?? page
    }

    /// A layer's contents as an image: a CPU frame already is one; an
    /// IOSurface the compositor owns is copied out of it.
    private static func image(of contents: Any?) -> CGImage? {
        guard let contents else { return nil }
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return (contents as! CGImage) }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = contents as! IOSurfaceRef
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard IOSurfaceGetBytesPerElement(surface) == 4, width > 0, height > 0 else { return nil }
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        let space = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace).flatMap {
            CGColorSpace(propertyListPlist: $0 as CFPropertyList)
        } ?? sRGB
        return bgraImage(data, width: width, height: height, bytesPerRow: bytesPerRow, space: space)
    }

    /// Chromium's pixel format: BGRA, premultiplied.
    private static let bgraBitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An image of BGRA pixels in Chromium's format.
    private static func bgraImage(
        _ data: Data, width: Int, height: Int, bytesPerRow: Int, space: CGColorSpace = sRGB
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: bgraBitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func offscreenDidChangeCursor(_ cursor: CefCursorType) {
        currentCursor = NSCursor.cursor(for: cursor) ?? .arrow
        currentCursor.set()
        window?.invalidateCursorRects(for: self)
    }

    public override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    public func offscreenPopupDidChangeVisibility(_ visible: Bool) {
        popupLayer.isHidden = !visible
        if !visible {
            popupLayer.contents = nil
            popupCompositor.reset()
        }
    }

    public func offscreenPopupDidResize(_ rect: CGRect) {
        popupPageRect = rect
        updateContentFrame()
    }

    public func offscreenDidChangeCompositionRange(_ range: NSRange, characterBounds: [CGRect]) {
        if let first = characterBounds.first {
            lastKnownCaretRect = first
        }
    }

    public func offscreenDidChangeSelection(_ selectedText: String, selectedRange: NSRange) {
        currentSelectedTextRange = selectedRange
    }

    /// AppKit shows the page's tooltip as the view's own, where the mouse
    /// rests.
    public func offscreenDidChangeToolTip(_ toolTip: String?) {
        guard self.toolTip != toolTip else { return }
        self.toolTip = toolTip
    }

    public func offscreenDidStopHosting(_ browser: CefBrowser) {
        guard self.browser === browser else { return }
        // Moved to another host: keep the last frame if asked to.
        let keepingFrame = keepsLastFrameWhenMoved && browser.hostView != nil && browser.hostView !== self
        isKeepingFrame = keepingFrame
        defer { isKeepingFrame = false }
        self.browser = nil
    }

    /// An event's location in page points, which are Chromium's view
    /// coordinates (top-left origin): through any transform the view is
    /// shown with, and where ``framePlacement`` puts the frame.
    func pagePoint(for event: NSEvent) -> CGPoint {
        pagePoint(fromWindow: event.locationInWindow)
    }
}

// MARK: - Gestures

// Pinch and smart magnify change the page zoom (``CefBrowser/zoomLevel``),
// swipes navigate when ``CefBrowser/Configuration/allowsBackForwardNavigationGestures``
// is set, and raw trackpad touches reach the page only when
// ``CefBrowser/Configuration/forwardsRawTouchEvents`` is set.
extension CefOffscreenBrowserView {

    /// The zoom level a smart magnify toggles to; each level is a factor of
    /// 1.2, so this is about 1.6x.
    private static let smartMagnifyZoomLevel = 2.5

    public override func magnify(with event: NSEvent) {
        guard let browser else { return }
        // A magnification of 0.25 changes the zoom by one level.
        browser.zoomLevel += Double(event.magnification) * 4
    }

    public override func smartMagnify(with event: NSEvent) {
        guard let browser else { return }
        browser.zoomLevel = abs(browser.zoomLevel) < 0.01 ? Self.smartMagnifyZoomLevel : 0
    }

    /// Pages have no use for rotation; consume it rather than pass it on.
    public override func rotate(with event: NSEvent) {}

    /// The dedicated navigation swipe (three fingers, or as configured in
    /// System Settings).
    public override func swipe(with event: NSEvent) {
        browser?.handleNavigationSwipe(event)
    }

    /// Starts a two-finger history swipe; see
    /// `CefBrowser.beginHistorySwipeIfNeeded(with:)`.
    func beginHistorySwipeIfNeeded(with event: NSEvent) -> Bool {
        browser?.beginHistorySwipeIfNeeded(with: event) ?? false
    }

    public override func touchesBegan(with event: NSEvent) {
        forwardTouches(in: event, phase: .began, as: .began)
    }

    public override func touchesMoved(with event: NSEvent) {
        forwardTouches(in: event, phase: .moved, as: .moved)
    }

    public override func touchesEnded(with event: NSEvent) {
        forwardTouches(in: event, phase: .ended, as: .ended)
    }

    public override func touchesCancelled(with event: NSEvent) {
        forwardTouches(in: event, phase: .cancelled, as: .cancelled)
    }

    private func forwardTouches(in event: NSEvent, phase: NSTouch.Phase, as touchPhase: CefTouchEvent.Phase) {
        guard let browser, browser.configuration.forwardsRawTouchEvents else { return }
        let size = shownPageSize
        for touch in event.touches(matching: phase, in: self) {
            // Trackpad touches have normalized, bottom-left positions.
            let position = touch.normalizedPosition
            let point = CGPoint(x: position.x * size.width, y: (1 - position.y) * size.height)
            browser.sendTouchEvent(CefTouchEvent(
                id: touch.identity.hash, location: point, phase: touchPhase, pressure: 1))
        }
    }
}
