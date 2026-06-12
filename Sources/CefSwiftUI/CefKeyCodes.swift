import AppKit
import Foundation

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
