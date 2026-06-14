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
        // Take key focus on click, and tell CEF explicitly — relying on
        // becomeFirstResponder alone proved flaky when several browsers share
        // a window (you'd have to click another view first).
        window?.makeFirstResponder(self)
        osrBrowser?.setFocus(true)
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
    /// What an `otherMouse*` button maps to. Buttons 3/4 are the standard
    /// "back"/"forward" thumb buttons; anything else is treated as a middle
    /// click. Extracted so the mapping is unit-testable.
    enum OtherMouseAction: Equatable { case back, forward, middle }
    static func otherMouseAction(forButtonNumber n: Int) -> OtherMouseAction {
        switch n {
        case 3: return .back
        case 4: return .forward
        default: return .middle
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        // The press is the meaningful edge for nav — fire on down, swallow up.
        switch CefMetalHostView.otherMouseAction(forButtonNumber: event.buttonNumber) {
        case .back: osrBrowser?.goBack(); return
        case .forward: osrBrowser?.goForward(); return
        case .middle:
            osrBrowser?.sendMouseDown(at: dipPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
        }
    }
    public override func otherMouseUp(with event: NSEvent) {
        // Swallow the release of the back/forward thumb buttons so they don't
        // also reach the page as a middle click.
        guard CefMetalHostView.otherMouseAction(forButtonNumber: event.buttonNumber) == .middle else { return }
        osrBrowser?.sendMouseUp(at: dipPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func scrollWheel(with event: NSEvent) {
        // Smooth, native-matching OSR scrolling uses the CGEvent *point* deltas
        // (pixel-precise, momentum-aware) — the same source cefclient uses.
        // Fall back to AppKit deltas (scaled for legacy line-based wheels).
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if let cg = event.cgEvent {
            let pointY = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let pointX = cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if pointX != 0 || pointY != 0 {
                dx = CGFloat(pointX)
                dy = CGFloat(pointY)
            } else if !event.hasPreciseScrollingDeltas {
                dx *= 40; dy *= 40
            }
        } else if !event.hasPreciseScrollingDeltas {
            dx *= 40; dy *= 40
        }
        // Carry the sub-pixel remainder so slow scrolls aren't rounded to zero.
        let totalX = dx + scrollResidual.x
        let totalY = dy + scrollResidual.y
        let sendX = totalX.rounded(.towardZero)
        let sendY = totalY.rounded(.towardZero)
        scrollResidual = CGPoint(x: totalX - sendX, y: totalY - sendY)
        if sendX == 0 && sendY == 0 { return }
        osrBrowser?.sendMouseWheel(at: dipPoint(for: event), deltaX: sendX, deltaY: sendY, modifiers: modifiers)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard osrBrowser != nil else { return }
        // Deferred model (mirrors cefclient): interpretKeyEvents only feeds the
        // NSTextInputClient methods, which *accumulate* state; we then decide
        // whether this was a plain keypress (→ KEYDOWN+CHAR, so JS key events
        // fire and the caret moves) or an IME composition/commit.
        handleKeyEventBeforeTextInputClient()
        interpretKeyEvents([event])
        let base = makeKeyEvent(event)
        handleKeyEventAfterTextInputClient(base)
    }

    public override func keyUp(with event: NSEvent) {
        var e = makeKeyEvent(event)
        e.type = KEYEVENT_KEYUP
        osrBrowser?.sendKeyEvent(e)
    }

    public override func flagsChanged(with event: NSEvent) {
        // Modifier-only change: down when the modifier is now pressed, else up.
        var e = makeKeyEvent(event)
        e.type = isModifierPressed(event) ? KEYEVENT_KEYDOWN : KEYEVENT_KEYUP
        osrBrowser?.sendKeyEvent(e)
    }

    /// Builds a `cef_key_event_t` (without a `type`) from an `NSEvent`.
    func makeKeyEvent(_ event: NSEvent) -> cef_key_event_t {
        var e = cef_key_event_t()
        e.size = MemoryLayout<cef_key_event_t>.stride
        e.modifiers = CefMetalHostView.cefModifiers(event.modifierFlags)
        // Numpad detection (mirrors cefclient's getModifiersForEvent / the
        // EVENTFLAG_IS_KEY_PAD bit) for key events. There is no EVENTFLAG for
        // the Fn key or NumLock on macOS, so those are intentionally omitted.
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            if CefMetalHostView.isKeyPadEvent(event) {
                e.modifiers |= UInt32(EVENTFLAG_IS_KEY_PAD.rawValue)
            }
        }
        e.native_key_code = Int32(event.keyCode)
        if event.type == .keyDown || event.type == .keyUp {
            e.windows_key_code = Int32(CefKeyCodes.windowsKeyCode(
                forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers))
            if let chars = event.charactersIgnoringModifiers, let first = chars.utf16.first {
                e.unmodified_character = first
            }
            if let chars = event.characters, let first = chars.utf16.first {
                e.character = first
            }
        }
        return e
    }

    /// Whether a key event originates from the numeric keypad (mirrors
    /// cefclient's `isKeyPadEvent:` — the `NSEventModifierFlagNumericPad` flag
    /// plus the known keypad key codes).
    static func isKeyPadEvent(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.numericPad) { return true }
        switch event.keyCode {
        // Clear, =, /, *, -, +, Enter, ., and digits 0-9 on the keypad.
        case 71, 81, 75, 67, 78, 69, 76, 65,
             82, 83, 84, 85, 86, 87, 88, 89, 91, 92:
            return true
        default:
            return false
        }
    }

    private func isModifierPressed(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return f.contains(.shift)
        case 59, 62: return f.contains(.control)
        case 58, 61: return f.contains(.option)
        case 55, 54: return f.contains(.command)
        case 57: return f.contains(.capsLock)
        default: return true
        }
    }

    // MARK: Deferred key-input (cefclient text_input_client model)

    private func handleKeyEventBeforeTextInputClient() {
        keyInput.oldHasMarkedText = keyInput.hasMarkedTextFlag
        keyInput.handlingKeyDown = true
        keyInput.textToBeInserted = ""
        keyInput.setMarkedReplacement = nil
        keyInput.unmarkTextCalled = false
    }

    private func handleKeyEventAfterTextInputClient(_ base: cef_key_event_t) {
        keyInput.handlingKeyDown = false
        guard let browser = osrBrowser else { return }

        // Plain keypress (no composition, at most one character produced):
        // send KEYDOWN then CHAR so the renderer sees a real key event.
        if !keyInput.hasMarkedTextFlag, !keyInput.oldHasMarkedText, keyInput.textToBeInserted.utf16.count <= 1 {
            var e = base
            e.type = KEYEVENT_KEYDOWN
            browser.sendKeyEvent(e)
            if let first = keyInput.textToBeInserted.utf16.first {
                e.character = first
            }
            e.type = KEYEVENT_CHAR
            browser.sendKeyEvent(e)
        }

        // Multi-character text (paste, IME result): commit as text.
        let commitThreshold = (keyInput.hasMarkedTextFlag || keyInput.oldHasMarkedText) ? 0 : 1
        if keyInput.textToBeInserted.utf16.count > commitThreshold {
            browser.imeCommitText(keyInput.textToBeInserted, replacementRange: nil)
            keyInput.textToBeInserted = ""
        }

        // Update or finish/cancel the IME composition.
        if keyInput.hasMarkedTextFlag, !keyInput.markedTextValue.isEmpty {
            browser.imeSetComposition(
                text: keyInput.markedTextValue,
                selectionRange: keyInput.markedSelectionRange,
                replacementRange: keyInput.setMarkedReplacement)
        } else if keyInput.oldHasMarkedText, !keyInput.hasMarkedTextFlag {
            if keyInput.unmarkTextCalled {
                browser.imeFinishComposing(keepSelection: false)
            } else {
                browser.imeCancelComposition()
            }
        }
        keyInput.setMarkedReplacement = nil
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

// MARK: - Key code mapping

/// Maps macOS virtual key codes (`NSEvent.keyCode`) to the "Windows" (DOM)
/// virtual key codes CEF expects in `cef_key_event_t.windows_key_code`.
///
/// CEF/Chromium uses the Windows VK_* numbering for `windowsKeyCode`. The
/// mapping below covers the keys whose VK code differs from their character
/// (navigation, function, modifier, and control keys); for ordinary printable
/// keys we fall back to the uppercased character code, which is what Chromium's
/// own mac event conversion does.
enum CefKeyCodes {

    /// Returns the Windows virtual key code for a mac key event.
    static func windowsKeyCode(forMacKeyCode keyCode: UInt16, characters: String?) -> Int {
        if let mapped = specialKeys[keyCode] {
            return mapped
        }
        // Printable key: Chromium uses the uppercased Unicode code point as the
        // VK code for letters/digits, which matches VK_A..VK_Z / VK_0..VK_9.
        if let scalar = characters?.uppercased().unicodeScalars.first, scalar.value < 128 {
            return Int(scalar.value)
        }
        return 0
    }

    /// mac keyCode -> Windows VK code for keys that don't map by character.
    private static let specialKeys: [UInt16: Int] = [
        0x24: 0x0D,  // Return -> VK_RETURN
        0x4C: 0x0D,  // KeypadEnter -> VK_RETURN
        0x30: 0x09,  // Tab -> VK_TAB
        0x31: 0x20,  // Space -> VK_SPACE
        0x33: 0x08,  // Delete (Backspace) -> VK_BACK
        0x75: 0x2E,  // ForwardDelete -> VK_DELETE
        0x35: 0x1B,  // Escape -> VK_ESCAPE
        0x7B: 0x25,  // Left -> VK_LEFT
        0x7C: 0x27,  // Right -> VK_RIGHT
        0x7D: 0x28,  // Down -> VK_DOWN
        0x7E: 0x26,  // Up -> VK_UP
        0x73: 0x24,  // Home -> VK_HOME
        0x77: 0x23,  // End -> VK_END
        0x74: 0x21,  // PageUp -> VK_PRIOR
        0x79: 0x22,  // PageDown -> VK_NEXT
        0x38: 0x10,  // Shift -> VK_SHIFT
        0x3C: 0x10,  // RightShift
        0x3B: 0x11,  // Control -> VK_CONTROL
        0x3E: 0x11,  // RightControl
        0x3A: 0x12,  // Option -> VK_MENU
        0x3D: 0x12,  // RightOption
        0x37: 0x5B,  // Command -> VK_LWIN
        0x36: 0x5C,  // RightCommand -> VK_RWIN
        0x39: 0x14,  // CapsLock -> VK_CAPITAL
        0x7A: 0x70,  // F1
        0x78: 0x71,  // F2
        0x63: 0x72,  // F3
        0x76: 0x73,  // F4
        0x60: 0x74,  // F5
        0x61: 0x75,  // F6
        0x62: 0x76,  // F7
        0x64: 0x77,  // F8
        0x65: 0x78,  // F9
        0x6D: 0x79,  // F10
        0x67: 0x7A,  // F11
        0x6F: 0x7B,  // F12
    ]
}
