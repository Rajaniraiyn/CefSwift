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
            if controller.sleepingTabs.count > 0 {
                SleepingTabsButton(controller: controller)
            }
            // The QR code bubble (Chromium's or the app's) opens under this
            // button, and the share menu under the next.
            Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
                .help("Create QR Code for This Page")
                .chromiumSurfaceAnchor([.qrCode], alignment: .trailing)
            Button("Share", systemImage: "square.and.arrow.up") { browser.execute(.showSharingHub) }
                .chromiumSurfaceAnchor([.share])
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

/// Says how many tabs Memory Saver has put to sleep, and wakes them.
struct SleepingTabsButton: View {
    let controller: BrowserController

    var body: some View {
        let count = controller.sleepingTabs.count
        Menu {
            Text("^[\(count) tab](inflect: true) asleep to save memory")
            Button("Wake All Tabs") { controller.sleepingTabs.forEach { $0.restore() } }
        } label: {
            Label("Sleeping Tabs", systemImage: "moon.zzz")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("^[\(count) tab](inflect: true) asleep to save memory")
    }
}

/// A favicon, or a spinner while the page loads, shown in the tab itself.
/// A tab that is asleep to save memory shows its icon faded.
struct TabIcon: View {
    let browser: CefBrowser

    var body: some View {
        Group {
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else if let favicon = browser.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                PageSymbol(url: browser.url)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(browser.isDiscarded ? 0.4 : 1)
        .help(browser.isDiscarded ? "Asleep to save memory" : "")
    }
}

/// The symbol standing in for a page without a favicon.
struct PageSymbol: View {
    let url: URL?

    var body: some View {
        Image(systemName: BrowserPages.isStartPage(url) ? "square.grid.2x2" : BrowserPages.isInternal(url) ? "gearshape" : "globe")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// The address field. Shows where you are — the site, its security, load
/// progress — and becomes an editable location field when clicked, with
/// suggestions as you type.
struct AddressBar: View {
    let browser: CefBrowser
    let controller: BrowserController
    let isPrivate: Bool

    @State private var text = ""
    @State private var suggestions = AddressSuggestions()
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isPrivate {
                Label("Private", systemImage: "hand.raised.fill")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
            if !isFocused, let security = SiteSecurity(browser: browser) {
                PageInfoButton(browser: browser, security: security)
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
                        Text(summary.isEmpty ? "Search or enter website name" : summary)
                            .foregroundStyle(summary.isEmpty ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
            }
            if !isFocused, BrowserLibrary.canBookmark(browser.url) {
                BookmarkButton(isBookmarked: controller.library.isBookmarked(browser.url)) {
                    controller.library.toggleBookmark(for: browser)
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
        .background(ViewAnchor { suggestions.anchor = $0 })
        // Chromium's bubbles (Cast, translate, passwords, …) open under the
        // field's trailing end, where Chrome's would hang from its omnibox.
        .chromiumSurfaceAnchor(alignment: .trailing)
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .onAppear {
            suggestions.setFieldText = { [$text] in $text.wrappedValue = $0 }
            suggestions.favicon = { [controller] url in controller.tab(showing: url)?.favicon }
            suggestions.choose = { [browser, controller, $isFocused] suggestion in
                $isFocused.wrappedValue = false
                Self.open(suggestion, in: browser, controller: controller)
            }
        }
        .onChange(of: browser.url, initial: true) {
            if !isFocused { text = Self.editableText(for: browser.url) }
        }
        .onChange(of: text) {
            guard isFocused else { return }
            suggestions.fieldTextChanged(
                to: text, profile: browser.configuration.profile ?? .default, currentURL: browser.url)
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else {
                suggestions.endEditing()
                text = Self.editableText(for: browser.url)
                return
            }
            suggestions.beginEditing(profile: browser.configuration.profile ?? .default)
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

    /// Goes where a suggestion leads: an open tab is brought forward, a
    /// search runs on the browser's search engine, a page opens.
    static func open(_ suggestion: CefAutocompleteSuggestion, in browser: CefBrowser, controller: BrowserController) {
        if suggestion.kind == .openTab, let url = suggestion.url, controller.switchToTab(showing: url) { return }
        let destination = suggestion.isSearch ? searchURL(for: suggestion.text) : suggestion.url
        if let destination = destination ?? Self.destination(for: suggestion.replacementText) {
            browser.load(destination)
        }
    }

    /// What the field shows when not editing: the site's host, or the
    /// title of an internal page.
    static func summary(of browser: CefBrowser) -> String {
        guard let url = browser.url, url.absoluteString != "about:blank", !BrowserPages.isStartPage(url) else { return "" }
        if BrowserPages.isInternal(url) { return browser.title.isEmpty ? url.absoluteString : browser.title }
        guard let host = url.host(), url.scheme == "https" || url.scheme == "http" else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the field shows while editing: the full address.
    static func editableText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank", !BrowserPages.isStartPage(url) else { return "" }
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
        return searchURL(for: trimmed)
    }

    /// A web search for `query`. Suggested searches use it too, so every
    /// search goes to the same engine whatever Chromium's own default is.
    static func searchURL(for query: String) -> URL? {
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: query)]
        return search.url
    }
}

/// The star in the address field: filled when the page is bookmarked.
private struct BookmarkButton: View {
    let isBookmarked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isBookmarked ? "star.fill" : "star", action: toggle)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isBookmarked ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Add Bookmark (⌘D)")
    }
}

/// Hands over the AppKit view behind a SwiftUI view, for positioning
/// windows against it.
private struct ViewAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The connection's security, as the address field shows it.
enum SiteSecurity {
    case secure, notSecure, app

    @MainActor init?(browser: CefBrowser) {
        let url = browser.url
        guard !BrowserPages.isStartPage(url) else { return nil }
        switch browser.connectionSecurity?.level {
        case .secure: self = .secure
        case .partiallySecure, .notSecure: self = .notSecure
        case .local: if BrowserPages.isInternal(url) { self = .app } else { return nil }
        case nil:
            switch url?.scheme {
            case "https": self = .secure
            case "http": self = .notSecure
            case _ where BrowserPages.isInternal(url): self = .app
            default: return nil
            }
        }
    }

    @MainActor @ViewBuilder var badge: some View {
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

    private var isActive: Bool { browser.downloads.contains { $0.state == .inProgress } }

    var body: some View {
        Button("Downloads", systemImage: isActive ? "arrow.down.circle.dotted" : "arrow.down.circle") { isPresented.toggle() }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Downloads").font(.headline)
                    ForEach(browser.downloads.reversed()) { download in
                        DownloadRow(download: download) {
                            browser.cancelDownload(download.id)
                        } resume: {
                            browser.resumeDownload(download.id)
                        }
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
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.destinationURL?.lastPathComponent ?? download.url?.lastPathComponent ?? "Download")
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch download.state {
                case .completed:
                    Button("Show in Finder") {
                        if let path = download.destinationURL { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                case .cancelled:
                    Text("Canceled").font(.caption).foregroundStyle(.secondary)
                case .interrupted(let reason):
                    Text("Failed (\(reason.description))").font(.caption).foregroundStyle(.secondary)
                case .paused:
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                case .inProgress:
                    if let expected = download.expectedBytes {
                        ProgressView(value: Double(download.receivedBytes), total: Double(expected))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if download.canResume {
                Button("Resume", systemImage: "arrow.clockwise.circle.fill", action: resume)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            if !download.state.isFinished {
                Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
