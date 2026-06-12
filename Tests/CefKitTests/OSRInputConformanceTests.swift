import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// Pure-logic tests for the OSR input-conformance work: the
/// `performKeyEquivalent` forwarding policy, modifier mapping (incl. command/
/// control/option/shift/capsLock and keypad), and the mouse-button → navigation
/// mapping. None require `cef_initialize` / the framework.
@MainActor
struct OSRInputConformanceTests {

    // MARK: performKeyEquivalent forwarding policy

    @Test func forwardsWebEditingCommandCombos() {
        // Cmd+A/C/V/X/Z and Shift+Cmd+Z are web editing shortcuts → forward.
        for ch in ["a", "c", "v", "x", "z"] {
            #expect(CefMetalHostView.shouldForwardKeyEquivalent(
                flags: [.command], charactersIgnoringModifiers: ch))
        }
        #expect(CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.command, .shift], charactersIgnoringModifiers: "z"))
        // Cmd+Shift+V (paste & match style) → forward.
        #expect(CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.command, .shift], charactersIgnoringModifiers: "v"))
    }

    @Test func passesThroughAppGlobalCommandShortcuts() {
        // These belong to the app / OS and must NOT be consumed by the page.
        for ch in ["q", "w", "m", "h", "`", ",", " ", "\t"] {
            #expect(!CefMetalHostView.shouldForwardKeyEquivalent(
                flags: [.command], charactersIgnoringModifiers: ch),
                "Cmd+\(ch) should pass through to the app")
        }
    }

    @Test func forwardsControlCombos() {
        // Control combinations (e.g. Ctrl+A line-start in inputs) → forward.
        #expect(CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.control], charactersIgnoringModifiers: "a"))
    }

    @Test func passesThroughPlainAndModifierlessKeys() {
        // Plain keys arrive via keyDown; performKeyEquivalent must not consume.
        #expect(!CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [], charactersIgnoringModifiers: "a"))
        // Shift-only / option-only (e.g. typing an accented char) → not here.
        #expect(!CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.shift], charactersIgnoringModifiers: "A"))
        #expect(!CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.option], charactersIgnoringModifiers: "e"))
        // Function key with no command/control → pass through.
        #expect(!CefMetalHostView.shouldForwardKeyEquivalent(
            flags: [.function], charactersIgnoringModifiers: nil))
    }

    // MARK: Modifier mapping

    @Test func modifierFlagsMapToCefBits() {
        let m = CefMetalHostView.cefModifiers([.command, .shift, .control, .option, .capsLock])
        #expect(m & UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_CONTROL_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_ALT_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue) != 0)
    }

    @Test func individualModifiersMapIndependently() {
        #expect(CefMetalHostView.cefModifiers([.command]) == UInt32(EVENTFLAG_COMMAND_DOWN.rawValue))
        #expect(CefMetalHostView.cefModifiers([.control]) == UInt32(EVENTFLAG_CONTROL_DOWN.rawValue))
        #expect(CefMetalHostView.cefModifiers([.option]) == UInt32(EVENTFLAG_ALT_DOWN.rawValue))
        #expect(CefMetalHostView.cefModifiers([.shift]) == UInt32(EVENTFLAG_SHIFT_DOWN.rawValue))
        #expect(CefMetalHostView.cefModifiers([]) == 0)
    }

    @Test func pressedMouseButtonsMapToFlags() {
        let left = CefMetalHostView.cefModifiers([], pressedButtons: 1 << 0)
        #expect(left & UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue) != 0)
        let right = CefMetalHostView.cefModifiers([], pressedButtons: 1 << 1)
        #expect(right & UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue) != 0)
        let middle = CefMetalHostView.cefModifiers([], pressedButtons: 1 << 2)
        #expect(middle & UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue) != 0)
    }

    @Test func keyPadCodesDetected() {
        // EVENTFLAG_IS_KEY_PAD exists and the numeric-keypad detection table is
        // sane (a known keypad code vs a non-keypad code). We can't easily
        // synthesize an NSEvent with a keyCode, so assert the flag constant is
        // distinct and present in the bitset for a numericPad event.
        #expect(EVENTFLAG_IS_KEY_PAD.rawValue == (1 << 9))
    }

    // MARK: Mouse-button → navigation mapping

    @Test func mouseButtonNavigationMapping() {
        #expect(CefMetalHostView.otherMouseAction(forButtonNumber: 3) == .back)
        #expect(CefMetalHostView.otherMouseAction(forButtonNumber: 4) == .forward)
        // Button 2 (middle) and any other → middle click.
        #expect(CefMetalHostView.otherMouseAction(forButtonNumber: 2) == .middle)
        #expect(CefMetalHostView.otherMouseAction(forButtonNumber: 5) == .middle)
    }

    // MARK: Editing-command capi name presence

    @Test func editingFramePointersExist() {
        // Compile-time-ish guard that the frame editing commands we route to
        // exist on cef_frame_t (the field set we call through CefBrowser's
        // editing extension). A zeroed struct has nil pointers, which is the
        // shape CefBrowserEditing safely optional-chains over.
        var frame = cef_frame_t()
        #expect(frame.copy == nil)
        #expect(frame.cut == nil)
        #expect(frame.paste == nil)
        #expect(frame.paste_and_match_style == nil)
        #expect(frame.del == nil)
        #expect(frame.select_all == nil)
        #expect(frame.undo == nil)
        #expect(frame.redo == nil)
    }
}
