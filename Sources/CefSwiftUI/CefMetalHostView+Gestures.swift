import AppKit
import CefKit
import CCef
import Foundation

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
        // CONTRACT-DEVIATION: Chromium's OSR host input has no rotation channel
        // (no rotate gesture in cef_browser_host_t), and web pages don't consume
        // a native rotation event. No-op rather than mismap it.
    }

    // MARK: Three-finger swipe → back/forward navigation

    public override func swipe(with event: NSEvent) {
        guard let browser = osrBrowser else { return }
        // deltaX > 0 is a right-to-left swipe → go back; < 0 → go forward.
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
