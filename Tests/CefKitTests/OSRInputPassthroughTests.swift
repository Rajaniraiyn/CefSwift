import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// Drag operations, drag data, paint elements and cursors for offscreen
/// browsers.
@MainActor
struct OSRInputPassthroughTests {

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

    // MARK: Drag data

    @Test func dragDataDefaults() {
        let d = CefDragData(isLink: true, linkURL: "https://example.com", linkTitle: "Ex")
        #expect(d.isLink)
        #expect(d.linkURL == "https://example.com")
        #expect(d.fragmentText.isEmpty)
        let item = d.pasteboardItem
        #expect(item.string(forType: .URL) == "https://example.com")
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
}
