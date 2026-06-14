import AppKit
import CCef
import Foundation
import Testing

@testable import CefKit
@testable import CefSwiftUI

/// Pure-logic tests for the OSR native-input passthrough additions: drag mask
/// mapping, touch-type/pointer mapping, paint-element routing, and the AX-tree
/// value decoder. None require `cef_initialize`.
@MainActor
struct OSRInputPassthroughTests {

    // MARK: Drag operation mask mapping (CefDragOperation <-> NSDragOperation)

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

    // MARK: Drag data snapshot defaults

    @Test func dragDataDefaults() {
        let d = CefDragData(isLink: true, linkURL: "https://example.com", linkTitle: "Ex")
        #expect(d.isLink)
        #expect(d.linkURL == "https://example.com")
        #expect(d.fragmentText.isEmpty)
        let item = d.pasteboardItem
        #expect(item.string(forType: .URL) == "https://example.com")
    }

}
