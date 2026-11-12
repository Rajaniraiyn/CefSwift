import AppKit
import Foundation

/// A page in a profile's browsing history.
///
/// Like `chrome://history`, history is grouped by day: a page visited on
/// several days appears once per day.
public struct CefHistoryEntry: Sendable, Identifiable, Hashable {
    public struct ID: Sendable, Hashable {
        public var url: URL
        public var lastVisitDate: Date
    }

    public var id: ID { ID(url: url, lastVisitDate: lastVisitDate) }
    public var url: URL
    public var title: String
    /// The latest visit this entry covers.
    public var lastVisitDate: Date
    /// Every visit this entry covers, newest first.
    public var visitDates: [Date]
    /// Whether the page is bookmarked.
    public var isBookmarked: Bool

    /// Chromium's own visit times, needed to remove exactly these visits.
    let visitTimes: [Double]
}

/// A site from a profile's most-visited list — the tiles on Chrome's new
/// tab page.
public struct CefMostVisitedSite: Sendable, Identifiable, Hashable {
    public var id: URL { url }
    public var url: URL
    public var title: String
}

/// The browsing history of a ``CefProfile`` — the same history Chrome's
/// `chrome://history` page shows.
///
/// ```swift
/// let history = CefProfile.default.history
/// for entry in try await history.search("swift", limit: 20) {
///     print(entry.lastVisitDate, entry.title, entry.url)
/// }
/// let tiles = try await history.mostVisited()
/// ```
///
/// Chromium records visits made in Chrome-style browsers (``CefBrowserWindow``
/// and Chrome UI windows). Browsers embedded with `CefWebView` use the Alloy
/// style, which keeps no history. An incognito profile has none either: its
/// methods throw.
///
/// CEF exposes no history API, so this one talks to the Mojo interfaces
/// behind Chromium's own `chrome://history` and new tab pages, through
/// hidden service browsers parked on them. Those interfaces are internal to
/// Chromium: this API is more likely than the rest of CefKit to need
/// attention when Chromium updates.
@MainActor
public final class CefHistory {
    private let history: CefInternalPageService
    private let newTabPage: CefInternalPageService

    init(profile: CefProfile) {
        // Incognito profiles keep no history.
        history = CefInternalPageService(
            profile: profile, page: "chrome://history/", setup: Self.historySetup, isAvailableInIncognito: false)
        newTabPage = CefInternalPageService(
            profile: profile, page: "chrome://new-tab-page-third-party/", setup: Self.mostVisitedSetup,
            isAvailableInIncognito: false)
    }

    /// Visited pages whose title or address matches `text` (everything
    /// when empty), newest first.
    public func search(_ text: String = "", limit: Int = 100) async throws -> [CefHistoryEntry] {
        try await history.call(
            """
            (s, a) => s.run(async () => {
              let page = (await s.handler.queryHistory(a.text, a.limit, null, true, false)).results;
              const entries = [...page.value];
              while (!page.info?.finished && entries.length < a.limit) {
                page = (await s.handler.queryHistoryContinuation()).results;
                if (!page.value.length) break;
                entries.push(...page.value);
              }
              return entries.slice(0, a.limit).map(e => {
                const times = Object.values(e.allTimestamps ?? {}).flat();
                return { url: e.url, title: e.title, time: e.time, times: times.length ? times : [e.time], starred: !!e.starred };
              });
            })
            """,
            ["text": .string(text), "limit": .number(Double(max(1, limit)))]
        ).decode([HistoryRecord].self).compactMap(CefHistoryEntry.init)
    }

    /// Removes the visits `entries` cover from history.
    public func remove(_ entries: [CefHistoryEntry]) async throws {
        guard !entries.isEmpty else { return }
        let items = CefJSON.array(entries.map { entry in
            ["url": .string(entry.url.absoluteString), "timestamps": .array(entry.visitTimes.map(CefJSON.number))]
        })
        _ = try await history.call(
            "(s, a) => s.run(() => s.handler.removeVisits(a.items)).then(() => true)", ["items": items])
    }

    /// Removes every visit to `url` from history.
    public func remove(_ url: URL) async throws {
        let matches = try await search(url.host() ?? url.absoluteString, limit: 10_000).filter { $0.url == url }
        try await remove(matches)
    }

    /// The profile's most-visited sites, most visited first — what Chrome's
    /// new tab page shows as tiles, including visits made just before the
    /// call.
    public func mostVisited() async throws -> [CefMostVisitedSite] {
        try await newTabPage.call(
            "s => s.tiles().then(tiles => tiles.map(t => ({ url: t.url, title: t.title })))"
        ).decode([TileRecord].self).compactMap { tile in
            URL(string: tile.url).map { CefMostVisitedSite(url: $0, title: tile.title) }
        }
    }

    /// The icon Chromium keeps for `pageURL` — the one the page showed when
    /// it was last visited — at `size` points, or `nil` when it has none.
    ///
    /// For pages that are not open, such as history entries, bookmarks and
    /// most-visited sites. An open page's icon is ``CefBrowser/favicon``.
    public func favicon(for pageURL: URL, size: Int = 16) async throws -> NSImage? {
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let dataURL = try await history.call(
            """
            async (s, a) => {
              const load = page => new Promise(resolve => {
                const image = new Image();
                image.onload = () => {
                  const canvas = document.createElement('canvas');
                  canvas.width = image.naturalWidth;
                  canvas.height = image.naturalHeight;
                  canvas.getContext('2d').drawImage(image, 0, 0);
                  resolve(canvas.toDataURL('image/png'));
                };
                image.onerror = () => resolve(null);
                image.src = 'chrome://favicon2/?' + new URLSearchParams({
                  pageUrl: page, size: a.size, scaleFactor: a.scale + 'x', allowGoogleServerFallback: '0' });
              });
              // Chromium answers with a generic icon when it has none.
              s.fallbacks ??= {};
              s.fallbacks[a.size + 'x' + a.scale] ??= load('https://cefswift.invalid/');
              const [icon, fallback] = await Promise.all([load(a.url), s.fallbacks[a.size + 'x' + a.scale]]);
              return icon && icon !== fallback ? icon : null;
            }
            """,
            ["url": .string(pageURL.absoluteString), "size": .number(Double(size)), "scale": .number(Double(scale))]
        ).stringValue
        guard let dataURL, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let representation = NSBitmapImageRep(data: data)
        else { return nil }
        representation.size = NSSize(width: size, height: size)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    // MARK: Page setup

    /// Binds an own `history.mojom.PageHandler`. Its generated remote class
    /// is not exported by name, so it is found by its methods. Calls are
    /// queued because result paging is stateful per handler.
    private static let historySetup = """
        async () => {
          const m = await import('chrome://history/history.js');
          const isHandler = v => typeof v === 'function'
            && typeof v.prototype?.queryHistory === 'function'
            && typeof v.prototype?.removeVisits === 'function';
          const Remote = Object.values(m).find(isHandler) ?? m.BrowserProxyImpl?.getInstance().handler?.constructor;
          if (!isHandler(Remote)) throw new Error('history.mojom.PageHandler not found');
          const handler = new Remote();
          handler.$.bindNewPipeAndPassReceiver().bindInBrowser();
          let queue = Promise.resolve();
          const run = body => (queue = queue.then(body, body));
          return { handler, run };
        }
        """

    /// Reads the tiles through a `most_visited.mojom.MostVisitedPageHandler`
    /// of its own, created for each call.
    ///
    /// Chromium's `TopSites` reads the most-visited list from history once,
    /// shortly after it loads, and afterwards only every hour; asking a
    /// handler for its tiles (`updateMostVisitedInfo`) returns that cached
    /// list. Creating a handler is what makes `TopSites` read history again
    /// (`MostVisitedSites::AddMostVisitedURLsObserver` calls `Refresh()`).
    /// The new handler first reports the cached tiles, and reports again once
    /// the fresh list differs; without a second report within a moment, the
    /// cached tiles were current.
    private static let mostVisitedSetup = """
        async () => {
          const m = await import('chrome://resources/cr_components/most_visited/most_visited.mojom-webui.js');
          const factory = m.MostVisitedPageHandlerFactory.getRemote();
          const tiles = () => new Promise((resolve, reject) => {
            const router = new m.MostVisitedPageCallbackRouter();
            const handler = new m.MostVisitedPageHandlerRemote();
            let latest = null, settle = null;
            const finish = () => {
              clearTimeout(settle);
              clearTimeout(giveUp);
              handler.$.close();
              router.$.close?.();
              latest ? resolve(latest) : reject(new Error('the new tab page sent no tiles'));
            };
            const giveUp = setTimeout(finish, 10000);
            router.setMostVisitedInfo.addListener(info => {
              const isFirst = latest === null;
              latest = info.tiles;
              if (isFirst) { settle = setTimeout(finish, 750); } else { finish(); }
            });
            factory.createPageHandler(router.$.bindNewPipeAndPassRemote(), handler.$.bindNewPipeAndPassReceiver());
            handler.updateMostVisitedInfo();
          });
          return { tiles };
        }
        """
}

private struct HistoryRecord: Decodable {
    var url: String
    var title: String
    var time: Double
    var times: [Double]
    var starred: Bool
}

private struct TileRecord: Decodable {
    var url: String
    var title: String
}

extension CefHistoryEntry {
    fileprivate init?(_ record: HistoryRecord) {
        guard let url = URL(string: record.url) else { return nil }
        self.url = url
        title = record.title
        lastVisitDate = Date(timeIntervalSince1970: record.time / 1000)
        visitTimes = record.times
        visitDates = record.times.sorted(by: >).map { Date(timeIntervalSince1970: $0 / 1000) }
        isBookmarked = record.starred
    }
}
