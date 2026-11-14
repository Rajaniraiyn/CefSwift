import CCef
import CoreGraphics
import Foundation
import Testing

@testable import CefKit

/// Numbers converted for CEF that may be out of its range — a renderer's
/// coordinates and ranges, an app's points, a server's cookie expiry —
/// saturate or map to CEF's own "invalid", never trap.
struct SaturatingConversionTests {
    @Test func coordinatesSaturate() {
        #expect(Int32(saturating: 12.4) == 12)
        #expect(Int32(saturating: -12.6) == -13)
        #expect(Int32(saturating: CGFloat(Int32.max) + 100) == .max)
        #expect(Int32(saturating: 1e300) == .max)
        #expect(Int32(saturating: -.infinity) == .min)
        #expect(Int32(saturating: .nan) == 0)
        // The screen point of a view point near Int32.max, as
        // `get_screen_point` computes it.
        #expect(Int32(saturating: 500 + CGFloat(Int32.max - 1)) == .max)
        let rect = cef_rect_t(CGRect(x: 1e20, y: -1e20, width: .infinity, height: .nan))
        #expect(rect.x == .max && rect.y == .min && rect.width == .max && rect.height == 1)
    }

    @Test func rangesFromCEF() {
        #expect(NSRange(cef_range_t(from: 2, to: 5)) == NSRange(location: 2, length: 3))
        // CEF's invalid range is no selection.
        #expect(NSRange(cef_range_t(from: .max, to: .max)).location == NSNotFound)
        // Reversed: empty at its start.
        #expect(NSRange(cef_range_t(from: 5, to: 2)) == NSRange(location: 5, length: 0))
    }

    @Test func rangesToCEF() {
        let range = cef_range_t(NSRange(location: 2, length: 3))
        #expect(range.from == 2 && range.to == 5)
        let none = cef_range_t(NSRange(location: NSNotFound, length: 4))
        #expect(none.from == .max && none.to == .max)
        let huge = cef_range_t(NSRange(location: Int.max - 1, length: 10))
        #expect(huge.from == .max && huge.to == .max)
    }

    @Test func farDatesSaturate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(cef_basetime_t(date: now).date == now)
        #expect(cef_basetime_t(date: .distantFuture).val > cef_basetime_t(date: now).val)
        #expect(cef_basetime_t(date: Date(timeIntervalSince1970: 1e300)).val > 0)
        #expect(cef_basetime_t(date: Date(timeIntervalSince1970: .infinity)).val > 0)
        #expect(cef_basetime_t(date: Date(timeIntervalSince1970: -.infinity)).val < 0)
        #expect(cef_basetime_t(date: Date(timeIntervalSince1970: .nan)).val == 0)
    }
}
