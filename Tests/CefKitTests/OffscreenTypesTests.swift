import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit

/// Drag operations, drag data, paint elements, cursors, view geometry and
/// the input events sent to offscreen browsers.
@MainActor
struct OffscreenTypesTests {

    // MARK: Drag operations

    @Test func dragOperationToNS() {
        #expect(CefDragOperation.copy.nsOperation == .copy)
        #expect(CefDragOperation.link.nsOperation == .link)
        #expect(CefDragOperation.move.nsOperation == .move)
        let combo = CefDragOperation([.copy, .move]).nsOperation
        #expect(combo.contains(.copy))
        #expect(combo.contains(.move))
        // .every widens to the common set.
        let every = CefDragOperation.every.nsOperation
        #expect(every.contains(.copy) && every.contains(.move) && every.contains(.link))
    }

    @Test func dragOperationFromNS() {
        #expect(CefDragOperation(NSDragOperation.copy).contains(.copy))
        #expect(CefDragOperation(NSDragOperation.move).contains(.move))
        let both = CefDragOperation([NSDragOperation.copy, NSDragOperation.link])
        #expect(both.contains(.copy))
        #expect(both.contains(.link))
        #expect(!both.contains(.move))
    }

    // MARK: Paint elements and cursors

    @Test func paintElementMapping() {
        #expect(CefOffscreenPaintElement(cefValue: PET_VIEW) == .view)
        #expect(CefOffscreenPaintElement(cefValue: PET_POPUP) == .popup)
    }

    @Test func cursorMapping() {
        #expect(CefCursorType(cefValue: CT_HAND) == .hand)
        #expect(CefCursorType(cefValue: CT_HAND).nsCursor == .pointingHand)
        #expect(CefCursorType(cefValue: CT_IBEAM).nsCursor == .iBeam)
        #expect(CefCursorType(cefValue: CT_NONE).nsCursor == nil)
        #expect(CefCursorType(cefValue: CT_DND_NONE) == .other)
    }

    // MARK: View info

    @Test func offscreenViewInfoDefaults() {
        let info = CefOffscreenViewInfo()
        #expect(info.deviceScaleFactor == 1)
        #expect(info.size == CGSize(width: 1, height: 1))
        let retina = CefOffscreenViewInfo(size: CGSize(width: 400, height: 300), deviceScaleFactor: 2)
        #expect(retina.deviceScaleFactor == 2)
        #expect(retina.size.width == 400)
    }

    // MARK: Input events

    @Test func modifiersMatchCefFlags() {
        #expect(CefEventModifiers.command.rawValue == UInt32(EVENTFLAG_COMMAND_DOWN.rawValue))
        #expect(CefEventModifiers.option.rawValue == UInt32(EVENTFLAG_ALT_DOWN.rawValue))
        let flags = CefEventModifiers([.command, .shift, .control, .option, .capsLock])
        #expect(flags == [.command, .shift, .control, .option, .capsLock])
        #expect(CefEventModifiers(pressedMouseButtons: 1 << 0) == .leftMouseButton)
        #expect(CefEventModifiers(pressedMouseButtons: 1 << 1) == .rightMouseButton)
        #expect(CefEventModifiers(pressedMouseButtons: 1 << 2) == .middleMouseButton)
    }

    @Test func keyEventConvertsToCef() {
        let event = CefKeyEvent(
            phase: .character, modifiers: [.shift, .numericPad], windowsKeyCode: 0x41, nativeKeyCode: 0,
            character: "A", unmodifiedCharacter: "a")
        let raw = event.cefValue
        #expect(raw.size == MemoryLayout<cef_key_event_t>.stride)
        #expect(raw.type == KEYEVENT_CHAR)
        #expect(raw.modifiers == UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) | UInt32(EVENTFLAG_IS_KEY_PAD.rawValue))
        #expect(raw.windows_key_code == 0x41)
        #expect(raw.character == UInt16(UInt8(ascii: "A")))
        #expect(raw.unmodified_character == UInt16(UInt8(ascii: "a")))
        #expect(CefKeyEvent(raw: raw) == event)
    }

    @Test func touchEventConvertsToCef() {
        let raw = CefTouchEvent(id: 3, location: CGPoint(x: 10, y: 20), phase: .ended, pressure: 1).cefValue
        #expect(raw.id == 3)
        #expect(raw.x == 10 && raw.y == 20)
        #expect(raw.type == CEF_TET_RELEASED)
        #expect(raw.pressure == 1)
        #expect(raw.pointer_type == CEF_POINTER_TYPE_TOUCH)
    }
}
