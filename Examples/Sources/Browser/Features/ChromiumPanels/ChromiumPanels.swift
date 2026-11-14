import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Chromium's QR code, Share and Cast interface, arranged around the
/// toolbar: the QR code bubble hangs from its button, the Share button opens
/// macOS's share menu, and the Cast dialog (View › Cast…) opens under the
/// top bar. With Settings › "Use the browser's QR code and Cast panels"
/// (`-customChromiumPanels YES`), the QR code and the Cast picker are the
/// browser's own SwiftUI panels (`CefChromeWindow.setCustomPresentation`),
/// the picker listing `CefMediaRouter`'s devices.
struct ChromiumPanels: BrowserFeature {
    static let customPanelsKey = "customChromiumPanels"

    func windowDidOpen(_ window: CefChromeWindow) {
        guard UserDefaults.standard.bool(forKey: Self.customPanelsKey) else { return }
        window.setCustomPresentation(for: .qrCode) { surface in QRCodePanel(surface: surface) }
        window.setCustomPresentation(for: .cast) { surface in CastPicker(surface: surface) }
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .trailing {
            // The QR code bubble (Chromium's or the browser's) opens under
            // this button, and the share menu under the next.
            Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
                .help("Create QR Code for This Page")
                .chromiumSurfaceAnchor([.qrCode], alignment: .trailing)
            Button("Share", systemImage: "square.and.arrow.up") { browser.execute(.showSharingHub) }
                .chromiumSurfaceAnchor([.share])
        }
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(before: .toolbar) {
            Button("Cast…") { controller.current?.execute(.castMedia) }
            Divider()
        }
    }

    var settings: some View {
        CustomPanelsSetting()
    }
}

private struct CustomPanelsSetting: View {
    @AppStorage(ChromiumPanels.customPanelsKey) private var customPanels = false

    var body: some View {
        Toggle("Use the browser's QR code and Cast panels", isOn: $customPanels)
            .help("Applies to windows opened from now on. Off: Chromium's own bubbles.")
    }
}

/// A QR code for the page, drawn by the browser.
private struct QRCodePanel: View {
    let surface: CefChromiumSurface

    var body: some View {
        VStack(spacing: 12) {
            Text("Scan QR Code").font(.headline)
            QRCodeView(url: surface.url)
                .frame(width: 200, height: 200)
                .padding(8)
                .background(.white, in: .rect(cornerRadius: 8))
            Text(surface.url?.absoluteString ?? "")
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(surface.url?.absoluteString ?? "", forType: .string)
                }
                Spacer()
                Button("Done", action: surface.dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 260)
    }
}

/// Cast devices, from the media router of the browser's profile.
private struct CastPicker: View {
    let surface: CefChromiumSurface
    private var router: CefMediaRouter { (surface.browser.configuration.profile ?? .default).mediaRouter }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.headline)
            if router.sinks.isEmpty {
                Label("Looking for devices on your network…", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
            ForEach(router.sinks) { sink in
                Label(sink.name, systemImage: sink.kind == .cast ? "tv" : "hifispeaker")
            }
            Divider()
            // Mirroring a tab needs Chromium's own dialog.
            Button("Use Chromium's Cast Dialog…") {
                guard let window = surface.chromeWindow else { return }
                let browser = surface.browser
                surface.dismiss()
                window.setCustomPresentation(for: .cast, nil)
                browser.execute(.castMedia)
            }
            .buttonStyle(.link)
        }
        .padding()
        .frame(width: 280, alignment: .leading)
        .onAppear { router.startDiscovery() }
    }
}
