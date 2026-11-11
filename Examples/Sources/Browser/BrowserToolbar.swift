import CefSwiftUI
import SwiftUI

/// The toolbar above each page: navigation, address bar, downloads.
struct BrowserToolbar: View {
    let browser: CefBrowser
    let controller: BrowserController
    let isPrivate: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button("Back", systemImage: "chevron.left", action: browser.goBack)
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: browser.goForward)
                .disabled(!browser.canGoForward)
            if browser.isLoading {
                Button("Stop", systemImage: "xmark", action: browser.stopLoading)
            } else {
                Button("Reload", systemImage: "arrow.clockwise") { browser.reload() }
            }

            AddressBar(browser: browser, controller: controller, isPrivate: isPrivate)

            if !browser.downloads.isEmpty {
                DownloadsButton(browser: browser)
            }
            Button("New Tab", systemImage: "plus") { controller.openTab() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .padding(.horizontal, 4)
    }
}

private struct AddressBar: View {
    let browser: CefBrowser
    let controller: BrowserController
    let isPrivate: Bool

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(navigate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(isFocused ? 1 : 0.6), in: .capsule)
        .overlay(alignment: .bottom) {
            // Load progress, drawn as a hairline along the field's lower edge.
            GeometryReader { field in
                Capsule()
                    .fill(.tint)
                    .frame(width: field.size.width * browser.estimatedProgress, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(browser.isLoading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: browser.estimatedProgress)
            }
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
        }
        .onChange(of: browser.url, initial: true) { _, url in
            if !isFocused { text = Self.display(url) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { text = Self.display(browser.url) }
        }
        .onChange(of: controller.addressBarFocusRequest) {
            if browser === controller.current { isFocused = true }
        }
    }

    private var icon: String {
        if isPrivate { return "eyeglasses" }
        switch browser.url?.scheme {
        case "https": return "lock.fill"
        case "chrome": return "gearshape"
        default: return "globe"
        }
    }

    private func navigate() {
        guard let destination = Self.destination(for: text) else { return }
        isFocused = false
        browser.load(destination)
    }

    private static func display(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    /// Turns typed text into a URL: an address if it looks like one,
    /// otherwise a web search.
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("about:"), let url = URL(string: trimmed) {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost"),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return search.url
    }
}

private struct DownloadsButton: View {
    let browser: CefBrowser
    @State private var isPresented = false

    var body: some View {
        Button("Downloads", systemImage: "arrow.down.circle") { isPresented.toggle() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(browser.downloads.reversed()) { download in
                        DownloadRow(download: download) { browser.cancelDownload(download.id) }
                    }
                }
                .padding()
                .frame(width: 320)
            }
    }
}

private struct DownloadRow: View {
    let download: CefDownload
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(download.fullPath?.lastPathComponent ?? download.url?.lastPathComponent ?? "Download")
                .lineLimit(1)
            if download.isComplete {
                Button("Show in Finder") {
                    if let path = download.fullPath { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                }
                .buttonStyle(.link)
            } else if download.isCanceled {
                Text("Canceled").foregroundStyle(.secondary)
            } else {
                HStack {
                    if download.totalBytes > 0 {
                        ProgressView(value: Double(download.receivedBytes), total: Double(download.totalBytes))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
