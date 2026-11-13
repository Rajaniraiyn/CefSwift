import Testing

@testable import CefKit

@Suite struct SwipeIndicatorTests {
    @Test func rubberBandsPastTheCommitPoint() {
        #expect(CefNavigationGestureIndicatorView.rubberBand(0.5) == 0.5)
        #expect(CefNavigationGestureIndicatorView.rubberBand(1) == 1)
        let far = CefNavigationGestureIndicatorView.rubberBand(3)
        #expect(far > 1 && far < 1.35)
        #expect(CefNavigationGestureIndicatorView.rubberBand(2) < far)
    }
}
