import CCef
import CefBase
import Foundation
import Testing

@testable @_spi(Testing) import CefKit

/// Docked DevTools (`CefWindow.devToolsPlacement`, experimental) without
/// Chromium: the size its panel asks for.
@MainActor
@Suite struct DevToolsDockingTests {
    private func preferredSize(_ edge: CefWindow.DevToolsPlacement.Edge, _ size: CGFloat) -> cef_size_t {
        let delegate = DockPanelDelegate(edge: edge, size: size).makeDelegate()
        defer { cefRelease(delegate) }
        return delegate.withMemoryRebound(to: cef_view_delegate_t.self, capacity: 1) {
            $0.pointee.get_preferred_size($0, nil)
        }
    }

    @Test func panelAsksForTheDockedSizeAlongItsEdge() {
        let bottom = preferredSize(.bottom, 320)
        #expect(bottom.width == 1 && bottom.height == 320)
        let trailing = preferredSize(.trailing, 480.4)
        #expect(trailing.width == 480 && trailing.height == 1)
    }

    /// CEF takes a size with a side of 0 as no answer, and lays the view
    /// out at its own size instead: never answer one.
    @Test func panelNeverAnswersAnEmptySize() {
        for size in [0, -50, CGFloat.nan] {
            let answer = preferredSize(.bottom, size)
            #expect(answer.width > 0 && answer.height > 0, "\(size)")
        }
    }
}
