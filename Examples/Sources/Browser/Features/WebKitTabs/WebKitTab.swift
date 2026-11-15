import AppKit
import CefSwiftUI
import SystemEngine
import SwiftUI

/// A tab shown by the system's WebKit: a window of its own, with a small
/// toolbar of its own, that the browser shows in its tab group
/// (`BrowserController.showTab`). Following a link to a site that is not a
/// streaming service hands the page back to Chromium.
@MainActor
final class WebKitTab {
    let page: SystemPage
    let window: NSWindow
    let isPrivate: Bool

    init(profile: CefProfile, tabs: WebKitTabs) {
        page = SystemPage(configuration: .init(profile: profile))
        let isPrivate = profile !== CefProfile.default
        self.isPrivate = isPrivate
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.contentView = NSHostingView(rootView: WebKitTabView(tab: self, tabs: tabs))
        page.decidePolicy = { [weak tabs] page, navigation in
            // A link the user follows out of the streaming site goes back
            // to Chromium; the site's own redirects (sign-in) stay here.
            guard let url = navigation.url, navigation.hasUserGesture, WebKitTabs.opensStreamingSitesAutomatically,
                  url.scheme == "https" || url.scheme == "http", !SystemPage.prefersSystemEngine(for: url),
                  let tabs
            else { return .allow }
            tabs.openInChromium(followedLinkTo: url, isPrivate: isPrivate)
            return .cancel
        }
        page.onOpenWindow = { [weak tabs] _, url in
            tabs?.open(url, profile: profile)
        }
        mirrorTitle()
    }

    private func mirrorTitle() {
        window.title = withObservationTracking {
            page.title.isEmpty ? (page.url?.host() ?? "New Tab") : page.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirrorTitle() }
        }
    }
}

private struct WebKitTabView: View {
    let tab: WebKitTab
    let tabs: WebKitTabs

    var body: some View {
        SystemWebView(tab.page)
            .clipShape(.rect(cornerRadius: 10))
            .padding([.horizontal, .bottom], 6)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 2) {
                        Button("Back", systemImage: "chevron.backward", action: tab.page.goBack)
                            .disabled(!tab.page.canGoBack)
                        Button("Forward", systemImage: "chevron.forward", action: tab.page.goForward)
                            .disabled(!tab.page.canGoForward)
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                }
                ToolbarItem(placement: .principal) {
                    WebKitAddressBar(tab: tab)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Chromium", systemImage: "arrow.uturn.backward.circle") {
                        if let url = tab.page.url {
                            tabs.openInChromium(url, isPrivate: tab.isPrivate)
                            tab.window.close()
                        }
                    }
                    .help("Open this page in a Chromium tab")
                    .buttonStyle(ToolbarIconButtonStyle())
                }
            }
    }
}

/// The site, with a badge saying the page is shown by WebKit.
private struct WebKitAddressBar: View {
    let tab: WebKitTab
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label("WebKit", systemImage: "safari")
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.18), in: .capsule)
                .help("Shown by the system's WebKit, which plays FairPlay-protected video")
            if tab.page.hasOnlySecureContent {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Address", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    let typed = text.contains("://") ? text : "https://\(text)"
                    if let url = URL(string: typed) { tab.page.load(url) }
                    isFocused = false
                }
            if tab.page.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Reload", systemImage: "arrow.clockwise") { tab.page.reload() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 640)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .onChange(of: tab.page.url, initial: true) {
            if !isFocused { text = tab.page.url?.absoluteString ?? "" }
        }
    }
}
