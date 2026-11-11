import AppKit
import Foundation
import Testing

@testable import CefSwiftUI

/// Key codes and menu titles used when forwarding AppKit input to offscreen
/// browsers.
@MainActor
struct OffscreenLogicTests {

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

    // MARK: Menu titles

    @Test func menuTitleDropsMnemonics() {
        #expect(CefOffscreenBrowserView.menuTitle(fromCefTitle: "&Copy") == "Copy")
        #expect(CefOffscreenBrowserView.menuTitle(fromCefTitle: "Save && &Quit") == "Save & Quit")
    }
}
