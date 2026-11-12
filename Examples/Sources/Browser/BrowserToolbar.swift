import CefSwiftUI
import SwiftUI

/// Back and forward, beside the window buttons.
struct NavigationButtons: View {
    let browser: CefBrowser

    var body: some View {
        HStack(spacing: 2) {
            Button("Back", systemImage: "chevron.left", action: browser.goBack)
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: browser.goForward)
                .disabled(!browser.canGoForward)
        }
        .buttonStyle(ToolbarIconButtonStyle())
    }
}

/// Downloads and New Tab, at the trailing edge.
struct TrailingButtons: View {
    let browser: CefBrowser
    let controller: BrowserController

    var body: some View {
        HStack(spacing: 2) {
            if !browser.downloads.isEmpty {
                DownloadsButton(browser: browser)
            }
            Button("New Tab", systemImage: "plus") { controller.openTab() }
        }
        .buttonStyle(ToolbarIconButtonStyle())
    }
}

/// An icon button sized and highlighted like AppKit's toolbar buttons.
struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 30, height: 28)
                .background(
                    .quaternary.opacity(configuration.isPressed ? 1 : isHovered && isEnabled ? 0.6 : 0),
                    in: .rect(cornerRadius: 7))
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

/// A favicon, or a spinner while the page loads, shown in the tab itself.
struct TabIcon: View {
    let browser: CefBrowser

    var body: some View {
        Group {
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else if let favicon = browser.faviconURL {
                AsyncImage(url: favicon) { image in
                    image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } placeholder: {
                    PageSymbol(url: browser.url)
                }
            } else {
                PageSymbol(url: browser.url)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// The symbol standing in for a page without a favicon.
struct PageSymbol: View {
    let url: URL?

    var body: some View {
        Image(systemName: BrowserPages.isInternal(url) ? "gearshape" : "globe")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// The address field. Shows where you are — the site, its security, load
/// progress — and becomes an editable location field when clicked.
struct AddressBar: View {
    let browser: CefBrowser
    let controller: BrowserController
    let isPrivate: Bool

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isPrivate {
                Label("Private", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
            ZStack {
                TextField("Search or enter website name", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(navigate)
                    .onExitCommand { isFocused = false }
                    .opacity(isFocused ? 1 : 0)
                if !isFocused {
                    // Where you are, centered; clicking starts editing the
                    // full address. (Changing the field's own alignment
                    // would end editing, so this is a separate view.)
                    HStack(spacing: 5) {
                        if let security = SiteSecurity(url: browser.url) { security.badge }
                        Text(summary.isEmpty ? "Search or enter website name" : summary)
                            .foregroundStyle(summary.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }
            if !isFocused, browser.url != nil {
                Button(browser.isLoading ? "Stop" : "Reload", systemImage: browser.isLoading ? "xmark" : "arrow.clockwise") {
                    if browser.isLoading { browser.stopLoading() } else { browser.reload() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.quaternary.opacity(isFocused ? 0.5 : 0.8), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.7 : 0), lineWidth: 2.5)
                .padding(-2)
        }
        .overlay(alignment: .bottomLeading) { progress }
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .onChange(of: browser.url, initial: true) {
            if !isFocused { text = Self.editableText(for: browser.url) }
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else {
                text = Self.editableText(for: browser.url)
                return
            }
            // Select the whole address so typing replaces it, as Safari does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var summary: String { Self.summary(of: browser) }

    /// Load progress, a hairline along the field's lower edge.
    private var progress: some View {
        GeometryReader { field in
            Rectangle()
                .fill(.tint)
                .frame(width: field.size.width * browser.estimatedProgress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(.rect(cornerRadius: 9))
        .opacity(browser.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: browser.estimatedProgress)
        .animation(.easeOut(duration: 0.4), value: browser.isLoading)
        .allowsHitTesting(false)
    }

    private func navigate() {
        guard let destination = Self.destination(for: text) else { return }
        isFocused = false
        browser.load(destination)
    }

    /// What the field shows when not editing: the site's host, or the
    /// title of an internal page.
    static func summary(of browser: CefBrowser) -> String {
        guard let url = browser.url, url.absoluteString != "about:blank" else { return "" }
        if BrowserPages.isInternal(url) { return browser.title.isEmpty ? url.absoluteString : browser.title }
        guard let host = url.host(), url.scheme == "https" || url.scheme == "http" else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the field shows while editing: the full address.
    static func editableText(for url: URL?) -> String {
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

/// The connection's security, as the address field shows it.
enum SiteSecurity {
    case secure, notSecure, app

    init?(url: URL?) {
        switch url?.scheme {
        case "https": self = .secure
        case "http": self = .notSecure
        case _ where BrowserPages.isInternal(url): self = .app
        default: return nil
        }
    }

    @ViewBuilder var badge: some View {
        switch self {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Secure connection")
        case .notSecure:
            Label("Not Secure", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize()
        case .app:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DownloadsButton: View {
    let browser: CefBrowser
    @State private var isPresented = false

    private var isActive: Bool { browser.downloads.contains { !$0.isComplete && !$0.isCancelled } }

    var body: some View {
        Button("Downloads", systemImage: isActive ? "arrow.down.circle.dotted" : "arrow.down.circle") { isPresented.toggle() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Downloads").font(.headline)
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
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.destinationURL?.lastPathComponent ?? download.url?.lastPathComponent ?? "Download")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if download.isComplete {
                    Button("Show in Finder") {
                        if let path = download.destinationURL { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else if download.isCancelled {
                    Text("Canceled").font(.caption).foregroundStyle(.secondary)
                } else if download.totalBytes > 0 {
                    ProgressView(value: Double(download.receivedBytes), total: Double(download.totalBytes))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if !download.isComplete, !download.isCancelled {
                Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
