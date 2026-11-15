import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The History menu: Back and Forward, the latest pages from Chromium's
/// history (`CefHistory`), and Chromium's history and downloads pages.
///
/// The latest pages are read whenever the menu bar opens, so a service host
/// for them runs only while the menu is in use. Private tabs record no
/// history.
@MainActor
@Observable
final class History: BrowserFeature {
    /// The most recently visited pages, newest first, one entry per page.
    private(set) var recent: [CefHistory.Entry] = []

    @ObservationIgnored private var refresh: Task<Void, Never>?

    func start(_ controller: BrowserController) {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated { if menu === NSApp.mainMenu { self?.reload() } }
        }
    }

    private func reload() {
        refresh?.cancel()
        refresh = Task {
            guard let entries = try? await CefProfile.default.history.search(limit: 40) else { return }
            recent = Self.menuEntries(entries, url: \.url)
        }
    }

    /// The entries the menu lists, newest first: at most 15, one per page,
    /// none of the browser's or Chromium's own pages.
    nonisolated static func menuEntries<Entry>(_ entries: [Entry], url: (Entry) -> URL) -> [Entry] {
        var seen = Set<URL>()
        return Array(entries.filter { !BrowserPages.isInternal(url($0)) && seen.insert(url($0)).inserted }.prefix(15))
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandMenu("History") { HistoryMenu(history: self, controller: controller) }
    }
}

private struct HistoryMenu: View {
    let history: History
    let controller: BrowserController

    var body: some View {
        Button("Back") { controller.frontmostPage?.goBack() }.keyboardShortcut("[")
        Button("Forward") { controller.frontmostPage?.goForward() }.keyboardShortcut("]")
        Divider()
        ForEach(history.recent) { entry in
            Button(String(menuTitle: entry.title, url: entry.url)) { controller.openInFrontmostTab(entry.url) }
        }
        if !history.recent.isEmpty { Divider() }
        Button("Show All History") { controller.openTab(url: URL(string: "chrome://history")!) }.keyboardShortcut("y")
        Button("Downloads") { controller.openTab(url: URL(string: "chrome://downloads")!) }
    }
}
