import AppKit
import CefKit
import CCef
import Foundation

/// Maps AppKit input events onto the OSR browser's host-input methods. All
/// coordinates are converted to view DIP (top-left origin) before forwarding.
extension CefMetalHostView {

    // MARK: Modifier mapping

    /// Translates `NSEvent.ModifierFlags` (+ pressed mouse buttons) into CEF's
    /// `cef_event_flags_t` bitmask.
    static func cefModifiers(_ flags: NSEvent.ModifierFlags, pressedButtons: Int = 0) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) }
        if flags.contains(.control) { m |= UInt32(EVENTFLAG_CONTROL_DOWN.rawValue) }
        if flags.contains(.option) { m |= UInt32(EVENTFLAG_ALT_DOWN.rawValue) }
        if flags.contains(.command) { m |= UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) }
        if flags.contains(.capsLock) { m |= UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue) }
        if pressedButtons & (1 << 0) != 0 { m |= UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue) }
        if pressedButtons & (1 << 1) != 0 { m |= UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue) }
        if pressedButtons & (1 << 2) != 0 { m |= UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue) }
        return m
    }

    private var modifiers: UInt32 {
        CefMetalHostView.cefModifiers(NSEvent.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons)
    }

    var osrBrowser: CefBrowser? { browser }

    // MARK: Mouse

    public override func mouseMoved(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers)
    }
    public override func mouseDragged(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers)
    }
    public override func rightMouseDragged(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers)
    }
    public override func otherMouseDragged(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers)
    }
    public override func mouseExited(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers, leaving: true)
    }
    public override func mouseEntered(with event: NSEvent) {
        osrBrowser?.sendMouseMove(to: dipPoint(for: event), modifiers: modifiers)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        osrBrowser?.sendMouseDown(at: dipPoint(for: event), button: .left, clickCount: event.clickCount, modifiers: modifiers)
    }
    public override func mouseUp(with event: NSEvent) {
        osrBrowser?.sendMouseUp(at: dipPoint(for: event), button: .left, clickCount: event.clickCount, modifiers: modifiers)
    }
    public override func rightMouseDown(with event: NSEvent) {
        osrBrowser?.sendMouseDown(at: dipPoint(for: event), button: .right, clickCount: event.clickCount, modifiers: modifiers)
    }
    public override func rightMouseUp(with event: NSEvent) {
        osrBrowser?.sendMouseUp(at: dipPoint(for: event), button: .right, clickCount: event.clickCount, modifiers: modifiers)
    }
    public override func otherMouseDown(with event: NSEvent) {
        osrBrowser?.sendMouseDown(at: dipPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
    }
    public override func otherMouseUp(with event: NSEvent) {
        osrBrowser?.sendMouseUp(at: dipPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func scrollWheel(with event: NSEvent) {
        // AppKit scroll deltas: scrollingDeltaY > 0 means content moves down.
        // CEF expects pixel deltas; precise events report fractional pixels.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale
        osrBrowser?.sendMouseWheel(at: dipPoint(for: event), deltaX: dx, deltaY: dy, modifiers: modifiers)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        sendKey(event, type: KEYEVENT_RAWKEYDOWN)
        // Let the input system produce characters / IME composition.
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        sendKey(event, type: KEYEVENT_KEYUP)
    }

    public override func flagsChanged(with event: NSEvent) {
        // Forward modifier-only changes as keydown/up so the page sees them.
        sendKey(event, type: KEYEVENT_KEYDOWN)
    }

    private func sendKey(_ event: NSEvent, type: cef_key_event_type_t) {
        var e = cef_key_event_t()
        e.size = MemoryLayout<cef_key_event_t>.stride
        e.type = type
        e.modifiers = CefMetalHostView.cefModifiers(event.modifierFlags)
        e.native_key_code = Int32(event.keyCode)
        e.windows_key_code = Int32(CefKeyCodes.windowsKeyCode(forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
        if let chars = event.charactersIgnoringModifiers, let first = chars.utf16.first {
            e.unmodified_character = first
        }
        if let chars = event.characters, let first = chars.utf16.first {
            e.character = first
        }
        osrBrowser?.sendKeyEvent(e)
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        osrBrowser?.setFocus(true)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        osrBrowser?.setFocus(false)
        return super.resignFirstResponder()
    }
}
