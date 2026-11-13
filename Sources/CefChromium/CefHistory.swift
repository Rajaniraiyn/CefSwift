import AppKit
import CefKit
import Foundation

extension CefHistory {
    /// A page in a profile's browsing history.
    ///
    /// Like `chrome://history`, history is grouped by day: a page visited on
    /// several days appears once per day.
    public struct Entry: Sendable, Identifiable, Hashable {
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
}

extension CefHistory {
    /// A site from a profile's most-visited list — the tiles on Chrome's new
    /// tab page.
    public struct TopSite: Sendable, Identifiable, Hashable {
        public var id: URL { url }
        public var url: URL
        public var title: String
    }
}

/// The browsing history of a ``CefProfile`` — the same history Chrome's
/// `chrome://history` page shows.
///
/// ```swift
/// let history = CefProfile.default.history
/// for entry in try await history.search("swift", limit: 20) {
///     print(entry.lastVisitDate, entry.title, entry.url)
/// }
/// let tiles = try await history.topSites()
/// ```
///
/// Chromium records visits made in Chrome-style browsers (``CefWindow``
/// and Chrome UI windows). Browsers embedded with `CefWebView` use the Alloy
/// style, which keeps no history. An incognito profile has none either: its
/// methods throw.
///
/// CEF exposes no history API, so this one talks to the Mojo interfaces
/// behind Chromium's own `chrome://history` and new tab pages, from hidden
/// service hosts that start on first use and close when idle. Those
/// interfaces are internal to Chromium: this API is more likely than CefKit
/// to need attention when Chromium updates.
@MainActor
public final class CefHistory {
    /// Held, so the profile lives as long as this object is in use.
    private let profile: CefProfile

    init(profile: CefProfile) {
        self.profile = profile
    }

    private func call<Result: Decodable & Sendable>(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON = [:], as type: Result.Type,
        isIdempotent: Bool = true
    ) async throws -> Result {
        // Incognito profiles keep no history.
        guard !profile.isIncognito else {
            throw CefError.operationFailed("an incognito profile keeps no history")
        }
        return try await profile.serviceHosts.call(module, function, arguments, as: type, isIdempotent: isIdempotent)
    }

    /// Visited pages whose title or address matches `text` (everything
    /// when empty), newest first.
    ///
    /// For a long history, ``entries(matching:pageSize:)`` reads the same
    /// pages a page at a time.
    public func search(_ text: String = "", limit: Int = 100) async throws -> [CefHistory.Entry] {
        try await call(
            Self.historyModule, "(s, a) => s.search(a.text, a.limit)",
            ["text": .string(text), "limit": .number(Double(max(1, limit)))], as: [HistoryRecord].self
        ).compactMap(CefHistory.Entry.init)
    }

    /// Visited pages whose title or address matches `text` (everything
    /// when empty), newest first, a page at a time: each page is read from
    /// Chromium when the consumer asks for it, so memory holds one page
    /// whatever the history's size. The sequence ends after the oldest
    /// match; ending the consuming task ends it.
    ///
    /// ```swift
    /// for try await page in CefProfile.default.history.entries(matching: "swift", pageSize: 200) {
    ///     print(page.count, page.first?.title ?? "")
    /// }
    /// ```
    ///
    /// Pages are Chromium's own batches, `pageSize` entries or fewer. A
    /// page visited between two reads can shift what the next page starts
    /// with, as on `chrome://history`.
    public func entries(matching text: String = "", pageSize: Int = 100) -> AsyncThrowingStream<[CefHistory.Entry], Error> {
        let cursor = HistoryCursor(text: text, pageSize: max(1, pageSize))
        return AsyncThrowingStream { [self] in try await self.nextPage(cursor) }
    }

    private func nextPage(_ cursor: HistoryCursor) async throws -> [CefHistory.Entry]? {
        guard !cursor.isFinished else { return nil }
        let page = try await call(
            Self.historyModule, "(s, a) => s.page(a.token, a.text, a.size, a.start)",
            [
                "token": .number(Double(cursor.token)), "text": .string(cursor.text),
                "size": .number(Double(cursor.pageSize)), "start": .number(Double(cursor.position)),
            ],
            as: HistoryPage.self)
        cursor.position += page.entries.count
        cursor.isFinished = page.finished || page.entries.isEmpty
        if page.entries.isEmpty { return nil }
        return page.entries.compactMap(CefHistory.Entry.init)
    }

    /// `count` made-up entries, built by the history host and decoded as
    /// ``search(_:limit:)`` decodes its results: the transport and decoding
    /// of a large result without a history that large. For benchmarks.
    @_spi(Testing) public func syntheticEntries(_ count: Int) async throws -> [CefHistory.Entry] {
        try await call(
            Self.historyModule,
            """
            (s, a) => Array.from({ length: a.count }, (_, i) => ({
              url: 'https://example.com/articles/' + i + '/a-page-with-a-typical-length-address',
              title: 'A typical page title, number ' + i, time: 1.7e12 - i * 60000,
              times: [1.7e12 - i * 60000], starred: i % 7 === 0 }))
            """,
            ["count": .number(Double(count))], as: [HistoryRecord].self
        ).compactMap(CefHistory.Entry.init)
    }

    /// Removes the visits `entries` cover from history.
    public func remove(_ entries: [CefHistory.Entry]) async throws {
        guard !entries.isEmpty else { return }
        let items = CefJSON.array(entries.map { entry in
            ["url": .string(entry.url.absoluteString), "timestamps": .array(entry.visitTimes.map(CefJSON.number))]
        })
        _ = try await call(
            Self.historyModule, "(s, a) => s.run(() => s.handler.removeVisits(a.items)).then(() => true)", ["items": items],
            as: CefJSON.self, isIdempotent: false)
    }

    /// Removes every visit to `url` from history.
    public func remove(_ url: URL) async throws {
        let matches = try await search(url.host() ?? url.absoluteString, limit: 10_000).filter { $0.url == url }
        try await remove(matches)
    }

    /// The profile's most-visited sites, most visited first — what Chrome's
    /// new tab page shows as tiles, including visits made just before the
    /// call.
    public func topSites() async throws -> [CefHistory.TopSite] {
        try await call(
            Self.mostVisitedModule,
            "s => s.tiles().then(tiles => tiles.map(t => ({ url: t.url, title: t.title })))", as: [TileRecord].self
        ).compactMap { tile in
            URL(string: tile.url).map { CefHistory.TopSite(url: $0, title: tile.title) }
        }
    }

    /// The icon Chromium keeps for `pageURL` — the one the page showed when
    /// it was last visited — at `size` points, or `nil` when it has none.
    ///
    /// For pages that are not open, such as history entries, bookmarks and
    /// most-visited sites. An open page's icon is ``CefBrowser/favicon``.
    /// For a list, ``favicons(for:size:)`` asks for all of them at once.
    public func favicon(for pageURL: URL, size: Int = 16) async throws -> NSImage? {
        try await favicons(for: [pageURL], size: size)[pageURL]
    }

    /// The icons Chromium keeps for `pageURLs`, at `size` points, by page;
    /// pages without one are left out. One call to the service host for the
    /// whole list.
    ///
    /// Icons travel as their pixels, which become the images' bitmaps
    /// without being encoded or decoded on the way.
    public func favicons(for pageURLs: [URL], size: Int = 16) async throws -> [URL: NSImage] {
        guard !pageURLs.isEmpty else { return [:] }
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        let icons = try await call(
            Self.faviconModule,
            "(s, a) => s.icons(a.urls, a.size, a.scale)",
            [
                "urls": .array(pageURLs.map { .string($0.absoluteString) }),
                "size": .number(Double(size)), "scale": .number(Double(scale)),
            ],
            as: [IconRecord?].self)
        var images: [URL: NSImage] = [:]
        for (url, icon) in zip(pageURLs, icons) {
            if let icon, let image = icon.makeImage(size: size) { images[url] = image }
        }
        return images
    }

    // MARK: Service modules

    /// An own `history.mojom.PageHandler`. Calls are queued because result
    /// paging is stateful per handler: the handler keeps the position of
    /// one query, which ``cursor`` says whose it is. A page whose query
    /// another moved queries again and skips what was delivered.
    static let historyModule = CefServiceHost.Module(
        name: "history", hosts: [.history],
        setup: """
            async () => {
              const m = await import('chrome://resources/cr_components/history/history.mojom-webui.js');
              const handler = m.PageHandler.getRemote();
              let queue = Promise.resolve();
              const run = body => (queue = queue.then(body, body));
              const record = e => {
                const times = Object.values(e.allTimestamps ?? {}).flat();
                return { url: e.url, title: e.title, time: e.time, times: times.length ? times : [e.time], starred: !!e.starred };
              };
              const batch = async (first, text, size) => {
                const results = (await (first
                  ? handler.queryHistory(text, size, null, true, false)
                  : handler.queryHistoryContinuation())).results;
                return { entries: results.value, finished: !!results.info?.finished || !results.value.length };
              };
              let cursor = null;
              const search = (text, limit) => run(async () => {
                cursor = null;
                let page = await batch(true, text, limit);
                const entries = [...page.entries];
                while (!page.finished && entries.length < limit) {
                  page = await batch(false, text, limit);
                  entries.push(...page.entries);
                }
                return entries.slice(0, limit).map(record);
              });
              const page = (token, text, size, start) => run(async () => {
                let page;
                if (cursor?.token === token && cursor.position === start) {
                  if (cursor.finished) return { entries: [], finished: true };
                  page = await batch(false, text, size);
                } else {
                  cursor = { token, position: 0, finished: false };
                  page = await batch(true, text, size);
                  while (cursor.position + page.entries.length <= start && !page.finished) {
                    cursor.position += page.entries.length;
                    page = await batch(false, text, size);
                  }
                  page.entries = page.entries.slice(Math.max(0, start - cursor.position));
                  cursor.position = start;
                }
                cursor.position += page.entries.length;
                cursor.finished = page.finished;
                return { entries: page.entries.map(record), finished: page.finished };
              });
              return { handler, run, search, page };
            }
            """)

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
    private static let mostVisitedModule = CefServiceHost.Module(
        name: "most-visited", hosts: [.mostVisited],
        setup: """
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
            """)

    /// `chrome://favicon2` images, which the bookmarks and history hosts may
    /// load; whichever of them runs answers. Each icon is drawn once into a
    /// canvas and read back as its RGBA pixels; Chromium answers with a
    /// generic icon when it has none, which is recognized by its pixels.
    private static let faviconModule = CefServiceHost.Module(
        name: "favicons", hosts: [.bookmarks, .history],
        setup: """
            async () => {
              const canvas = new OffscreenCanvas(1, 1);
              const context = canvas.getContext('2d', { willReadFrequently: true });
              const load = (page, size, scale) => new Promise(resolve => {
                const image = new Image();
                image.onload = () => {
                  const width = image.naturalWidth, height = image.naturalHeight;
                  if (!width || !height) return resolve(null);
                  canvas.width = width;
                  canvas.height = height;
                  context.clearRect(0, 0, width, height);
                  context.drawImage(image, 0, 0);
                  resolve({ width, height, pixels: context.getImageData(0, 0, width, height).data.buffer });
                };
                image.onerror = () => resolve(null);
                image.src = 'chrome://favicon2/?' + new URLSearchParams({
                  pageUrl: page, size, scaleFactor: scale + 'x', allowGoogleServerFallback: '0' });
              });
              const same = (a, b) => {
                if (!a || !b || a.width !== b.width || a.height !== b.height) return false;
                const x = new Uint32Array(a.pixels), y = new Uint32Array(b.pixels);
                for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
                return true;
              };
              const fallbacks = {};
              const icons = async (pages, size, scale) => {
                const fallback = await (fallbacks[size + 'x' + scale] ??= load('https://cefswift.invalid/', size, scale));
                const loaded = await Promise.all(pages.map(page => load(page, size, scale)));
                return loaded.map(icon => icon && !same(icon, fallback) ? icon : null);
              };
              return { icons };
            }
            """)
}

/// Where a paged history read stands.
@MainActor
private final class HistoryCursor {
    private static var lastToken = 0
    let token: Int
    let text: String
    let pageSize: Int
    var position = 0
    var isFinished = false

    init(text: String, pageSize: Int) {
        Self.lastToken += 1
        token = Self.lastToken
        self.text = text
        self.pageSize = pageSize
    }
}

struct HistoryPage: Decodable {
    var entries: [HistoryRecord]
    var finished: Bool
}

/// An icon's RGBA pixels, not premultiplied, as a canvas reads them.
struct IconRecord: Decodable {
    var width: Int
    var height: Int
    var pixels: Data

    func makeImage(size: Int) -> NSImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: size, height: size))
    }
}

struct HistoryRecord: Decodable {
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

extension CefHistory.Entry {
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
