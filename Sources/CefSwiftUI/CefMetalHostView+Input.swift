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
        oldHasMarkedText = hasMarkedTextFlag
        handlingKeyDown = true
        textToBeInserted = ""
        setMarkedReplacement = nil
        unmarkTextCalled = false
    }

    private func handleKeyEventAfterTextInputClient(_ base: cef_key_event_t) {
        handlingKeyDown = false
        guard let browser = osrBrowser else { return }

        // Plain keypress (no composition, at most one character produced):
        // send KEYDOWN then CHAR so the renderer sees a real key event.
        if !hasMarkedTextFlag, !oldHasMarkedText, textToBeInserted.utf16.count <= 1 {
            var e = base
            e.type = KEYEVENT_KEYDOWN
            browser.sendKeyEvent(e)
            if let first = textToBeInserted.utf16.first {
                e.character = first
            }
            e.type = KEYEVENT_CHAR
            browser.sendKeyEvent(e)
        }

        // Multi-character text (paste, IME result): commit as text.
        let commitThreshold = (hasMarkedTextFlag || oldHasMarkedText) ? 0 : 1
        if textToBeInserted.utf16.count > commitThreshold {
            browser.imeCommitText(textToBeInserted, replacementRange: nil)
            textToBeInserted = ""
        }

        // Update or finish/cancel the IME composition.
        if hasMarkedTextFlag, !markedTextValue.isEmpty {
            browser.imeSetComposition(
                text: markedTextValue,
                selectionRange: markedSelectionRange,
                replacementRange: setMarkedReplacement)
        } else if oldHasMarkedText, !hasMarkedTextFlag {
            if unmarkTextCalled {
                browser.imeFinishComposing(keepSelection: false)
            } else {
                browser.imeCancelComposition()
            }
        }
        setMarkedReplacement = nil
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
