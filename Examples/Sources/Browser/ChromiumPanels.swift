import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The browser's own interface in place of some of Chromium's: a find bar
/// under the toolbar and, over the page, a link status bubble and the swipe
/// indicator always, and, when the
/// "Use the browser's QR code and Cast panels" setting is on, a QR code
/// panel and a Cast picker. Chromium's other bubbles hang from the toolbar.
@MainActor
enum ChromiumPanels {
    static let customPanelsKey = "customChromiumPanels"

    static func configure(_ window: CefWindow) {
        window.setFindBar { session in FindBar(session: session) }
        window.chromiumUI[.statusBubble] = .hidden
        let browser = window.browser
        window.setPageOverlay {
            ZStack {
                StatusBubble(browser: browser)
                SwipeIndicator(browser: browser)
            }
        }
        guard UserDefaults.standard.bool(forKey: customPanelsKey) else { return }
        window.setCustomPresentation(for: .qrCode) { surface in QRCodePanel(surface: surface) }
        window.setCustomPresentation(for: .cast) { surface in CastPicker(surface: surface) }
    }
}

/// Find in page, Safari style: a bar under the toolbar.
private struct FindBar: View {
    @Bindable var session: CefFindSession

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find on Page", text: $session.text)
                    .textFieldStyle(.plain)
                    .onSubmit(session.next)
                    .onExitCommand(perform: session.end)
                if !session.text.isEmpty {
                    Text(session.matchCount == 0 ? "Not found" : "\(session.activeMatch) of \(session.matchCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 280, height: 24)
            .background(.quaternary.opacity(0.8), in: .rect(cornerRadius: 6))
            Button("Previous", systemImage: "chevron.left", action: session.previous)
                .disabled(session.matchCount == 0)
            Button("Next", systemImage: "chevron.right", action: session.next)
                .disabled(session.matchCount == 0)
            Button("Done", action: session.end)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The address of the link under the pointer, at the page's lower left,
/// while there is one.
private struct StatusBubble: View {
    let browser: CefBrowser

    var body: some View {
        if !browser.statusText.isEmpty {
            bubble(browser.statusText)
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
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

/// A QR code for the page, drawn by the app.
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

/// Cast devices, from Chromium's media router.
private struct CastPicker: View {
    let surface: CefChromiumSurface
    @State private var router = CefMediaRouter.shared

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
                guard let window = surface.parentWindow else { return }
                surface.dismiss()
                window.setCustomPresentation(for: .cast, nil)
                window.browser.execute(.castMedia)
            }
            .buttonStyle(.link)
        }
        .padding()
        .frame(width: 280, alignment: .leading)
        .onAppear { router.startDiscovery() }
    }
}
