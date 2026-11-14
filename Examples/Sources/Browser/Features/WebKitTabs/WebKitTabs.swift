import AppKit
import CefSwiftUI
import SwiftUI
import SystemEngine

/// Tabs shown by the system's WebKit instead of Chromium (`SystemEngine`'s
/// `SystemBrowser`), which plays the FairPlay-protected video Chromium in
/// CefSwift cannot: streaming services open there by themselves (Settings ›
/// "Play streaming services with WebKit"), and View › Open in WebKit moves
/// any page there. WebKit pages are not Chromium tabs, so each is a window
/// of its own (`WebKitTab`) beside the browser's windows rather than an
/// entry in their tab rail, marked with a WebKit badge, and its "Open in
/// Chromium" button moves the page back.
@MainActor
final class WebKitTabs: BrowserFeature {
    static let automaticKey = "streamingInSystemEngine"

    /// Whether streaming services open in WebKit by themselves.
    static var opensStreamingSitesAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    private weak var controller: BrowserController?
    private var tabs: [WebKitTab] = []
    /// Chromium tabs the user moved out of WebKit, which keep streaming
    /// sites in Chromium.
    private var keptInChromium: Set<ObjectIdentifier> = []

    func start(_ controller: BrowserController) {
        self.controller = controller
    }

    func decidePolicy(for navigation: CefNavigationAction, in browser: CefBrowser) -> CefNavigationDecision? {
        guard navigation.isMainFrame, let url = navigation.url, Self.opensStreamingSitesAutomatically,
              !keptInChromium.contains(ObjectIdentifier(browser)), SystemBrowser.prefersSystemEngine(for: url)
        else { return nil }
        open(url, profile: browser.configuration.profile ?? .default, replacing: browser)
        return .cancel
    }

    /// Opens `url` in a WebKit tab beside the frontmost tab, carrying the
    /// Chromium profile's cookies for the site over. With `replacing`, a
    /// Chromium tab that has shown nothing else yet closes, so the WebKit
    /// tab takes its place.
    func open(_ url: URL, profile: CefProfile, replacing source: CefBrowser? = nil) {
        guard let controller else { return }
        let tab = WebKitTab(profile: profile, tabs: self)
        tabs.append(tab)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: tab.window, queue: .main
        ) { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                tab?.browser.close()
                self?.tabs.removeAll { $0 === tab }
            }
        }
        controller.showTab(tab.window, page: tab.browser)
        if let source, !source.canGoBack { controller.tab(of: source)?.close() }
        Task {
            _ = try? await tab.browser.importCookies(from: profile, for: url)
            tab.browser.load(url)
        }
    }

    /// "Open in Chromium" from a WebKit tab: a Chromium tab that keeps the
    /// page in Chromium even if it is a streaming site.
    func openInChromium(_ url: URL, isPrivate: Bool) {
        // Chromium asks about the first navigation only once the browser
        // exists, after this returns.
        guard let controller else { return }
        Task {
            if let browser = await controller.openTabNow(url: url, isPrivate: isPrivate)?.browser {
                keptInChromium.insert(ObjectIdentifier(browser))
            }
        }
    }

    /// A link followed out of a streaming site in WebKit: back to Chromium.
    func openInChromium(followedLinkTo url: URL, isPrivate: Bool) {
        controller?.openTab(url: url, isPrivate: isPrivate)
    }

    /// View › Open in WebKit: shows the frontmost Chromium tab's page in a
    /// WebKit tab instead.
    private func openCurrentTab() {
        guard let controller, let browser = controller.current, let url = browser.url,
              url.scheme == "https" || url.scheme == "http", let tab = controller.tab(of: browser)
        else { return }
        open(url, profile: browser.configuration.profile ?? .default)
        tab.close()
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(before: .toolbar) {
            Button("Open in WebKit") { self.openCurrentTab() }
                .help("Show this page with the system's WebKit, which plays FairPlay-protected video")
            Divider()
        }
    }

    var settings: some View {
        Setting()
    }

    private struct Setting: View {
        @AppStorage(WebKitTabs.automaticKey) private var streamingInSystemEngine = true

        var body: some View {
            Toggle(isOn: $streamingInSystemEngine) {
                Text("Play streaming services with WebKit")
                Text("Netflix, Disney+ and other services that need FairPlay open in a tab shown by the system's WebKit.")
            }
        }
    }
}

extension SystemBrowser: TabPage {}
