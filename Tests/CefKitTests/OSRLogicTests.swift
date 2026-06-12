import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// Pure-logic tests for the OSR (offscreen / Metal) hosting mode. None require
/// `cef_initialize` — they exercise the value-type and coordinate mappings that
/// route AppKit input into CEF's windowless browser.
@MainActor
struct OSRLogicTests {

    // MARK: Mouse button mapping

    @Test func mouseButtonMapping() {
        #expect(CefMouseButton.left.cefValue == MBT_LEFT)
        #expect(CefMouseButton.middle.cefValue == MBT_MIDDLE)
        #expect(CefMouseButton.right.cefValue == MBT_RIGHT)
    }

    // MARK: Modifier flag mapping

    @Test func modifierFlagMapping() {
        let m = CefMetalHostView.cefModifiers([.shift, .command])
        #expect(m & UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_CONTROL_DOWN.rawValue) == 0)
        #expect(m & UInt32(EVENTFLAG_ALT_DOWN.rawValue) == 0)
    }

    @Test func modifierMouseButtonMapping() {
        let m = CefMetalHostView.cefModifiers([], pressedButtons: (1 << 0) | (1 << 1))
        #expect(m & UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue) != 0)
        #expect(m & UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue) == 0)
    }

    @Test func allModifiersOff() {
        #expect(CefMetalHostView.cefModifiers([]) == 0)
    }

    // MARK: Windows key code mapping

    @Test func windowsKeyCodeSpecialKeys() {
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x24, characters: "\r") == 0x0D)  // Return
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x30, characters: "\t") == 0x09)  // Tab
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x33, characters: nil) == 0x08)   // Backspace
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x7B, characters: nil) == 0x25)   // Left
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x35, characters: nil) == 0x1B)   // Escape
    }

    @Test func windowsKeyCodePrintableFallback() {
        // Printable letters map to their uppercased code point (VK_A == 0x41).
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x00, characters: "a") == 0x41)
        #expect(CefKeyCodes.windowsKeyCode(forMacKeyCode: 0x12, characters: "1") == 0x31)
    }

    // MARK: OSR view info defaults

    @Test func osrViewInfoDefaults() {
        let info = CefOSRViewInfo()
        #expect(info.deviceScaleFactor == 1)
        #expect(info.sizeDIP == CGSize(width: 1, height: 1))
        // Custom retina geometry round-trips.
        let retina = CefOSRViewInfo(sizeDIP: CGSize(width: 400, height: 300), deviceScaleFactor: 2)
        #expect(retina.deviceScaleFactor == 2)
        #expect(retina.sizeDIP.width == 400)
    }
}
