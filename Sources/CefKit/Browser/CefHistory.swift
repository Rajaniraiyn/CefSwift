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
/// style, which keeps no history.
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
        history = CefInternalPageService(profile: profile, page: "chrome://history/", setup: Self.historySetup)
        newTabPage = CefInternalPageService(
            profile: profile, page: "chrome://new-tab-page-third-party/", setup: Self.mostVisitedSetup)
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
    /// new tab page shows as tiles. Updated by Chromium a few seconds after
    /// history changes.
    public func mostVisited() async throws -> [CefMostVisitedSite] {
        try await newTabPage.call(
            """
            s => new Promise(resolve => {
              s.waiters.push(resolve);
              s.handler.updateMostVisitedInfo();
            }).then(info => info.tiles.map(t => ({ url: t.url, title: t.title })))
            """
        ).decode([TileRecord].self).compactMap { tile in
            URL(string: tile.url).map { CefMostVisitedSite(url: $0, title: tile.title) }
        }
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

    /// Binds an own `most_visited.mojom.MostVisitedPageHandler`; tiles arrive
    /// through its page callback.
    private static let mostVisitedSetup = """
        async () => {
          const m = await import('chrome://resources/cr_components/most_visited/most_visited.mojom-webui.js');
          const router = new m.MostVisitedPageCallbackRouter();
          const handler = new m.MostVisitedPageHandlerRemote();
          m.MostVisitedPageHandlerFactory.getRemote().createPageHandler(
            router.$.bindNewPipeAndPassRemote(), handler.$.bindNewPipeAndPassReceiver());
          const service = { handler, waiters: [] };
          router.setMostVisitedInfo.addListener(info => {
            const waiters = service.waiters;
            service.waiters = [];
            waiters.forEach(resolve => resolve(info));
          });
          return service;
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
