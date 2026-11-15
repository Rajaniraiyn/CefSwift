import AppKit
import Foundation
import Testing

@testable import CefKit

/// Key-equivalent forwarding, modifier flags and extra mouse buttons in the
/// offscreen browser view.
@MainActor
struct OffscreenInputConformanceTests {

    // MARK: performKeyEquivalent forwarding policy

    @Test func forwardsWebEditingCommandCombos() {
        // Cmd+A/C/V/X/Z and Shift+Cmd+Z are web editing shortcuts → forward.
        for ch in ["a", "c", "v", "x", "z"] {
            #expect(CefOffscreenPageView.shouldForwardKeyEquivalent(
                flags: [.command], charactersIgnoringModifiers: ch))
        }
        #expect(CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.command, .shift], charactersIgnoringModifiers: "z"))
        // Cmd+Shift+V (paste & match style) → forward.
        #expect(CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.command, .shift], charactersIgnoringModifiers: "v"))
    }

    @Test func passesThroughAppGlobalCommandShortcuts() {
        // These belong to the app / OS and must NOT be consumed by the page.
        for ch in ["q", "w", "m", "h", "`", ",", " ", "\t"] {
            #expect(!CefOffscreenPageView.shouldForwardKeyEquivalent(
                flags: [.command], charactersIgnoringModifiers: ch),
                "Cmd+\(ch) should pass through to the app")
        }
    }

    @Test func forwardsControlCombos() {
        // Control combinations (e.g. Ctrl+A line-start in inputs) → forward.
        #expect(CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.control], charactersIgnoringModifiers: "a"))
    }

    @Test func passesThroughPlainAndModifierlessKeys() {
        // Plain keys arrive via keyDown; performKeyEquivalent must not consume.
        #expect(!CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [], charactersIgnoringModifiers: "a"))
        // Shift-only / option-only (e.g. typing an accented char) → not here.
        #expect(!CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.shift], charactersIgnoringModifiers: "A"))
        #expect(!CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.option], charactersIgnoringModifiers: "e"))
        // Function key with no command/control → pass through.
        #expect(!CefOffscreenPageView.shouldForwardKeyEquivalent(
            flags: [.function], charactersIgnoringModifiers: nil))
    }

    // MARK: Modifier mapping

    @Test func modifierFlagsMapToCefBits() {
        let m = CefOffscreenPageView.eventModifiers([.command, .shift, .control, .option, .capsLock])
        #expect(m == [.command, .shift, .control, .option, .capsLock])
    }

    @Test func pressedMouseButtonsMapToFlags() {
        #expect(CefOffscreenPageView.eventModifiers([], pressedButtons: 1 << 0) == .leftMouseButton)
        #expect(CefOffscreenPageView.eventModifiers([], pressedButtons: 1 << 1) == .rightMouseButton)
        #expect(CefOffscreenPageView.eventModifiers([], pressedButtons: 1 << 2) == .middleMouseButton)
        #expect(CefOffscreenPageView.eventModifiers([.shift], pressedButtons: 1 << 0) == [.shift, .leftMouseButton])
    }

    // MARK: Mouse-button → navigation mapping

    @Test func mouseButtonNavigationMapping() {
        #expect(CefOffscreenPageView.otherMouseAction(forButtonNumber: 3) == .back)
        #expect(CefOffscreenPageView.otherMouseAction(forButtonNumber: 4) == .forward)
        // Button 2 (middle) and any other → middle click.
        #expect(CefOffscreenPageView.otherMouseAction(forButtonNumber: 2) == .middle)
        #expect(CefOffscreenPageView.otherMouseAction(forButtonNumber: 5) == .middle)
    }

}
