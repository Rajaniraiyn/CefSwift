import CefSwiftUI
import SwiftUI

/// The browser's back and forward swipe indicator: a chevron in a circle
/// that slides in from the edge the page is leaving, resists past the point
/// where releasing navigates, as a rubber band does, and fills with the
/// accent color from that point on.
///
/// It follows ``CefBrowser/navigationGestureProgress``: 0 at rest, toward
/// -1 while swiping back and toward 1 while swiping forward. The browser's
/// windows lay it over the page (``CefWindow/pageOverlay``) and turn
/// Chromium's own arrow off
/// (``CefBrowser/Configuration/showsChromiumNavigationGestureIndicator``).
struct SwipeIndicator: View {
    let browser: CefBrowser

    var body: some View {
        SwipeIndicatorCircle(progress: browser.navigationGestureProgress)
    }
}

/// The indicator for a given progress.
struct SwipeIndicatorCircle: View {
    let progress: Double

    /// Diameter of the circle.
    static let diameter: CGFloat = 44
    /// How far the circle's edge travels from the page edge at progress 1.
    static let travel: CGFloat = 72

    var body: some View {
        GeometryReader { geometry in
            let magnitude = abs(progress)
            let isArmed = magnitude >= 1
            let goesBack = progress < 0
            let radius = Self.diameter / 2
            let offset = Self.rubberBand(magnitude) * Self.travel
            // Starts hidden past the page edge and slides in.
            let x = goesBack ? -radius + offset : geometry.size.width + radius - offset
            Image(systemName: goesBack ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(isArmed ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: Self.diameter, height: Self.diameter)
                .background(isArmed ? AnyShapeStyle(.tint) : AnyShapeStyle(.background), in: .circle)
                .overlay { Circle().strokeBorder(.separator, lineWidth: isArmed ? 0 : 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
                .scaleEffect(isArmed ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: isArmed)
                .position(x: x, y: geometry.size.height / 2)
                .opacity(progress == 0 ? 0 : min(1, magnitude * 2.5))
        }
        .animation(.easeOut(duration: 0.2), value: progress == 0)
        .accessibilityHidden(true)
    }

    /// Linear up to 1, then increasingly resistant.
    nonisolated static func rubberBand(_ value: Double) -> Double {
        guard value > 1 else { return value }
        let excess = value - 1
        return 1 + (1 - 1 / (excess * 0.55 + 1)) * 0.35
    }
}
