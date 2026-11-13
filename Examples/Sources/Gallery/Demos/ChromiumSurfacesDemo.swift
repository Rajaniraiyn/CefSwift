import CefChromium
import CefSwiftUI
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Chromium draws some of its interface over a `CefWindow` in windows of
/// its own: the find bar, the link status bubble, bubbles such as the QR
/// code generator. CefChromium lets the app replace each kind with its own
/// SwiftUI view, hang Chromium's under a control of the app's, or hide it.
struct ChromiumSurfacesDemo: Demo {
    let title = "Chromium's Interface, Restyled"
    let summary = "A CefWindow whose find bar (⌘F), link status bubble and QR code bubble are SwiftUI views of the app's own."
    let symbol = "rectangle.on.rectangle.angled"
    let category = DemoCategory.windows

    func makeView() -> some View { ChromiumSurfacesView() }
}

private struct ChromiumSurfacesView: View {
    @State private var window: CefWindow?

    var body: some View {
        ContentUnavailableView {
            Label("Restyled Surfaces", systemImage: "rectangle.on.rectangle.angled")
        } description: {
            Text("Press ⌘F in the window, hover a link, or click the QR code button.")
        } actions: {
            Button("Show Window", action: show)
        }
        .reportReady {
            show()
            try await window?.browser.waitUntilLoaded(timeout: .seconds(30))
        }
        .onDisappear { window?.close() }
    }

    private func show() {
        if let window, !window.isClosed {
            window.show()
            return
        }
        let browser = CefBrowser(url: SamplePage.tour[0].url)
        let window = CefWindow(browser: browser)
        window.setToolbar {
            EmptyView()
        } principal: {
            PageTitle(browser: browser)
        } trailing: {
            HStack {
                Button("Find", systemImage: "magnifyingglass") { browser.execute(.find) }
                Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
                    .chromiumSurfaceAnchor([.qrCode], alignment: .trailing)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
        }
        window.setFindBar { session in FindBar(session: session) }
        window.setStatusBubble { text in
            Text(text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: .capsule)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
        }
        window.setCustomPresentation(for: .qrCode) { surface in
            QRCode(text: surface.url?.absoluteString ?? "")
        }
        window.show()
        self.window = window
    }
}

private struct PageTitle: View {
    let browser: CefBrowser
    var body: some View { Text(browser.title).lineLimit(1) }
}

private struct FindBar: View {
    @Bindable var session: CefFindSession

    var body: some View {
        HStack {
            TextField("Find", text: $session.text).frame(width: 220)
                .onSubmit(session.next)
            Text(session.matchCount == 0 ? "" : "\(session.activeMatch) of \(session.matchCount)")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Previous", systemImage: "chevron.up", action: session.previous)
            Button("Next", systemImage: "chevron.down", action: session.next)
            Button("Done", action: session.end)
        }
        .labelStyle(.iconOnly)
        .padding(8)
    }
}

/// The page's address as a QR code, drawn with Core Image.
private struct QRCode: View {
    let text: String

    var body: some View {
        VStack {
            if let image = Self.image(for: text) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
            }
            Text(text).font(.caption).lineLimit(1).frame(width: 180)
        }
        .padding()
    }

    private static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
