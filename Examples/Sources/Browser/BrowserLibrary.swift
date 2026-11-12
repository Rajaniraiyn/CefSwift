import AppKit
import CefSwiftUI

/// The browser's bookmarks and history, kept current for the menus, the
/// address field's star and the start page.
///
/// Bookmarks follow `CefBookmarks.changes`; recent history is re-read when
/// the menu bar opens and shortly after each navigation. Private tabs share
/// the regular profile's bookmarks, as in Safari, and record no history.
@MainActor
@Observable
final class BrowserLibrary {
    /// The permanent bookmark folders with their contents.
    private(set) var bookmarkTree: [CefBookmark] = []
    /// Every bookmarked address, for the star in the address field.
    private(set) var bookmarkedURLs: Set<URL> = []
    /// The most recently visited pages, newest first, one entry per page.
    private(set) var recentHistory: [CefHistoryEntry] = []

    /// Serves the start page (`browser://start/`) its data. Only that page
    /// may call it.
    let startPageBridge = CefBridge(name: "startPage")

    private let profile = CefProfile.default
    @ObservationIgnored private var historyRefresh: Task<Void, Never>?

    init() {
        startPageBridge.access = .origins([BrowserPages.startOrigin])
        startPageBridge.handle("load") { [weak self] (_: CefJSON, call: CefBridgeCall) in
            await self?.startPageContent(isPrivate: call.browser.options.profile.map { $0 !== CefProfile.default } ?? false)
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated { if menu === NSApp.mainMenu { self?.reloadHistory() } }
        }
    }

    /// Reads bookmarks and history and starts following bookmark changes.
    /// Call once CEF is running.
    func start() {
        Task { await observeBookmarks() }
        reloadHistory()
    }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        url.map(bookmarkedURLs.contains) ?? false
    }

    /// Bookmarks the page, or removes its bookmarks if it has any.
    func toggleBookmark(for browser: CefBrowser) {
        guard let url = browser.url, Self.canBookmark(url) else { return }
        let title = browser.title.isEmpty ? (url.host() ?? url.absoluteString) : browser.title
        Task {
            do {
                let existing = try await profile.bookmarks.bookmarks(for: url)
                if existing.isEmpty {
                    try await profile.bookmarks.add(url, title: title)
                } else {
                    for bookmark in existing { try await profile.bookmarks.remove(bookmark.id) }
                }
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Whether `url` is a page worth bookmarking: not a blank tab or the
    /// start page.
    static func canBookmark(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "http" || url.scheme == "https" || url.scheme == "file"
            || (BrowserPages.isInternal(url) && !BrowserPages.isStartPage(url))
    }

    private func observeBookmarks() async {
        await reloadBookmarks()
        for await _ in profile.bookmarks.changes {
            await reloadBookmarks()
            startPageBridge.emit("changed")
        }
    }

    private func reloadBookmarks() async {
        guard let tree = try? await profile.bookmarks.tree() else { return }
        bookmarkTree = tree
        var urls = Set<URL>()
        func collect(_ nodes: [CefBookmark]) {
            for node in nodes {
                if let url = node.url { urls.insert(url) }
                collect(node.children ?? [])
            }
        }
        collect(tree)
        bookmarkedURLs = urls
    }

    // MARK: History

    /// Re-reads recent history once a navigation has had time to commit.
    func historyMayHaveChanged() {
        historyRefresh?.cancel()
        historyRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            reloadHistory()
        }
    }

    private func reloadHistory() {
        Task {
            guard let entries = try? await profile.history.search(limit: 40) else { return }
            var seen = Set<URL>()
            recentHistory = Array(
                entries.filter { !BrowserPages.isInternal($0.url) && seen.insert($0.url).inserted }.prefix(15))
        }
    }

    // MARK: Start page

    private struct StartPageContent: Encodable {
        struct Site: Encodable {
            var url: String
            var title: String
        }
        var isPrivate: Bool
        var frequentlyVisited: [Site]
        var bookmarks: [Site]
    }

    private func startPageContent(isPrivate: Bool) async -> StartPageContent {
        let topSites = isPrivate ? [] : (try? await profile.history.mostVisited()) ?? []
        let recent = (try? await profile.bookmarks.recent(limit: 12)) ?? []
        return StartPageContent(
            isPrivate: isPrivate,
            frequentlyVisited: topSites.filter { !BrowserPages.isInternal($0.url) }.prefix(8)
                .map { .init(url: $0.url.absoluteString, title: $0.title) },
            bookmarks: recent.compactMap { bookmark in
                bookmark.url.map { .init(url: $0.absoluteString, title: bookmark.title) }
            })
    }
}
