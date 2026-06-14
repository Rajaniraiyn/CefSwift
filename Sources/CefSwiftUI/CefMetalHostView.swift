import AppKit
import CefKit
import CCef
import Foundation

/// The `NSView` that hosts an offscreen-rendered CEF browser: it owns a
/// `CALayer` whose `contents` is set to the shared `IOSurface` Chromium paints
/// each frame, forwards AppKit input (mouse/key/scroll/IME) to the browser, and
/// reports geometry/scale back to CEF so rendering is retina-correct.
///
/// This is the workhorse behind ``CefMetalWebView``. It is a genuine in-tree
/// subview, so native SwiftUI/AppKit content composites over and around it.
@MainActor
public final class CefMetalHostView: NSView, CefOSRHost {

    // MARK: Stored state

    weak var model: CefWebViewModel? {
        didSet {
            guard model !== oldValue else { return }
            if oldValue != nil { closeBrowser() }
            createBrowserIfPossible()
        }
    }

    /// The hosted offscreen browser, available once async creation completes.
    private(set) var browser: CefBrowser?
    private var isTornDown = false

    /// Layer that displays the IOSurface (the web pixels).
    private let contentLayer = CALayer()
    /// Layer for the `<select>`-style popup widget (composited above content).
    private let popupLayer = CALayer()
    private var popupRectDIP: CGRect = .zero

    /// Tracking area for mouse-move/enter/leave.
    private var trackingAreaRef: NSTrackingArea?

    /// Cursor the page last requested. Re-applied from `cursorUpdate(with:)`
    /// because AppKit resets the cursor on every mouse-move; a one-shot
    /// `NSCursor.set()` from `osrDidChangeCursor` alone would not stick.
    private var currentCursor: NSCursor = .arrow

    /// Drives `sendExternalBeginFrame()` once per display refresh so painting is
    /// vsync-paced (smooth scrolling). Started while the view is in a window.
    private var displayLink: CADisplayLink?

    /// Sub-pixel scroll-wheel remainder. CEF takes integer wheel deltas, so we
    /// carry the fractional part across events instead of rounding it away —
    /// otherwise slow trackpad scrolls lose sub-pixel motion and feel steppy.
    var scrollResidual: CGPoint = .zero

    /// Last reported character bounds for IME candidate placement.
    var currentImeCharacterBounds: [CGRect] = []
    /// Sticky copy of the most recent caret glyph rect (view DIP, top-left),
    /// so the emoji palette / accent popup can anchor at the caret even after a
    /// composition ends. See `firstRect(forCharacterRange:)`.
    var lastKnownCaretRectDIP: CGRect?
    var currentImeSelectedRange = NSRange(location: NSNotFound, length: 0)
    var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    var currentSelectedText = ""
    var currentSelectedTextRange = NSRange(location: NSNotFound, length: 0)

    // Deferred key-input state (mirrors cefclient's text_input_client_osr_mac):
    // during a `keyDown`, `interpretKeyEvents` only *accumulates* here; the
    // actual key/char/composition events are sent afterward, so normal typing
    // goes out as KEYEVENT_KEYDOWN+KEYEVENT_CHAR (firing JS key events) instead
    // of being silently committed as IME text.
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

    func clearMarked() {
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
        keyInput.hasMarkedTextFlag = false
        keyInput.markedTextValue = ""
    }

    /// In-flight native context-menu callback (resolved by the menu action).
    var pendingContextMenuCallback: CefRunContextMenuCallback?

    /// Allowed drag operations for an in-flight page-initiated (page→system)
    /// drag session. Set when `start_dragging` fires; consumed by the
    /// `NSDraggingSource` callbacks.
    var currentDragAllowedOps: CefDragOperation = .none

    /// Observers for window key-state changes (focus follows key window).
    private var windowKeyObservers: [NSObjectProtocol] = []

    // MARK: Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The view's own backing layer hosts the content + popup sublayers.
        let root = CALayer()
        root.backgroundColor = NSColor.white.cgColor
        contentLayer.contentsGravity = .resize
        contentLayer.frame = bounds
        popupLayer.contentsGravity = .resize
        popupLayer.isHidden = true
        root.addSublayer(contentLayer)
        root.addSublayer(popupLayer)
        layer = root
        // Receive indirect (trackpad) touches for raw-touch forwarding.
        allowedTouchTypes = [.indirect]
        // Accept system → page drags.
        registerDragTypes()
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
        removeWindowKeyObservers()
        if window == nil {
            stopDisplayLink()
            return
        }
        createBrowserIfPossible()
        updateScale()
        startDisplayLink()
        installWindowKeyObservers()
    }

    // MARK: Window key-state → CEF focus

    /// Mirror the window's key state into CEF focus while this view is the
    /// first responder, so tabbing/clicking between the app and other apps
    /// keeps the page's focus ring and caret in sync (matching a real browser).
    private func installWindowKeyObservers() {
        guard let window else { return }
        let nc = NotificationCenter.default
        let becomeKey = nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                self.browser?.setFocus(true)
            }
        }
        let resignKey = nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                self.browser?.setFocus(false)
            }
        }
        windowKeyObservers = [becomeKey, resignKey]
    }

    private func removeWindowKeyObservers() {
        for o in windowKeyObservers { NotificationCenter.default.removeObserver(o) }
        windowKeyObservers = []
    }

    // MARK: Display-link (external begin-frame pacing)

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        // macOS 14+ gives a window/display-matched CADisplayLink from the view.
        let link = displayLink(target: self, selector: #selector(stepBeginFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func stepBeginFrame() {
        browser?.sendExternalBeginFrame()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    public override func layout() {
        super.layout()
        syncLayerGeometry()
        browser?.wasResized()
        updateTrackingArea()
    }

    /// `setFrameSize` is invoked synchronously on every step of a live resize —
    /// keep the layers locked to the new bounds *immediately* (and without
    /// implicit animation) so the displayed frame never lags the view. Combined
    /// with `.resize` contents gravity (which stretches the last painted frame
    /// to fill) this removes the blank/garbage trails that appear when the layer
    /// grows ahead of CEF's next paint. `wasResized` then asks CEF to repaint at
    /// the new size; the CADisplayLink (running in `.common` modes, so it keeps
    /// firing during the resize event loop) delivers the new frames.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerGeometry()
        browser?.wasResized()
    }

    private func syncLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = bounds
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Snap a crisp, correctly-sized final frame after the user lets go.
        syncLayerGeometry()
        browser?.wasResized()
        browser?.invalidate()
    }

    private func updateScale() {
        guard let scale = window?.backingScaleFactor else { return }
        if layer?.contentsScale != scale {
            layer?.contentsScale = scale
            contentLayer.contentsScale = scale
            popupLayer.contentsScale = scale
        }
        browser?.notifyScreenInfoChanged()
        browser?.wasResized()
    }

    private func createBrowserIfPossible() {
        guard !isTornDown, window != nil, let model, browser == nil else { return }
        let url = model.url ?? URL(string: "about:blank")!
        let scale = window?.backingScaleFactor ?? 2.0
        let size = bounds.size == .zero ? CGSize(width: 800, height: 600) : bounds.size
        let browser = CefBrowser.createOSRBrowser(
            initialSize: size,
            scale: scale,
            url: url,
            options: model.options,
            host: self,
            delegate: model
        )
        self.browser = browser
        model.attach(browser)
        // Best-effort accessibility: enable the AX tree (see docs for status).
        browser.setAccessibilityEnabled(true)
    }

    private func closeBrowser() {
        guard let browser else { return }
        model?.detach()
        browser.close(force: true)
        self.browser = nil
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        stopDisplayLink()
        removeWindowKeyObservers()
        closeBrowser()
        model = nil
    }

    // MARK: CefOSRHost

    public var osrViewInfo: CefOSRViewInfo {
        let scale = window?.backingScaleFactor ?? 2.0
        var origin = CGPoint.zero
        var screenRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let window {
            // Convert view origin (top-left, flipped) to screen DIP top-left.
            let inWindow = convert(bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            if let screen = window.screen ?? NSScreen.main {
                let sf = screen.frame
                // AppKit screen coords are bottom-left; CEF wants top-left DIP.
                origin = CGPoint(x: onScreen.minX, y: sf.maxY - onScreen.maxY)
                screenRect = CGRect(x: 0, y: 0, width: sf.width, height: sf.height)
            }
        }
        return CefOSRViewInfo(
            sizeDIP: bounds.size == .zero ? CGSize(width: 1, height: 1) : bounds.size,
            deviceScaleFactor: scale,
            screenOriginDIP: origin,
            screenRectDIP: screenRect
        )
    }

    public func osrDidPaint(_ frame: CefOSRFrame, element: CefOSRPaintElement) {
        // PET_VIEW frames go to the content layer; PET_POPUP frames (the
        // `<select>` dropdown / autofill widget) go to the popup overlay layer
        // sized by on_popup_size and shown/hidden by on_popup_show.
        let target = (element == .popup) ? popupLayer : contentLayer
        switch frame {
        case let .accelerated(surface, _):
            // Setting an IOSurface as layer contents is the proven, correct
            // zero-copy path on macOS. CEF returns the surface to its pool
            // after this call, but CALayer takes its own reference to the
            // surface's contents for the current frame.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.contents = surface
            CATransaction.commit()
        case let .cpu(buffer, width, height, _):
            // CPU fallback: wrap BGRA bytes in a CGImage.
            let bytesPerRow = width * 4
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: bytesPerRow * height, releaseData: { _, _, _ in }) else { return }
            if let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                target.contents = image
                CATransaction.commit()
            }
        }
    }

    public func osrDidChangeCursor(_ cursor: CefCursorType) {
        currentCursor = cursor.nsCursor ?? .arrow
        // Apply immediately, and make AppKit re-apply it via cursorUpdate(_:)
        // on subsequent mouse-moves (otherwise it reverts to the arrow).
        currentCursor.set()
        window?.invalidateCursorRects(for: self)
    }

    public override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    public func osrPopupDidChangeVisibility(_ visible: Bool) {
        popupLayer.isHidden = !visible
        if !visible { popupRectDIP = .zero }
    }

    public func osrPopupDidResize(_ rect: CGRect) {
        popupRectDIP = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        popupLayer.frame = rect
        CATransaction.commit()
    }

    public func osrImeCompositionRangeChanged(selectedRange: NSRange, characterBounds: [CGRect]) {
        currentImeSelectedRange = selectedRange
        currentImeCharacterBounds = characterBounds
        if let first = characterBounds.first {
            lastKnownCaretRectDIP = first
        }
    }

    public func osrTextSelectionChanged(selectedText: String, selectedRange: NSRange) {
        currentSelectedText = selectedText
        currentSelectedTextRange = selectedRange
    }

    // MARK: Coordinate conversion (AppKit → CEF DIP)

    /// Converts an `NSEvent`'s location to view DIP (top-left origin). The view
    /// is flipped, so `convert(_:from:nil)` already yields top-left coords.
    func dipPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: Tracking area

    private func updateTrackingArea() {
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }
}

// MARK: - Gestures

/// Trackpad/Multi-Touch gesture forwarding for the OSR web view. These make an
/// embedded `CefMetalWebView` respond to pinch-zoom, smart-magnify, and
/// three-finger swipe navigation the way a real browser does.
///
/// ## Zoom approach
/// Pinch-zoom (`magnify(with:)`) drives Chromium's **page zoom** through the
/// browser host's `set_zoom_level`/`get_zoom_level` (exposed as
/// ``CefBrowser/zoomLevel``). We accumulate `event.magnification` into the
/// current zoom level. This is the faithful, header-supported route on macOS
/// (the ctrl+wheel alternative is coarser and fights the page's own wheel
/// handlers). `smartMagnify` toggles between 1:1 and a zoomed-in step.
///
/// ## Touch approach
/// Raw `NSTouch` forwarding to `send_touch_event` is gated behind
/// ``CefBrowserOptions/forwardsRawTouchEvents`` (default off) because indirect
/// trackpad touches are unreliable as a gesture source; the explicit gesture
/// overrides below are the robust path. When the flag is on we also forward
/// raw touches so Chromium's own recognizers can act.
extension CefMetalHostView {

    /// CEF zoom-level step that maps to ~1.25x per unit (Chromium's scale).
    private static let smartMagnifyStep: Double = 2.5

    // MARK: Pinch zoom

    public override func magnify(with event: NSEvent) {
        guard let browser = osrBrowser else { return }
        // event.magnification is an incremental scale delta (-1...1-ish per
        // event). Translate into a zoom-level delta; ~4 units of magnification
        // ≈ one Chromium zoom step, matching trackpad feel.
        let current = browser.zoomLevel
        browser.zoomLevel = current + Double(event.magnification) * 4.0
    }

    public override func smartMagnify(with event: NSEvent) {
        guard let browser = osrBrowser else { return }
        // Two-finger double-tap: toggle between default and a zoomed-in step.
        if abs(browser.zoomLevel) < 0.01 {
            browser.zoomLevel = CefMetalHostView.smartMagnifyStep
        } else {
            browser.zoomLevel = 0
        }
    }

    // MARK: Rotation

    public override func rotate(with event: NSEvent) {
        // OSR host input has no rotation channel (no rotate gesture in
        // cef_browser_host_t), and web pages don't consume native rotation
        // events. No-op rather than mismap it.
    }

    // MARK: Three-finger swipe → back/forward navigation

    public override func swipe(with event: NSEvent) {
        guard let browser = osrBrowser else { return }
        // deltaX > 0 is a right-to-left swipe → go back; < 0 → go forward.
        //
        // Gesture-vs-scroll conflict: AppKit only delivers `swipe(with:)` for
        // the dedicated 3-finger (or the user-configured 2-finger) navigation
        // gesture, which is mutually exclusive at the AppKit level with the
        // `scrollWheel(with:)` momentum stream — so our swipe-nav never
        // double-fires against a normal two-finger scroll. We deliberately make
        // this the single navigation path and do NOT also drive Chromium's
        // built-in horizontal-overscroll navigation from forwarded wheel
        // deltas, avoiding a double-navigation; see the OSR input docs.
        if event.deltaX > 0 {
            browser.goBack()
        } else if event.deltaX < 0 {
            browser.goForward()
        }
    }

    // MARK: Raw touch forwarding (opt-in)

    /// Whether the hosted browser opted into raw touch forwarding.
    private var forwardsRawTouches: Bool {
        model?.options.forwardsRawTouchEvents ?? false
    }

    public override func touchesBegan(with event: NSEvent) {
        forwardTouches(event, type: CEF_TET_PRESSED)
    }
    public override func touchesMoved(with event: NSEvent) {
        forwardTouches(event, type: CEF_TET_MOVED)
    }
    public override func touchesEnded(with event: NSEvent) {
        forwardTouches(event, type: CEF_TET_RELEASED)
    }
    public override func touchesCancelled(with event: NSEvent) {
        forwardTouches(event, type: CEF_TET_CANCELLED)
    }

    private func forwardTouches(_ event: NSEvent, type: cef_touch_event_type_t) {
        guard forwardsRawTouches, let browser = osrBrowser else { return }
        let phase: NSTouch.Phase
        switch type {
        case CEF_TET_PRESSED: phase = .began
        case CEF_TET_MOVED: phase = .moved
        case CEF_TET_RELEASED: phase = .ended
        default: phase = .cancelled
        }
        let touches = event.touches(matching: phase, in: self)
        let viewSize = bounds.size
        for touch in touches {
            // Indirect (trackpad) touches report normalized positions; map them
            // onto the view rect (top-left origin).
            let n = touch.normalizedPosition
            let point = CGPoint(x: n.x * viewSize.width, y: (1 - n.y) * viewSize.height)
            let id = Int32(truncatingIfNeeded: touch.identity.hash)
            browser.sendTouchEvent(id: id, point: point, type: type,
                                   pressure: 1.0, pointerType: CEF_POINTER_TYPE_TOUCH)
        }
    }
}

// MARK: - IME (NSTextInputClient)

/// `NSTextInputClient` bridge so dead-keys and CJK/IME composition route into
/// the offscreen browser via `imeSetComposition`/`imeCommitText`. AppKit calls
/// these as a result of `interpretKeyEvents(_:)` in `keyDown`.
extension CefMetalHostView: @preconcurrency NSTextInputClient {

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        if keyInput.handlingKeyDown {
            // Accumulate; keyDown's after-handler decides KEYDOWN+CHAR vs commit.
            keyInput.textToBeInserted += text
        } else {
            // Direct insert (e.g. IME candidate pick outside a keystroke).
            let range = replacementRange.location == NSNotFound ? nil : replacementRange
            osrBrowser?.imeCommitText(text, replacementRange: range)
        }
        // Inserting text always clears any marked composition.
        keyInput.hasMarkedTextFlag = false
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        keyInput.markedSelectionRange = selectedRange
        keyInput.markedTextValue = text
        keyInput.hasMarkedTextFlag = !text.isEmpty
        currentMarkedRange = keyInput.hasMarkedTextFlag
            ? NSRange(location: 0, length: text.utf16.count)
            : NSRange(location: NSNotFound, length: 0)
        let rep = replacementRange.location == NSNotFound ? nil : replacementRange
        if keyInput.handlingKeyDown {
            // Defer to the after-handler so it sequences with the key event.
            keyInput.setMarkedReplacement = rep
        } else {
            if text.isEmpty {
                osrBrowser?.imeCancelComposition()
            } else {
                osrBrowser?.imeSetComposition(text: text, selectionRange: selectedRange, replacementRange: rep)
            }
        }
    }

    public func unmarkText() {
        keyInput.hasMarkedTextFlag = false
        keyInput.markedTextValue = ""
        if keyInput.handlingKeyDown {
            keyInput.unmarkTextCalled = true
        } else {
            osrBrowser?.imeFinishComposing(keepSelection: true)
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

    /// Returns the screen rect (bottom-left origin) used to position the IME
    /// candidate window, the emoji & symbols palette (Cmd+Ctrl+Space), and the
    /// press-and-hold accent popup, anchored at the caret.
    ///
    /// Source of the caret rect, in order of fidelity:
    /// 1. **Live composition bounds** — during an active IME composition CEF
    ///    delivers exact per-character bounds via
    ///    `on_ime_composition_range_changed`; we use the first glyph's box.
    /// 2. **Last-known caret rect** — we cache (1) so that immediately after a
    ///    composition ends, and for the accent popup that fires on the next
    ///    key, the anchor stays at the real caret instead of snapping away.
    /// 3. **Focused-view fallback** — with no composition data at all (a plain
    ///    caret in an `<input>`), CEF's OSR API exposes no caret rect for a
    ///    non-composition selection, so we anchor near the top-left of the view
    ///    rather than at the screen origin. This is an honest limitation, not
    ///    pixel-perfect; see the OSR input docs.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return NSRect(origin: .zero, size: .zero) }
        if let bounds = currentImeCharacterBounds.first {
            lastKnownCaretRectDIP = bounds
        }
        let caret = lastKnownCaretRectDIP ?? CGRect(x: 4, y: 4, width: 1, height: 16)
        // Caret bounds are in view DIP (top-left). Build a view-coordinate rect
        // whose origin is the caret's bottom (palette appears just below the
        // glyph), then convert to window then screen (bottom-left).
        let viewRect = NSRect(x: caret.minX, y: caret.maxY,
                              width: max(caret.width, 1), height: max(caret.height, 1))
        let inWindow = convert(viewRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}

// MARK: - Context Menu

/// Presents CEF's context menu as a native `NSMenu` for the offscreen browser,
/// so right-click feels identical to a native control.
extension CefMetalHostView {

    public func osrRunContextMenu(_ menu: CefMenuModel, at viewPoint: CGPoint, callback: CefRunContextMenuCallback) {
        // IMPORTANT: CEF forbids running an OS modal message loop *inside* this
        // callback (only start_dragging may). So we snapshot the menu items
        // synchronously, then present the NSMenu on the next runloop tick and
        // resolve the callback then. We return having retained the callback.
        struct Item { let label: String; let commandID: Int; let isSeparator: Bool }
        var items: [Item] = []
        for i in 0..<menu.count {
            if menu.isSeparator(at: i) {
                items.append(Item(label: "", commandID: -1, isSeparator: true))
            } else {
                let label = menu.label(at: i).replacingOccurrences(of: "&", with: "")
                guard !label.isEmpty else { continue }
                items.append(Item(label: label, commandID: menu.commandID(at: i), isSeparator: false))
            }
        }
        guard !items.isEmpty else {
            callback.cancel()
            return
        }

        pendingContextMenuCallback = callback
        let location = NSPoint(x: viewPoint.x, y: viewPoint.y)

        DispatchQueue.main.async { [weak self] in
            guard let self else { callback.cancel(); return }
            let nsMenu = NSMenu()
            nsMenu.autoenablesItems = false
            for item in items {
                if item.isSeparator {
                    nsMenu.addItem(.separator())
                    continue
                }
                let mi = NSMenuItem(title: item.label, action: #selector(self.contextMenuItemSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = item.commandID
                nsMenu.addItem(mi)
            }
            nsMenu.popUp(positioning: nil, at: location, in: self)
            // popUp is modal; the action selector resolved the callback if an
            // item was chosen. Otherwise cancel.
            if let cb = self.pendingContextMenuCallback {
                cb.cancel()
                self.pendingContextMenuCallback = nil
            }
        }
    }

    @objc private func contextMenuItemSelected(_ sender: NSMenuItem) {
        guard let cb = pendingContextMenuCallback else { return }
        cb.select(commandID: sender.tag)
        pendingContextMenuCallback = nil
    }
}
