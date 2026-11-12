import AppKit
import CefSwiftUI
import SwiftUI

/// Tabs shown by the system's WebKit instead of Chromium: streaming
/// services whose players need FairPlay, opened automatically (Settings:
/// "Play streaming services with WebKit") or with View > Open in WebKit.
///
/// Each is a window of its own in the same native tab group as the
/// Chromium tabs, with a small toolbar of its own. Following a link to a
/// site that is not a streaming service hands the tab back to Chromium.
@MainActor
final class SystemEngineTab {
    let browser: CefSystemBrowser
    let window: NSWindow
    let isPrivate: Bool

    static let automaticKey = "streamingInSystemEngine"

    /// Whether streaming services open in WebKit by themselves.
    static var opensStreamingSitesAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    init(url: URL, profile: CefProfile, controller: BrowserController) {
        browser = CefSystemBrowser(options: .init(profile: profile))
        isPrivate = profile !== CefProfile.default
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingIdentifier = BrowserController.tabbingIdentifier
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.contentView = NSHostingView(rootView: SystemEngineTabView(tab: self, controller: controller))
        browser.decidePolicy = { [weak controller] browser, navigation in
            // A link the user follows out of the streaming site goes back
            // to Chromium; the site's own redirects (sign-in) stay here.
            guard let url = navigation.url, navigation.hasUserGesture, Self.opensStreamingSitesAutomatically,
                  url.scheme == "https" || url.scheme == "http", !CefSystemBrowser.prefersSystemEngine(for: url),
                  let controller
            else { return .allow }
            controller.openTab(url: url, isPrivate: profile !== CefProfile.default)
            return .cancel
        }
        browser.onOpenWindow = { [weak controller] _, url in
            controller?.openSystemTab(url: url, profile: profile)
        }
        mirrorTitle()
    }

    private func mirrorTitle() {
        window.title = withObservationTracking {
            browser.title.isEmpty ? (browser.url?.host() ?? "New Tab") : browser.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.mirrorTitle() }
        }
    }
}

private struct SystemEngineTabView: View {
    let tab: SystemEngineTab
    let controller: BrowserController

    var body: some View {
        CefSystemWebView(tab.browser)
            .clipShape(.rect(cornerRadius: 10))
            .padding([.horizontal, .bottom], 6)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 2) {
                        Button("Back", systemImage: "chevron.left", action: tab.browser.goBack)
                            .disabled(!tab.browser.canGoBack)
                        Button("Forward", systemImage: "chevron.right", action: tab.browser.goForward)
                            .disabled(!tab.browser.canGoForward)
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                }
                ToolbarItem(placement: .principal) {
                    SystemEngineAddressBar(tab: tab)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Chromium", systemImage: "arrow.uturn.backward.circle") {
                        if let url = tab.browser.url {
                            controller.openTabInChromium(url: url, isPrivate: tab.isPrivate)
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
private struct SystemEngineAddressBar: View {
    let tab: SystemEngineTab
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
            if tab.browser.hasOnlySecureContent {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Address", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    let typed = text.contains("://") ? text : "https://\(text)"
                    if let url = URL(string: typed) { tab.browser.load(url) }
                    isFocused = false
                }
            if tab.browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Reload", systemImage: "arrow.clockwise") { tab.browser.reload() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 640)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .onChange(of: tab.browser.url, initial: true) {
            if !isFocused { text = tab.browser.url?.absoluteString ?? "" }
        }
    }
}
