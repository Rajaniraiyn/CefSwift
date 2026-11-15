import CefChromium
import CefSwiftUI
import SwiftUI

/// The address of the link under the pointer, at the page's lower left, in
/// place of Chromium's status bubble: ``CefPage/statusText`` drawn over
/// the page.
struct StatusBubble: BrowserFeature {
    func configure(_ configuration: inout CefPage.Configuration) {
        configuration.showsChromiumStatusBubble = false
    }

    func pageOverlay(for page: CefPage) -> some View {
        Bubble(page: page)
    }

    private struct Bubble: View {
        let page: CefPage

        var body: some View {
            if !page.statusText.isEmpty {
                Text(page.statusText)
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
