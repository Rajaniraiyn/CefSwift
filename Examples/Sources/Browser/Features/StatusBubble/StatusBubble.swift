import CefChromium
import CefSwiftUI
import SwiftUI

/// The address of the link under the pointer, at the page's lower left, in
/// place of Chromium's status bubble: ``CefBrowser/statusText`` drawn over
/// the page.
struct StatusBubble: BrowserFeature {
    func windowDidOpen(_ window: CefWindow) {
        window.chromiumSurfacePolicy[.statusBubble] = .hidden
    }

    func pageOverlay(for browser: CefBrowser) -> some View {
        Bubble(browser: browser)
    }

    private struct Bubble: View {
        let browser: CefBrowser

        var body: some View {
            if !browser.statusText.isEmpty {
                Text(browser.statusText)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5) }
                    .frame(maxWidth: 480, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
        }
    }
}
