import CefSwiftUI
import SwiftUI

/// With `allowsBackForwardNavigationGestures`, a two-finger swipe goes back
/// and forward. `navigationGestureProgress` moves from 0 toward -1 (back)
/// or 1 (forward) during the swipe, and releasing at ±1 navigates; the app
/// draws its own indicator from it.
struct SwipeNavigationDemo: Demo {
    let title = "Swipe Navigation"
    let summary = "Swipe with two fingers to go back and forward, with an indicator the app draws from the swipe's progress."
    let symbol = "hand.draw"
    let category = DemoCategory.webViews

    func makeView() -> some View { SwipeNavigationView() }
}

private struct SwipeNavigationView: View {
    @State private var browser: CefBrowser = {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        configuration.allowsBackForwardNavigationGestures = true
        return CefBrowser(url: SamplePage.tour[0].url, configuration: configuration)
    }()

    var body: some View {
        CefWebView(browser)
            .overlay { SwipeIndicator(progress: browser.navigationGestureProgress) }
            // Two pages of history, so that there is somewhere to swipe back to.
            .reportReady {
                try await browser.waitUntilLoaded(timeout: .seconds(30))
                try await browser.load(SamplePage.tour[1].url).waitUntilLoaded(timeout: .seconds(30))
            }
            .onDisappear { browser.close(force: true) }
    }
}

/// A chevron that slides in from the edge the swipe leads to and fills
/// with the accent color once releasing would navigate.
private struct SwipeIndicator: View {
    let progress: Double

    var body: some View {
        let amount = min(1, abs(progress))
        let commits = abs(progress) >= 1
        Image(systemName: progress < 0 ? "chevron.left" : "chevron.right")
            .font(.title2.weight(.semibold))
            .foregroundStyle(commits ? .white : .primary)
            .frame(width: 48, height: 48)
            .background(commits ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial), in: .circle)
            .scaleEffect(0.6 + 0.4 * amount)
            .offset(x: (progress < 0 ? -1 : 1) * 40 * (1 - amount))
            .opacity(amount)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: progress < 0 ? .leading : .trailing)
            .animation(.snappy(duration: 0.15), value: commits)
            .allowsHitTesting(false)
    }
}
