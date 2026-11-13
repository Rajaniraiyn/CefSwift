import CefSwiftUI
import SwiftUI

/// An offscreen browser draws its frames in a layer of the app's own, so
/// SwiftUI can clip it, round its corners and composite native views over
/// live web content. It needs `isOffscreenRenderingEnabled` in the runtime
/// configuration.
struct OffscreenOverlayDemo: Demo {
    let title = "Offscreen Rendering"
    let summary = "An offscreen page clipped to a rounded card, with native SwiftUI controls composited over it."
    let symbol = "square.2.layers.3d"
    let category = DemoCategory.webViews

    func makeView() -> some View { OffscreenOverlayView() }
}

private struct OffscreenOverlayView: View {
    @State private var browser: CefBrowser = {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        return CefBrowser(url: SamplePage.article.url, configuration: configuration)
    }()
    @State private var zoom = 0.0

    var body: some View {
        CefWebView(browser)
            .clipShape(.rect(cornerRadius: 16))
            .shadow(radius: 8, y: 2)
            .padding(24)
            .overlay(alignment: .bottom) {
                // Native SwiftUI, drawn over the page's pixels.
                HStack(spacing: 14) {
                    Label(browser.title, systemImage: "doc.richtext").lineLimit(1)
                    Divider().frame(height: 18)
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: -2...2, step: 0.5).frame(width: 140)
                    Image(systemName: "plus.magnifyingglass")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: .capsule)
                .padding(40)
            }
            .onChange(of: zoom) { browser.zoomLevel = zoom }
            .readyWhenLoaded(browser)
            .onDisappear { browser.close(force: true) }
    }
}
