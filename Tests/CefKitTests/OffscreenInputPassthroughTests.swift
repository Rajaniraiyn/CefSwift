import AppKit
import Foundation
import Testing

@testable import CefKit

/// Drag data leaving an offscreen browser.
@MainActor
struct OffscreenInputPassthroughTests {

    @Test func dragDataPasteboardItem() {
        let d = CefDragData(isLink: true, linkURL: URL(string: "https://example.com"), linkTitle: "Ex")
        #expect(d.isLink)
        #expect(d.linkURL?.absoluteString == "https://example.com")
        #expect(d.fragmentText.isEmpty)
        let item = d.pasteboardItem
        #expect(item.string(forType: .URL) == "https://example.com")
    }
}
