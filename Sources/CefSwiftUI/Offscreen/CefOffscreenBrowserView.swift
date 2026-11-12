import AppKit
import CefKit
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
/// `CefWebView` uses this for browsers whose ``CefBrowserOptions/rendering``
/// is `.offscreen`; use it directly in AppKit by assigning ``browser``.
@MainActor
public final class CefOffscreenBrowserView: NSView, CefOffscreenHost {

    /// The browser shown in this view. Assigning a browser that is already
    /// live moves it here from wherever it was shown before.
    public var browser: CefBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            if let oldValue, oldValue.hostView === self {
                oldValue.hostViewDidHide()
            }
            hostBrowserIfPossible()
            updateVisibility(notifyingBrowser: true)
            accessibilityBridge.browserDidChange()
            gestureIndicator = updatedGestureIndicator(gestureIndicator, browser: browser, isAllowed: showsBuiltInGestureIndicator)
        }
    }

    /// The page's accessibility elements.
    lazy var accessibilityBridge = CefOffscreenAccessibilityBridge(view: self)

    /// Whether the view draws the built-in swipe indicator that
    /// ``CefBrowserOptions/navigationGestureIndicator`` chooses. `CefWebView`
    /// turns it off for an indicator of the app's own.
    public var showsBuiltInGestureIndicator = true {
        didSet {
            gestureIndicator = updatedGestureIndicator(gestureIndicator, browser: browser, isAllowed: showsBuiltInGestureIndicator)
        }
    }

    private var gestureIndicator: CefNavigationGestureIndicatorView?

    /// Whether dismantling the view closes its browser. `CefWebView(url:)`
    /// sets this for the browser it owns.
    var closesBrowserOnTeardown = false
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

    /// The completion of the context menu being shown.
    var pendingContextMenuCompletion: CefContextMenuCompletion?

    /// The operations allowed for the page-initiated drag in progress.
    var currentDragAllowedOperations: CefDragOperation = .none

    // MARK: Initialization

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = CALayer()
        root.backgroundColor = NSColor.white.cgColor
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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

    func tearDown() {
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

    public func offscreenDidPaint(_ frame: CefOffscreenFrame, element: CefOffscreenPaintElement) {
        let target = element == .popup ? popupLayer : contentLayer
        let contents: Any
        switch frame {
        case let .accelerated(surface, _):
            // Chromium paints the next frames into the same few surfaces,
            // so the layer shows a copy the view owns.
            guard let copy = (element == .popup ? popupCompositor : contentCompositor).copy(surface) else { return }
            contents = copy
        case let .cpu(buffer, width, height, _):
            // The buffer is only valid during this call; the image copies it.
            let bytesPerRow = width * 4
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(bytes: buffer, count: bytesPerRow * height) as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            contents = image
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.contents = contents
        CATransaction.commit()
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

    /// An event's location in view coordinates, which are Chromium's: the
    /// view is flipped, so the origin is at the top left.
    func viewPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}

// MARK: - Gestures

// Pinch and smart magnify change the page zoom (``CefBrowser/zoomLevel``),
// swipes navigate when ``CefBrowserOptions/allowsBackForwardNavigationGestures``
// is set, and raw trackpad touches reach the page only when
// ``CefBrowserOptions/forwardsRawTouchEvents`` is set.
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
        guard let browser, browser.options.forwardsRawTouchEvents else { return }
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

// MARK: - Text input

// Dead keys, accents and input methods reach the page through
// `NSTextInputClient`. During `keyDown(with:)` these methods only record what
// AppKit asked for; see `keyInput`.
extension CefOffscreenBrowserView: @preconcurrency NSTextInputClient {

    private static func plainText(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    private static func optionalRange(_ range: NSRange) -> NSRange? {
        range.location == NSNotFound ? nil : range
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(string)
        guard !text.isEmpty else { return }
        if keyInput.handlingKeyDown {
            keyInput.textToBeInserted += text
        } else {
            browser?.insertText(text, replacementRange: Self.optionalRange(replacementRange))
        }
        keyInput.hasMarkedTextFlag = false
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainText(string)
        keyInput.markedSelectionRange = selectedRange
        keyInput.markedTextValue = text
        keyInput.hasMarkedTextFlag = !text.isEmpty
        currentMarkedRange = keyInput.hasMarkedTextFlag
            ? NSRange(location: 0, length: text.utf16.count)
            : NSRange(location: NSNotFound, length: 0)
        let replacement = Self.optionalRange(replacementRange)
        if keyInput.handlingKeyDown {
            keyInput.setMarkedReplacement = replacement
        } else if text.isEmpty {
            browser?.cancelComposition()
        } else {
            browser?.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacement)
        }
    }

    public func unmarkText() {
        keyInput.hasMarkedTextFlag = false
        keyInput.markedTextValue = ""
        if keyInput.handlingKeyDown {
            keyInput.unmarkTextCalled = true
        } else {
            browser?.unmarkText(keepingSelection: true)
        }
    }

    public func selectedRange() -> NSRange {
        currentSelectedTextRange
    }

    public func markedRange() -> NSRange {
        currentMarkedRange
    }

    public func hasMarkedText() -> Bool {
        currentMarkedRange.location != NSNotFound && currentMarkedRange.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// The screen rect below which the candidate window, the emoji palette
    /// and the accent popup appear.
    ///
    /// Chromium reports the caret only during a composition, so this uses the
    /// last composition's caret, or the view's top-left corner if there has
    /// been none.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let caret = lastKnownCaretRect ?? CGRect(x: 4, y: 4, width: 1, height: 16)
        let rect = NSRect(x: caret.minX, y: caret.maxY, width: max(caret.width, 1), height: max(caret.height, 1))
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}

// MARK: - Context menu

extension CefOffscreenBrowserView {

    public func offscreenShowContextMenu(_ menu: CefMenuModel, at point: CGPoint, completion: CefContextMenuCompletion) {
        // Chromium does not allow a nested run loop inside this callback, so
        // the menu is read now and shown on the next turn of the run loop.
        let menuItems: [NSMenuItem] = (0..<menu.count).compactMap { index in
            if menu.isSeparator(at: index) { return .separator() }
            let title = Self.menuTitle(fromCefTitle: menu.title(at: index))
            guard !title.isEmpty else { return nil }
            let item = NSMenuItem(title: title, action: #selector(contextMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menu.commandID(at: index)
            return item
        }
        guard !menuItems.isEmpty else {
            completion.cancel()
            return
        }

        pendingContextMenuCompletion = completion
        DispatchQueue.main.async { [weak self] in
            guard let self else { return completion.cancel() }
            let nsMenu = NSMenu()
            nsMenu.autoenablesItems = false
            nsMenu.items = menuItems
            nsMenu.popUp(positioning: nil, at: point, in: self)
            // `popUp` returns once the menu closes; an unanswered completion
            // means nothing was chosen.
            self.pendingContextMenuCompletion?.cancel()
            self.pendingContextMenuCompletion = nil
        }
    }

    /// Chromium marks mnemonics with `&` and writes a literal ampersand as `&&`.
    static func menuTitle(fromCefTitle title: String) -> String {
        title.components(separatedBy: "&&")
            .map { $0.replacingOccurrences(of: "&", with: "") }
            .joined(separator: "&")
    }

    @objc private func contextMenuItemSelected(_ sender: NSMenuItem) {
        pendingContextMenuCompletion?.select(commandID: sender.tag)
        pendingContextMenuCompletion = nil
    }
}
