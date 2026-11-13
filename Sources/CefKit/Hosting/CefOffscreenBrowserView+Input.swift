import AppKit
import Foundation

// Forwards AppKit mouse, scroll and keyboard events to the browser, in view
// coordinates (top-left origin).
extension CefOffscreenBrowserView {

    // MARK: Modifiers

    /// The modifiers for AppKit modifier flags and a
    /// `NSEvent.pressedMouseButtons` mask.
    static func eventModifiers(_ flags: NSEvent.ModifierFlags, pressedButtons: Int = 0) -> CefEventModifiers {
        CefEventModifiers(flags).union(CefEventModifiers(pressedMouseButtons: pressedButtons))
    }

    private var modifiers: CefEventModifiers {
        Self.eventModifiers(NSEvent.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons)
    }

    // MARK: Mouse

    public override func mouseMoved(with event: NSEvent) {
        browser?.sendMouseMove(to: viewPoint(for: event), modifiers: modifiers)
    }

    public override func mouseDragged(with event: NSEvent) {
        browser?.sendMouseMove(to: viewPoint(for: event), modifiers: modifiers)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        browser?.sendMouseMove(to: viewPoint(for: event), modifiers: modifiers)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        browser?.sendMouseMove(to: viewPoint(for: event), modifiers: modifiers)
    }

    public override func mouseEntered(with event: NSEvent) {
        browser?.sendMouseMove(to: viewPoint(for: event), modifiers: modifiers)
    }

    public override func mouseExited(with event: NSEvent) {
        browser?.sendMouseExit(at: viewPoint(for: event), modifiers: modifiers)
    }

    public override func mouseDown(with event: NSEvent) {
        // `makeFirstResponder` does nothing when this view already is first
        // responder, so the browser is focused explicitly as well.
        window?.makeFirstResponder(self)
        browser?.hostViewDidBecomeKey()
        browser?.sendMouseDown(at: viewPoint(for: event), button: .left, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func mouseUp(with event: NSEvent) {
        browser?.sendMouseUp(at: viewPoint(for: event), button: .left, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func rightMouseDown(with event: NSEvent) {
        browser?.sendMouseDown(at: viewPoint(for: event), button: .right, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func rightMouseUp(with event: NSEvent) {
        browser?.sendMouseUp(at: viewPoint(for: event), button: .right, clickCount: event.clickCount, modifiers: modifiers)
    }

    /// What an `otherMouse` button does. Buttons 3 and 4 are the back and
    /// forward thumb buttons; any other is a middle click.
    enum OtherMouseAction: Equatable { case back, forward, middle }

    static func otherMouseAction(forButtonNumber n: Int) -> OtherMouseAction {
        switch n {
        case 3: return .back
        case 4: return .forward
        default: return .middle
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        // Thumb buttons navigate on press; their release is swallowed.
        switch Self.otherMouseAction(forButtonNumber: event.buttonNumber) {
        case .back:
            browser?.goBack()
        case .forward:
            browser?.goForward()
        case .middle:
            browser?.sendMouseDown(at: viewPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard Self.otherMouseAction(forButtonNumber: event.buttonNumber) == .middle else { return }
        browser?.sendMouseUp(at: viewPoint(for: event), button: .middle, clickCount: event.clickCount, modifiers: modifiers)
    }

    public override func scrollWheel(with event: NSEvent) {
        if beginHistorySwipeIfNeeded(with: event) { return }
        // Prefer the event's point deltas; otherwise use AppKit's, scaled up
        // for line-based mouse wheels.
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        let pointX = event.cgEvent?.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) ?? 0
        let pointY = event.cgEvent?.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) ?? 0
        if pointX != 0 || pointY != 0 {
            dx = CGFloat(pointX)
            dy = CGFloat(pointY)
        } else if !event.hasPreciseScrollingDeltas {
            dx *= 40
            dy *= 40
        }
        let totalX = dx + scrollResidual.x
        let totalY = dy + scrollResidual.y
        let sendX = totalX.rounded(.towardZero)
        let sendY = totalY.rounded(.towardZero)
        scrollResidual = CGPoint(x: totalX - sendX, y: totalY - sendY)
        if sendX == 0 && sendY == 0 { return }
        browser?.sendScrollWheel(at: viewPoint(for: event), delta: CGVector(dx: sendX, dy: sendY), modifiers: modifiers)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard browser != nil else { return }
        // `interpretKeyEvents` calls the `NSTextInputClient` methods, which
        // only record into `keyInput`; afterwards the keystroke is sent as a
        // key event, so the page sees `keydown` and `keypress`, or as IME text.
        handleKeyEventBeforeTextInputClient()
        interpretKeyEvents([event])
        handleKeyEventAfterTextInputClient(makeKeyEvent(event, phase: .keyDown))
    }

    public override func keyUp(with event: NSEvent) {
        browser?.sendKeyEvent(makeKeyEvent(event, phase: .keyUp))
    }

    public override func flagsChanged(with event: NSEvent) {
        browser?.sendKeyEvent(makeKeyEvent(event, phase: isModifierPressed(event) ? .keyDown : .keyUp))
    }

    /// The key event for a `keyDown`, `keyUp` or `flagsChanged` event.
    func makeKeyEvent(_ event: NSEvent, phase: CefKeyEvent.Phase) -> CefKeyEvent {
        var e = CefKeyEvent(phase: phase, modifiers: Self.eventModifiers(event.modifierFlags))
        if Self.isKeyPadEvent(event) {
            e.modifiers.insert(.numericPad)
        }
        e.nativeKeyCode = Int(event.keyCode)
        // `flagsChanged` events have no characters.
        if event.type == .keyDown || event.type == .keyUp {
            e.windowsKeyCode = CefKeyCodes.windowsKeyCode(
                forMacKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // Chromium takes the first UTF-16 code unit of each.
            e.unmodifiedCharacter = event.charactersIgnoringModifiers?.first
            e.character = event.characters?.first
        }
        return e
    }

    /// Whether a key event comes from the numeric keypad.
    static func isKeyPadEvent(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.numericPad) { return true }
        switch event.keyCode {
        // Clear, =, /, *, -, +, Enter, ., and 0–9.
        case 71, 81, 75, 67, 78, 69, 76, 65,
             82, 83, 84, 85, 86, 87, 88, 89, 91, 92:
            return true
        default:
            return false
        }
    }

    /// Whether a `flagsChanged` event pressed its modifier key.
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

    // MARK: Text input during keyDown

    private func handleKeyEventBeforeTextInputClient() {
        keyInput.oldHasMarkedText = keyInput.hasMarkedTextFlag
        keyInput.handlingKeyDown = true
        keyInput.textToBeInserted = ""
        keyInput.setMarkedReplacement = nil
        keyInput.unmarkTextCalled = false
    }

    private func handleKeyEventAfterTextInputClient(_ base: CefKeyEvent) {
        keyInput.handlingKeyDown = false
        guard let browser else { return }

        // A keystroke outside a composition that produced at most one
        // character is sent as a key event.
        if !keyInput.hasMarkedTextFlag, !keyInput.oldHasMarkedText, keyInput.textToBeInserted.utf16.count <= 1 {
            var e = base
            e.phase = .keyDown
            browser.sendKeyEvent(e)
            if let first = keyInput.textToBeInserted.first {
                e.character = first
            }
            e.phase = .character
            browser.sendKeyEvent(e)
        }

        // Other text, such as the result of a composition, is committed.
        let commitThreshold = (keyInput.hasMarkedTextFlag || keyInput.oldHasMarkedText) ? 0 : 1
        if keyInput.textToBeInserted.utf16.count > commitThreshold {
            browser.insertText(keyInput.textToBeInserted)
            keyInput.textToBeInserted = ""
        }

        // Update, finish or cancel the composition.
        if keyInput.hasMarkedTextFlag, !keyInput.markedTextValue.isEmpty {
            browser.setMarkedText(
                keyInput.markedTextValue,
                selectedRange: keyInput.markedSelectionRange,
                replacementRange: keyInput.setMarkedReplacement)
        } else if keyInput.oldHasMarkedText, !keyInput.hasMarkedTextFlag {
            if keyInput.unmarkTextCalled {
                browser.unmarkText(keepingSelection: false)
            } else {
                browser.cancelComposition()
            }
        }
        keyInput.setMarkedReplacement = nil
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        // Tab or Shift-Tab from another control focuses the page's first or
        // last element.
        browser?.hostViewDidBecomeKey(selecting: window?.keyViewSelectionDirection ?? .directSelection)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        browser?.hostViewDidResignKey()
        return super.resignFirstResponder()
    }
}
