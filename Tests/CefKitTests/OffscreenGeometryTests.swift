import AppKit
import Foundation
import Testing

@testable import CefKit

/// Where `CefOffscreenBrowserView` draws a frame of another size than the
/// view, and how page points and view points map onto each other.
@MainActor
struct OffscreenGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let page = CGSize(width: 1200, height: 600)

    @Test func placements() {
        #expect(CefOffscreenBrowserView.rect(placing: page, in: bounds, .stretch) == bounds)
        #expect(CefOffscreenBrowserView.rect(placing: page, in: bounds, .topLeading)
            == CGRect(x: 0, y: 0, width: 1200, height: 600))
        // 1200×600 into 400×300: fitted by width, filled by height.
        #expect(CefOffscreenBrowserView.rect(placing: page, in: bounds, .aspectFit)
            == CGRect(x: 0, y: 50, width: 400, height: 200))
        #expect(CefOffscreenBrowserView.rect(placing: page, in: bounds, .aspectFill)
            == CGRect(x: -100, y: 0, width: 600, height: 300))
        // Nothing to place yet: the view's bounds.
        #expect(CefOffscreenBrowserView.rect(placing: .zero, in: bounds, .aspectFit) == bounds)
    }

    @Test func pagePointsFollowThePlacedFrame() {
        let view = offscreenView()
        view.frame = bounds
        view.pageSize = page
        view.framePlacement = .aspectFit
        // The page's middle shows at the view's middle, its corner at the
        // fitted frame's corner.
        #expect(view.viewPoint(fromPage: CGPoint(x: 600, y: 300)) == CGPoint(x: 200, y: 150))
        #expect(view.viewPoint(fromPage: .zero) == CGPoint(x: 0, y: 50))
        #expect(view.pagePoint(fromView: CGPoint(x: 100, y: 100)) == CGPoint(x: 300, y: 150))
        #expect(view.viewRect(fromPage: CGRect(x: 0, y: 0, width: 600, height: 300))
            == CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func pageSizeIsWhatChromiumIsTold() {
        let view = offscreenView()
        view.frame = bounds
        #expect(view.offscreenViewInfo.size == bounds.size)
        view.pageSize = page
        #expect(view.offscreenViewInfo.size == page)
        view.pageSize = nil
        #expect(view.offscreenViewInfo.size == bounds.size)
    }

    @Test func defaults() {
        let view = offscreenView()
        #expect(view.resizePolicy == .live)
        #expect(view.framePlacement == .stretch)
        #expect(view.pageSize == nil)
        #expect(!view.keepsLastFrameWhenMoved)
    }

    private func offscreenView() -> CefOffscreenBrowserView {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        return CefOffscreenBrowserView(browser: CefBrowser(url: URL(string: "about:blank")!, configuration: configuration))
    }
}
