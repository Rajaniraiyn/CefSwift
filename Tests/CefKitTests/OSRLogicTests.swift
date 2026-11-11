import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// Key codes and geometry used when forwarding AppKit input to offscreen
/// browsers.
@MainActor
struct OSRLogicTests {

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

    // MARK: View info

    @Test func offscreenViewInfoDefaults() {
        let info = CefOffscreenViewInfo()
        #expect(info.deviceScaleFactor == 1)
        #expect(info.sizeDIP == CGSize(width: 1, height: 1))
        let retina = CefOffscreenViewInfo(sizeDIP: CGSize(width: 400, height: 300), deviceScaleFactor: 2)
        #expect(retina.deviceScaleFactor == 2)
        #expect(retina.sizeDIP.width == 400)
    }
}
