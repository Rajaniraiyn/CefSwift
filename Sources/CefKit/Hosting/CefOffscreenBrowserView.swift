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
            browserDidChange(from: oldValue)
        }
    }

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

    private func browserDidChange(from oldValue: CefBrowser?) {
        // It stops painting here, and one still waiting for its profile,
        // or discarded, is not created here later.
        oldValue?.stopHosting(in: self)
        if oldValue != nil {
            // Nothing of the last page stays up, and the next browser's
            // first frame is copied whole.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contents = nil
            popupLayer.contents = nil
            popupLayer.isHidden = true
            CATransaction.commit()
            contentCompositor.reset()
            popupCompositor.reset()
        }
        if let browser { layer?.backgroundColor = browser.hostBackgroundColor }
        hostBrowserIfPossible()
        updateVisibility(notifyingBrowser: true)
        accessibilityBridge.browserDidChange()
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

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    public override func layout() {
        super.layout()
        syncLayerGeometry()
        browser?.hostViewDidResize()
    }

    // Live resize calls this on every step. Resizing the content layer here,
    // without animation, keeps the last frame stretched over the whole view
    // until Chromium paints at the new size.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerGeometry()
        browser?.hostViewDidResize()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        syncLayerGeometry()
        browser?.hostViewDidResize()
        browser?.setNeedsDisplay()
    }

    private func syncLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    private func updateScale() {
        guard let scale = window?.backingScaleFactor else { return }
        contentLayer.contentsScale = scale
        popupLayer.contentsScale = scale
        browser?.hostViewDidChangeBackingProperties()
        browser?.hostViewDidResize()
    }

    private func hostBrowserIfPossible() {
        guard !isTornDown, window != nil, let browser else { return }
        browser.host(offscreenIn: self, size: bounds.size == .zero ? CGSize(width: 800, height: 600) : bounds.size)
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
        guard window?.firstResponder === self else { return }
        if isKey { browser?.hostViewDidBecomeKey() } else { browser?.hostViewDidResignKey() }
    }

    // MARK: CefOffscreenHost

    /// The view, its window and its screen, as a windowed browser in the
    /// same window would report them.
    public var offscreenViewInfo: CefOffscreenViewInfo {
        var info = CefOffscreenViewInfo(
            size: bounds.size == .zero ? CGSize(width: 1, height: 1) : bounds.size,
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
        switch frame {
        case let .accelerated(surface, _):
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
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.contents = contents
        CATransaction.commit()
    }

    public func offscreenSnapshot() -> CGImage? {
        guard let page = Self.image(of: contentLayer.contents) else { return nil }
        guard !popupLayer.isHidden, let popup = Self.image(of: popupLayer.contents), bounds.width > 0,
              let context = CGContext(
                  data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: page.colorSpace ?? Self.sRGB, bitmapInfo: Self.bgraBitmapInfo.rawValue)
        else { return page }
        // View points, origin at the top left, to image pixels, origin at
        // the bottom left.
        let scale = CGFloat(page.width) / bounds.width
        let rect = popupLayer.frame
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popupLayer.frame = rect
        CATransaction.commit()
    }

    public func offscreenDidChangeCompositionRange(_ range: NSRange, characterBounds: [CGRect]) {
        if let first = characterBounds.first {
            lastKnownCaretRect = first
        }
    }

    public func offscreenDidChangeSelection(_ selectedText: String, selectedRange: NSRange) {
        currentSelectedTextRange = selectedRange
    }

    public func offscreenDidStopHosting(_ browser: CefBrowser) {
        guard self.browser === browser else { return }
        self.browser = nil
    }

    /// An event's location in view coordinates, which are Chromium's: the
    /// view is flipped, so the origin is at the top left.
    func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
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
        let size = bounds.size
        for touch in event.touches(matching: phase, in: self) {
            // Trackpad touches have normalized, bottom-left positions.
            let position = touch.normalizedPosition
            let point = CGPoint(x: position.x * size.width, y: (1 - position.y) * size.height)
            browser.sendTouchEvent(CefTouchEvent(
                id: touch.identity.hash, location: point, phase: touchPhase, pressure: 1))
        }
    }
}
