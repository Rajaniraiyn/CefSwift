import AppKit
import CCef
import Foundation

/// A mouse button, for forwarding clicks to an offscreen browser.
public enum CefMouseButton: Sendable {
    case left, middle, right

    var cefValue: cef_mouse_button_type_t {
        switch self {
        case .left: MBT_LEFT
        case .middle: MBT_MIDDLE
        case .right: MBT_RIGHT
        }
    }
}

/// A touch sent to an offscreen browser with ``CefBrowser/sendTouchEvent(_:)``.
public struct CefTouchEvent: Sendable, Equatable {
    /// Where the touch is in its sequence. A touch begins, moves zero or
    /// more times, then ends or is cancelled.
    public enum Phase: Sendable, Equatable {
        case began, moved, ended, cancelled

        var cefValue: cef_touch_event_type_t {
            switch self {
            case .began: CEF_TET_PRESSED
            case .moved: CEF_TET_MOVED
            case .ended: CEF_TET_RELEASED
            case .cancelled: CEF_TET_CANCELLED
            }
        }
    }

    /// The device producing the touch.
    public enum PointerType: Sendable, Equatable {
        case touch, mouse, pen, eraser, unknown

        var cefValue: cef_pointer_type_t {
            switch self {
            case .touch: CEF_POINTER_TYPE_TOUCH
            case .mouse: CEF_POINTER_TYPE_MOUSE
            case .pen: CEF_POINTER_TYPE_PEN
            case .eraser: CEF_POINTER_TYPE_ERASER
            case .unknown: CEF_POINTER_TYPE_UNKNOWN
            }
        }
    }

    /// Identifies the touch across its phases.
    public var id: Int
    /// The touch position in view points.
    public var location: CGPoint
    public var phase: Phase
    /// The touch's radii in view points, or zero when unknown.
    public var radius: CGSize
    /// The rotation of the touch ellipse in degrees, from 0 to 90.
    public var rotationAngle: Double
    /// The pressure, from 0 to 1, or 0 when unknown.
    public var pressure: Double
    public var modifiers: CefEventModifiers
    public var pointerType: PointerType

    public init(
        id: Int, location: CGPoint, phase: Phase,
        radius: CGSize = .zero, rotationAngle: Double = 0, pressure: Double = 0,
        modifiers: CefEventModifiers = [], pointerType: PointerType = .touch
    ) {
        self.id = id
        self.location = location
        self.phase = phase
        self.radius = radius
        self.rotationAngle = rotationAngle
        self.pressure = pressure
        self.modifiers = modifiers
        self.pointerType = pointerType
    }

    var cefValue: cef_touch_event_t {
        var event = cef_touch_event_t()
        event.id = Int32(truncatingIfNeeded: id)
        event.x = Float(location.x)
        event.y = Float(location.y)
        event.radius_x = Float(radius.width)
        event.radius_y = Float(radius.height)
        event.rotation_angle = Float(rotationAngle)
        event.pressure = Float(pressure)
        event.type = phase.cefValue
        event.modifiers = modifiers.rawValue
        event.pointer_type = pointerType.cefValue
        return event
    }
}

// MARK: - Offscreen input

// Points are in view points with a top-left origin.
extension CefBrowser {

    // MARK: Mouse

    /// Forwards a mouse move.
    public func sendMouseMove(to point: CGPoint, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_move_event(host, &event, 0)
        }
    }

    /// Forwards the mouse leaving the view at `point`.
    public func sendMouseExit(at point: CGPoint, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_move_event(host, &event, 1)
        }
    }

    /// Forwards a mouse button press.
    public func sendMouseDown(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_click_event(host, &event, button.cefValue, 0, Int32(clickCount))
        }
    }

    /// Forwards a mouse button release.
    public func sendMouseUp(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_click_event(host, &event, button.cefValue, 1, Int32(clickCount))
        }
    }

    /// Forwards a scroll at `point`. `delta` is in points, positive toward
    /// the top and left of the page, as `NSEvent.scrollingDeltaX/Y` report.
    public func sendScrollWheel(at point: CGPoint, delta: CGVector, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_wheel_event(host, &event, Int32(delta.dx.rounded()), Int32(delta.dy.rounded()))
        }
    }

    // MARK: Keyboard

    /// Forwards a key event.
    public func sendKeyEvent(_ event: CefKeyEvent) {
        withHost { host in
            var event = event.cefValue
            host.pointee.send_key_event(host, &event)
        }
    }

    /// Forwards a touch.
    public func sendTouchEvent(_ event: CefTouchEvent) {
        withHost { host in
            var event = event.cefValue
            host.pointee.send_touch_event(host, &event)
        }
    }

    // MARK: Hosting

    /// Tells Chromium the host view became the key view — first responder
    /// in the key window — so the page shows focus and takes keystrokes.
    public func hostViewDidBecomeKey() {
        withHost { $0.pointee.set_focus($0, 1) }
    }

    /// Tells Chromium the host view stopped being the key view.
    public func hostViewDidResignKey() {
        withHost { $0.pointee.set_focus($0, 0) }
    }

    /// Tells Chromium the host view's size changed, so it reads
    /// ``CefOffscreenHost/offscreenViewInfo`` and repaints.
    public func hostViewDidResize() {
        withHost { $0.pointee.was_resized($0) }
    }

    /// Tells Chromium the host view's scale factor or screen changed.
    public func hostViewDidChangeBackingProperties() {
        withHost { $0.pointee.notify_screen_info_changed($0) }
    }

    /// Tells Chromium the host view can no longer be seen — hidden,
    /// occluded or out of a window. Hidden browsers stop painting.
    public func hostViewDidHide() {
        withHost { $0.pointee.was_hidden($0, 1) }
    }

    /// Tells Chromium the host view can be seen again.
    public func hostViewDidUnhide() {
        withHost { $0.pointee.was_hidden($0, 0) }
    }

    /// Marks the whole view as needing to be repainted. The repaint arrives
    /// with the next frame (``displayIfNeeded()``).
    public func setNeedsDisplay() {
        withHost { $0.pointee.invalidate($0, PET_VIEW) }
    }

    /// Asks Chromium for a frame, which it paints if anything changed.
    /// Offscreen browsers are created with external begin frames, so the
    /// host view calls this on every display refresh while it can be seen.
    public func displayIfNeeded() {
        withHost { $0.pointee.send_external_begin_frame($0) }
    }

    // MARK: Text input

    /// Starts or updates the marked text of an input-method composition, as
    /// `NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)`
    /// does. `replacementRange` is a range of existing text to replace.
    public func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange? = nil) {
        withHost { host in
            CefStringUtil.withCefString(text) { cefText in
                var selection = cef_range_t(selectedRange)
                var underline = cef_composition_underline_t(
                    size: MemoryLayout<cef_composition_underline_t>.stride,
                    range: cef_range_t(from: 0, to: UInt32(text.utf16.count)),
                    color: 0xFF000000, background_color: 0, thick: 0, style: CEF_CUS_SOLID)
                if let replacementRange {
                    var replacement = cef_range_t(replacementRange)
                    host.pointee.ime_set_composition(host, cefText, 1, &underline, &replacement, &selection)
                } else {
                    host.pointee.ime_set_composition(host, cefText, 1, &underline, nil, &selection)
                }
            }
        }
    }

    /// Inserts text, completing any composition, as
    /// `NSTextInputClient.insertText(_:replacementRange:)` does.
    /// `replacementRange` is a range of existing text to replace.
    public func insertText(_ text: String, replacementRange: NSRange? = nil) {
        withHost { host in
            CefStringUtil.withCefString(text) { cefText in
                if let replacementRange {
                    var replacement = cef_range_t(replacementRange)
                    host.pointee.ime_commit_text(host, cefText, &replacement, 0)
                } else {
                    host.pointee.ime_commit_text(host, cefText, nil, 0)
                }
            }
        }
    }

    /// Accepts the marked text as it stands, as
    /// `NSTextInputClient.unmarkText()` does. Unless `keepingSelection` is
    /// set, the current selection, if any, is discarded.
    public func unmarkText(keepingSelection: Bool = true) {
        withHost { $0.pointee.ime_finish_composing_text($0, keepingSelection ? 1 : 0) }
    }

    /// Discards the marked text of the current composition.
    public func cancelComposition() {
        withHost { $0.pointee.ime_cancel_composition($0) }
    }

    // MARK: Accessibility

    /// Turns Chromium's accessibility tree on or off.
    public func setAccessibilityEnabled(_ enabled: Bool) {
        withHost { $0.pointee.set_accessibility_state($0, enabled ? STATE_ENABLED : STATE_DISABLED) }
    }
}

// MARK: - Editing

extension CefBrowser {
    /// Copies the selection to the clipboard.
    public func copySelection() { withEditingFrame { $0.pointee.copy($0) } }
    /// Cuts the selection to the clipboard.
    public func cutSelection() { withEditingFrame { $0.pointee.cut($0) } }
    /// Pastes the clipboard, keeping its formatting.
    public func paste() { withEditingFrame { $0.pointee.paste($0) } }
    /// Pastes the clipboard with the formatting of the destination.
    public func pasteAndMatchStyle() { withEditingFrame { $0.pointee.paste_and_match_style($0) } }
    /// Deletes the selection.
    public func deleteSelection() { withEditingFrame { $0.pointee.del($0) } }
    /// Selects all content.
    public func selectAll() { withEditingFrame { $0.pointee.select_all($0) } }
    /// Undoes the last edit.
    public func undo() { withEditingFrame { $0.pointee.undo($0) } }
    /// Redoes the last undone edit.
    public func redo() { withEditingFrame { $0.pointee.redo($0) } }

    /// Runs `body` with the focused frame, or the main frame when none has
    /// focus.
    private func withEditingFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw = raw?.pointer,
              let frame = raw.pointee.get_focused_frame(raw) ?? raw.pointee.get_main_frame(raw)
        else { return }
        defer { cefRelease(frame) }
        body(frame)
    }
}
