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
    var currentImeSelectedRange = NSRange(location: NSNotFound, length: 0)
    var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    var currentSelectedText = ""
    var currentSelectedTextRange = NSRange(location: NSNotFound, length: 0)

    func clearMarked() {
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    }

    /// In-flight native context-menu callback (resolved by the menu action).
    var pendingContextMenuCallback: CefRunContextMenuCallback?

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
        popupLayer.isHidden = true
        root.addSublayer(contentLayer)
        root.addSublayer(popupLayer)
        layer = root
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
        if window == nil {
            stopDisplayLink()
            return
        }
        createBrowserIfPossible()
        updateScale()
        startDisplayLink()
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
        let browser = CefBrowserFactory.createOSRBrowser(
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

    public func osrDidPaint(_ frame: CefOSRFrame) {
        switch frame {
        case let .accelerated(surface, _):
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Setting an IOSurface as layer contents is the proven, correct
            // zero-copy path on macOS. CEF returns the surface to its pool
            // after this call, but CALayer takes its own reference to the
            // surface's contents for the current frame.
            if popupLayer.isHidden == false, popupRectDIP != .zero {
                // When a popup is showing, the same surface carries both; the
                // popup overlay is part of the OSR output for Alloy OSR.
            }
            contentLayer.contents = surface
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
                contentLayer.contents = image
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
