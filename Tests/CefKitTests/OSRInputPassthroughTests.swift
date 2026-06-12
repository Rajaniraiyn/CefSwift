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

    @Test func dragOperationCefValueRoundTrip() {
        // The raw value feeds straight into cef_drag_operations_mask_t.
        #expect(CefDragOperation.copy.rawValue == UInt32(DRAG_OPERATION_COPY.rawValue))
        #expect(CefDragOperation.link.rawValue == UInt32(DRAG_OPERATION_LINK.rawValue))
        #expect(CefDragOperation.move.rawValue == UInt32(DRAG_OPERATION_MOVE.rawValue))
    }

    // MARK: Touch event type values

    @Test func touchEventTypeRawValues() {
        // Sanity: the CEF enum members the gesture forwarder uses exist and are
        // distinct (begin/move/end/cancel).
        let set: Set<UInt32> = [
            CEF_TET_PRESSED.rawValue, CEF_TET_MOVED.rawValue,
            CEF_TET_RELEASED.rawValue, CEF_TET_CANCELLED.rawValue,
        ]
        #expect(set.count == 4)
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

    // MARK: Paint-element routing

    @Test func paintElementRouting() {
        // The render handler maps PET_POPUP -> .popup and everything else ->
        // .view. We assert the enum values are distinct so the host can branch.
        #expect(CefOSRPaintElement.view != CefOSRPaintElement.popup)
    }

    // MARK: AX value decoder (pure Swift, no CEF objects)

    @Test func axValueConvenienceAccessors() {
        let tree: CefAXValue = .dictionary([
            "ax_tree_id": .string("tree-1"),
            "updates": .list([
                .dictionary([
                    "nodes": .list([
                        .dictionary([
                            "id": .int(1),
                            "role": .string("button"),
                            "attributes": .dictionary(["name": .string("Submit")]),
                        ])
                    ])
                ])
            ]),
        ])
        #expect(tree["ax_tree_id"]?.string == "tree-1")
        let nodes = tree["updates"]?.list?.first?["nodes"]?.list
        #expect(nodes?.count == 1)
        #expect(nodes?.first?["role"]?.string == "button")
        #expect(nodes?.first?["attributes"]?["name"]?.string == "Submit")
    }
}
