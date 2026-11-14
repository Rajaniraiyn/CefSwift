import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Chromium's QR code, Share and Cast interface from the toolbar: QR Code
/// and Share buttons, and View › Cast….
///
/// Chromium shows its own bubbles for them. In a `CefWindow`, CefChromium
/// can anchor them under these buttons or replace them with the app's own
/// panels (`CefWindow.chromiumSurfacePolicy`, `setCustomPresentation`, as
/// the Gallery's Chromium Surfaces demo does); it does not yet follow
/// Chromium's surfaces in a `CefChromeWindow`, so in the browser's windows
/// they are Chromium's, where Chromium puts them.
struct ChromiumPanels: BrowserFeature {
    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .trailing {
            Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
                .help("Create QR Code for This Page")
            Button("Share", systemImage: "square.and.arrow.up") { browser.execute(.showSharingHub) }
        }
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(before: .toolbar) {
            Button("Cast…") { controller.current?.execute(.castMedia) }
            Divider()
        }
    }
}
