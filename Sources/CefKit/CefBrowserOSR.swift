import AppKit
import CCef
import Foundation

/// A mouse button for OSR input forwarding.
public enum CefMouseButton: Sendable {
    case left, middle, right

    var cefValue: cef_mouse_button_type_t {
        switch self {
        case .left: return MBT_LEFT
        case .middle: return MBT_MIDDLE
        case .right: return MBT_RIGHT
        }
    }
}

/// OSR host-input forwarding. These methods drive an offscreen browser created
/// via ``CefBrowserFactory/createOSRBrowser(initialSize:scale:url:options:host:delegate:)``.
/// All coordinates are in **view DIP** (points, top-left origin); the host view
/// is responsible for converting AppKit's bottom-left coordinates.
///
/// On windowed browsers these are no-ops in practice (CEF owns input), but they
/// are safe to call (the host pointer methods simply route through CEF).
extension CefBrowser {

    /// Whether this browser was created in offscreen-rendering mode.
    public var isOffscreen: Bool { client?.osrHost != nil }

    // MARK: Mouse

    private func mouseEvent(at point: CGPoint, modifiers: UInt32) -> cef_mouse_event_t {
        cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers)
    }

    /// Forwards a mouse-move (or mouse-leave when `leaving` is true).
    public func sendMouseMove(to point: CGPoint, modifiers: UInt32, leaving: Bool = false) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_move_event?(host, &event, leaving ? 1 : 0)
        }
    }

    /// Forwards a mouse button press.
    public func sendMouseDown(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_click_event?(host, &event, button.cefValue, 0, Int32(clickCount))
        }
    }

    /// Forwards a mouse button release.
    public func sendMouseUp(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_click_event?(host, &event, button.cefValue, 1, Int32(clickCount))
        }
    }

    /// Forwards a scroll-wheel event. Deltas are in device-independent units.
    public func sendMouseWheel(at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, modifiers: UInt32) {
        withHostInternal { host in
            var event = mouseEvent(at: point, modifiers: modifiers)
            host.pointee.send_mouse_wheel_event?(host, &event, Int32(deltaX.rounded()), Int32(deltaY.rounded()))
        }
    }

    // MARK: Keyboard

    /// Forwards a raw CEF key event (built by the host view from `NSEvent`).
    public func sendKeyEvent(_ event: cef_key_event_t) {
        withHostInternal { host in
            var e = event
            host.pointee.send_key_event?(host, &e)
        }
    }

    // MARK: Focus

    /// Sets the browser's logical focus (call from `becomeFirstResponder` /
    /// `resignFirstResponder`).
    public func setFocus(_ focused: Bool) {
        withHostInternal { $0.pointee.set_focus?($0, focused ? 1 : 0) }
    }

    // MARK: Geometry

    /// Notifies CEF that the view size changed; CEF re-queries `get_view_rect`
    /// and repaints at the new size.
    public func wasResized() {
        withHostInternal { $0.pointee.was_resized?($0) }
    }

    /// Notifies CEF that the screen scale/geometry changed; CEF re-queries
    /// `get_screen_info` (drives retina correctness).
    public func notifyScreenInfoChanged() {
        withHostInternal { $0.pointee.notify_screen_info_changed?($0) }
    }

    /// Notifies CEF the view's visibility changed (pause painting when hidden).
    public func wasHidden(_ hidden: Bool) {
        withHostInternal { $0.pointee.was_hidden?($0, hidden ? 1 : 0) }
    }

    /// Forces a full repaint of the view.
    public func invalidate() {
        withHostInternal { $0.pointee.invalidate?($0, PET_VIEW) }
    }

    /// Requests one frame from CEF. Used when the browser is created with
    /// `external_begin_frame_enabled`: the host drives this each display tick
    /// (via `CADisplayLink`) so painting is paced to the real display refresh,
    /// giving vsync-smooth scrolling/animation instead of CEF's free-running
    /// internal timer.
    public func sendExternalBeginFrame() {
        withHostInternal { $0.pointee.send_external_begin_frame?($0) }
    }

    // MARK: IME

    /// Begins/updates an IME composition (bridged from `NSTextInputClient.setMarkedText`).
    public func imeSetComposition(text: String, selectionRange: NSRange, replacementRange: NSRange?) {
        withHostInternal { host in
            CefStringUtil.withCefString(text) { cefText in
                var sel = cef_range_t(from: UInt32(max(0, selectionRange.location)),
                                      to: UInt32(max(0, selectionRange.location + selectionRange.length)))
                var underline = cef_composition_underline_t(
                    size: MemoryLayout<cef_composition_underline_t>.stride,
                    range: cef_range_t(from: 0, to: UInt32(text.utf16.count)),
                    color: 0xFF000000, background_color: 0, thick: 0, style: CEF_CUS_SOLID)
                if let replacementRange {
                    var rep = cef_range_t(from: UInt32(max(0, replacementRange.location)),
                                          to: UInt32(max(0, replacementRange.location + replacementRange.length)))
                    host.pointee.ime_set_composition?(host, cefText, 1, &underline, &rep, &sel)
                } else {
                    host.pointee.ime_set_composition?(host, cefText, 1, &underline, nil, &sel)
                }
            }
        }
    }

    /// Commits IME text (bridged from `NSTextInputClient.insertText`).
    public func imeCommitText(_ text: String, replacementRange: NSRange?) {
        withHostInternal { host in
            CefStringUtil.withCefString(text) { cefText in
                if let replacementRange {
                    var rep = cef_range_t(from: UInt32(max(0, replacementRange.location)),
                                          to: UInt32(max(0, replacementRange.location + replacementRange.length)))
                    host.pointee.ime_commit_text?(host, cefText, &rep, 0)
                } else {
                    host.pointee.ime_commit_text?(host, cefText, nil, 0)
                }
            }
        }
    }

    /// Completes the current composition (keeping the selection).
    public func imeFinishComposing(keepSelection: Bool = true) {
        withHostInternal { $0.pointee.ime_finish_composing_text?($0, keepSelection ? 1 : 0) }
    }

    /// Cancels the current composition.
    public func imeCancelComposition() {
        withHostInternal { $0.pointee.ime_cancel_composition?($0) }
    }

    // MARK: Accessibility

    /// Enables or disables accessibility for this browser. When enabled, CEF
    /// builds the AX tree and delivers it via the accessibility handler.
    public func setAccessibilityEnabled(_ enabled: Bool) {
        withHostInternal { $0.pointee.set_accessibility_state?($0, enabled ? STATE_ENABLED : STATE_DISABLED) }
    }
}
