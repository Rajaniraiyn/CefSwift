import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Bookmarks, kept by Chromium (`CefBookmarks`): a star in the address
/// field and a Bookmarks menu. ⌘D adds or removes the frontmost page's
/// bookmark.
///
/// Bookmarks are read at launch and follow `CefBookmarks.changes`, which
/// reads Chromium's own file and starts no service host. Private tabs share
/// the regular profile's bookmarks, as in Safari.
@MainActor
@Observable
final class Bookmarks: BrowserFeature {
    /// The permanent bookmark folders with their contents.
    private(set) var tree: [CefBookmark] = []
    /// Every bookmarked address, for the star.
    private(set) var bookmarkedURLs: Set<URL> = []

    private let profile = CefProfile.default

    func start(_ controller: BrowserController) {
        Task { await observe() }
    }

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

    /// Whether `url` is a page worth bookmarking: a web page, a file, or
    /// one of the browser's or Chromium's own pages. The start page is not.
    nonisolated static func canBookmark(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "http" || url.scheme == "https" || url.scheme == "file" || BrowserPages.isInternal(url)
    }

    private func observe() async {
        await reload()
        for await _ in profile.bookmarks.changes { await reload() }
    }

    private func reload() async {
        guard let tree = try? await profile.bookmarks.tree() else { return }
        self.tree = tree
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

    // MARK: Interface

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .addressFieldTrailing { BookmarkButton(browser: browser, bookmarks: self) }
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandMenu("Bookmarks") { BookmarksMenu(bookmarks: self, controller: controller) }
    }
}

/// The star in the address field: filled when the page is bookmarked.
private struct BookmarkButton: View {
    let browser: CefBrowser
    let bookmarks: Bookmarks
    @Environment(BrowserController.self) private var controller
    @Environment(\.isEditingAddress) private var isEditingAddress

    var body: some View {
        if !isEditingAddress, Bookmarks.canBookmark(browser.url), !controller.isStartPage(browser.url) {
            let isBookmarked = bookmarks.isBookmarked(browser.url)
            Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark", systemImage: isBookmarked ? "star.fill" : "star") {
                bookmarks.toggleBookmark(for: browser)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isBookmarked ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Add Bookmark (⌘D)")
        }
    }
}

/// Add or remove the frontmost page's bookmark, then the bookmarks: the
/// bookmarks bar's contents first, the other folders as submenus. Menu
/// contents are views, so they follow the bookmarks as they change.
private struct BookmarksMenu: View {
    let bookmarks: Bookmarks
    let controller: BrowserController

    var body: some View {
        let url = controller.current?.url
        Button(bookmarks.isBookmarked(url) ? "Remove Bookmark" : "Add Bookmark") {
            if let browser = controller.current { bookmarks.toggleBookmark(for: browser) }
        }
        .keyboardShortcut("d")
        .disabled(!Bookmarks.canBookmark(url) || controller.isStartPage(url))
        Button("Show All Bookmarks") { controller.openTab(url: URL(string: "chrome://bookmarks")!) }
            .keyboardShortcut("b", modifiers: [.command, .option])
        let bar = bookmarks.tree.first { $0.permanentFolder == .bookmarksBar }?.children ?? []
        if !bar.isEmpty { Divider() }
        ForEach(bar) { BookmarkMenuItem(bookmark: $0, open: controller.openInFrontmostTab) }
        let folders = bookmarks.tree.filter { $0.permanentFolder != .bookmarksBar && !($0.children ?? []).isEmpty }
        if !folders.isEmpty { Divider() }
        ForEach(folders) { BookmarkMenuItem(bookmark: $0, open: controller.openInFrontmostTab) }
    }
}

/// A bookmark as a menu item, or a folder as a submenu.
private struct BookmarkMenuItem: View {
    let bookmark: CefBookmark
    let open: (URL) -> Void

    var body: some View {
        if let url = bookmark.url {
            Button(String(menuTitle: bookmark.title, url: url)) { open(url) }
        } else {
            Menu(bookmark.title.isEmpty ? "Untitled Folder" : bookmark.title) {
                ForEach(bookmark.children ?? []) { BookmarkMenuItem(bookmark: $0, open: open) }
                if (bookmark.children ?? []).isEmpty { Text("Empty") }
            }
        }
    }
}
