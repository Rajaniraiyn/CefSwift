import SwiftUI
import CefKit
import CefSwiftUI

/// One browser tab: a stable identity wrapping a `CefWebViewModel`.
@Observable
@MainActor
final class BrowserTab: Identifiable {
    /// How the tab's browser is hosted.
    enum Kind {
        /// NSView-embedded browser (`CefWebView`, Alloy style).
        case web
        /// Chrome-style child-window overlay (`CefChromeWebView`,
        /// experimental) — full Chrome runtime, chrome:// pages render.
        case chromeEmbedded
    }

    let id = UUID()
    let kind: Kind
    let model: CefWebViewModel

    init(url: URL, kind: Kind = .web, store: TabStore? = nil) {
        self.kind = kind
        model = CefWebViewModel(url: url)
        // Popups (target=_blank, window.open) become new tabs instead of new windows.
        model.onPopupRequest = { [weak store] popupURL in
            guard let store, let popupURL else { return .block }
            store.newTab(url: popupURL)
            return .block // we handled it ourselves
        }
    }

    var displayTitle: String {
        if !model.title.isEmpty { return model.title }
        return model.url?.host() ?? "New Tab"
    }
}

/// The browser's tab list + selection. Owned by the App, injected via `.environment`.
@Observable
@MainActor
final class TabStore {
    static let homeURL = URL(string: "https://duckduckgo.com")!

    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: BrowserTab.ID?

    /// Incremented to ask the omnibox to grab focus (⌘L).
    private(set) var omniboxFocusToken = 0

    init() {
        newTab()
    }

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    @discardableResult
    func newTab(url: URL = TabStore.homeURL, kind: BrowserTab.Kind = .web) -> BrowserTab {
        let tab = BrowserTab(url: url, kind: kind, store: self)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.model.browser?.close()
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func requestOmniboxFocus() {
        omniboxFocusToken += 1
    }
}

/// Omnibox heuristic: things that look like URLs navigate, everything else searches.
enum Omnibox {
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Explicit scheme → take it verbatim (https://, chrome://, about:, data:, file://…)
        if trimmed.contains("://") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") {
            return URL(string: trimmed)
        }
        // Bare host or host/path (no spaces, contains a dot or is localhost) → https
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost") {
            return URL(string: "https://\(trimmed)")
        }
        // Otherwise: search.
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}
