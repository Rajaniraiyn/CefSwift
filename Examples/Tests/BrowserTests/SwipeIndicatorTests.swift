import Testing

@testable import Browser

@Suite struct SwipeIndicatorTests {
    @Test func rubberBandIsLinearUpToOneThenResists() {
        #expect(SwipeIndicatorCircle.rubberBand(0.5) == 0.5)
        #expect(SwipeIndicatorCircle.rubberBand(1) == 1)
        let far = SwipeIndicatorCircle.rubberBand(3)
        #expect(far > 1 && far < 1.35)
        #expect(SwipeIndicatorCircle.rubberBand(2) < far)
    }
}
