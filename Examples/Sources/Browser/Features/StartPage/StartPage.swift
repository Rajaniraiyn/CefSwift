import AppKit
import CefChromium
import CefSwiftUI

/// The page new tabs open with, `browser://start/`: frequently visited
/// sites (`CefHistory.topSites()`) and recent bookmarks as tiles, with the
/// sites' icons where Chromium has them. The page is the browser's own HTML
/// (`StartPage+HTML.swift`) and gets its data from Swift through the
/// `startPage` bridge (`CefBridge`), which also tells it when bookmarks
/// change. Private tabs show no frequently visited sites, and say they are
/// private.
@MainActor
final class StartPage: BrowserFeature {
    static let url = URL(string: "browser://start/")!

    /// Serves the page its data. Only the page may call it.
    private let bridge = CefBridge(name: "startPage")
    private let profile = CefProfile.default

    init() {
        bridge.access = .origins(["browser://start"])
        bridge.handle("load") { [weak self] (_: CefJSON, call: CefBridge.Call) in
            await self?.content(isPrivate: call.browser.isPrivate)
        }
    }

    func start(_ controller: BrowserController) {
        controller.startPage = Self.url
        BrowserPages.register(host: "start", Page())
        let bridge = bridge
        Task {
            for await _ in profile.bookmarks.changes { bridge.emit("changed") }
        }
    }

    func configure(_ configuration: inout CefBrowser.Configuration) {
        configuration.bridges.append(bridge)
    }

    private struct Page: CefSchemeHandler {
        func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
            BrowserPages.html(StartPage.html)
        }
    }

    // MARK: Content

    private struct Content: Encodable {
        struct Site: Encodable {
            var url: String
            var title: String
            /// The site's icon as a `data:` URL, when Chromium has one.
            var icon: String?
        }
        var isPrivate: Bool
        var frequentlyVisited: [Site]
        var bookmarks: [Site]
    }

    private func content(isPrivate: Bool) async -> Content {
        let topSites = isPrivate ? [] : (try? await profile.history.topSites()) ?? []
        let recent = (try? await profile.bookmarks.recent(limit: 12)) ?? []
        var frequentlyVisited: [Content.Site] = []
        for site in topSites.filter({ !BrowserPages.isInternal($0.url) }).prefix(8) {
            frequentlyVisited.append(.init(url: site.url.absoluteString, title: site.title, icon: await iconURL(for: site.url)))
        }
        var bookmarks: [Content.Site] = []
        for bookmark in recent {
            guard let url = bookmark.url else { continue }
            bookmarks.append(.init(url: url.absoluteString, title: bookmark.title, icon: await iconURL(for: url)))
        }
        return Content(isPrivate: isPrivate, frequentlyVisited: frequentlyVisited, bookmarks: bookmarks)
    }

    /// The icon Chromium keeps for a page, as a `data:` URL the page can
    /// show (it cannot load Chromium's `chrome://favicon2` itself).
    private func iconURL(for url: URL) async -> String? {
        guard let image = try? await profile.history.favicon(for: url, size: 32),
              let bitmap = image.representations.first as? NSBitmapImageRep,
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
