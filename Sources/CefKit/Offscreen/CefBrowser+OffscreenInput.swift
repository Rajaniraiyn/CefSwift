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

// MARK: - Offscreen input

// Points are in view points with a top-left origin; `modifiers` is a
// `cef_event_flags_t` mask.
extension CefBrowser {

    // MARK: Mouse

    /// Forwards a mouse move, or the mouse leaving the view when `leaving`
    /// is `true`.
    public func sendMouseMove(to point: CGPoint, modifiers: UInt32, leaving: Bool = false) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_move_event(host, &event, leaving ? 1 : 0)
        }
    }

    /// Forwards a mouse button press.
    public func sendMouseDown(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_click_event(host, &event, button.cefValue, 0, Int32(clickCount))
        }
    }

    /// Forwards a mouse button release.
    public func sendMouseUp(at point: CGPoint, button: CefMouseButton, clickCount: Int, modifiers: UInt32) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_click_event(host, &event, button.cefValue, 1, Int32(clickCount))
        }
    }

    /// Forwards a scroll. Deltas are in points.
    public func sendMouseWheel(at point: CGPoint, deltaX: CGFloat, deltaY: CGFloat, modifiers: UInt32) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.send_mouse_wheel_event(host, &event, Int32(deltaX.rounded()), Int32(deltaY.rounded()))
        }
    }

    // MARK: Keyboard

    /// Forwards a key event.
    public func sendKeyEvent(_ event: cef_key_event_t) {
        withHost { host in
            var event = event
            host.pointee.send_key_event(host, &event)
        }
    }

    // MARK: Focus

    /// Gives the page keyboard focus or takes it away.
    public func setFocus(_ focused: Bool) {
        withHost { $0.pointee.set_focus($0, focused ? 1 : 0) }
    }

    // MARK: Geometry

    /// Tells Chromium the view size changed, so it reads
    /// ``CefOffscreenHost/offscreenViewInfo`` and repaints.
    public func wasResized() {
        withHost { $0.pointee.was_resized($0) }
    }

    /// Tells Chromium the scale factor or screen changed.
    public func notifyScreenInfoChanged() {
        withHost { $0.pointee.notify_screen_info_changed($0) }
    }

    /// Tells Chromium whether the view is hidden. Hidden browsers stop painting.
    public func wasHidden(_ hidden: Bool) {
        withHost { $0.pointee.was_hidden($0, hidden ? 1 : 0) }
    }

    /// Repaints the whole view.
    public func invalidate() {
        withHost { $0.pointee.invalidate($0, PET_VIEW) }
    }

    /// Asks Chromium for a frame. Offscreen browsers are created with
    /// external begin frames, so the host calls this on every display
    /// refresh.
    public func sendExternalBeginFrame() {
        withHost { $0.pointee.send_external_begin_frame($0) }
    }

    // MARK: IME

    /// Starts or updates an IME composition, as from
    /// `NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)`.
    public func imeSetComposition(text: String, selectionRange: NSRange, replacementRange: NSRange?) {
        withHost { host in
            CefStringUtil.withCefString(text) { cefText in
                var selection = cef_range_t(selectionRange)
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

    /// Commits text, as from `NSTextInputClient.insertText(_:replacementRange:)`.
    public func imeCommitText(_ text: String, replacementRange: NSRange?) {
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

    /// Commits the current composition.
    public func imeFinishComposing(keepSelection: Bool = true) {
        withHost { $0.pointee.ime_finish_composing_text($0, keepSelection ? 1 : 0) }
    }

    /// Discards the current composition.
    public func imeCancelComposition() {
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
