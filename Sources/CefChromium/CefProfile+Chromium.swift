import CefKit
import Foundation

// CefChromium: Chromium's own browser features, on CefKit.
//
// - Chromium's stores of a profile, bookmarks, history and autocomplete,
//   reached through CefKit's internal service hosts on Chromium's WebUI
//   pages (CefBookmarks, CefHistory, CefAutocomplete).
// - Chromium's surfaces in Chrome-style windows, its bubbles, find bar and
//   status bubble, recognized through overrides of Chromium's AppKit
//   classes (CefChromiumSurface, CefWindow.chromiumSurfacePolicy), with their
//   SwiftUI glue.
//
// Both are bound to interfaces Chromium keeps private: the Mojo handlers
// and extension APIs of its WebUI pages, the format of its Bookmarks file,
// its AppKit classes and the view names its accessibility reports, as the
// pinned CEF has them. A CEF update is more likely to need changes here
// than anywhere in CefKit; SelfTest exercises all of it. The service hosts
// are Chrome-style browsers, and history records visits made in
// Chrome-style browsers only.
//
// Each store object holds its profile, so a profile stays alive while a
// store of it is in use; the profile holds its stores weakly.

extension CefProfile {
    /// The profile's bookmarks.
    ///
    /// An incognito profile shares the default profile's bookmarks, as
    /// Chrome's incognito windows share the bookmarks of the profile they
    /// belong to: for an incognito profile this is
    /// `CefProfile.default.bookmarks`, and bookmarks added through it are
    /// kept on disk with the default profile.
    public var bookmarks: CefBookmarks {
        if isIncognito { return CefProfile.default.bookmarks }
        let stores = chromiumStores
        if let bookmarks = stores.bookmarks { return bookmarks }
        let made = CefBookmarks(profile: self)
        stores.bookmarks = made
        return made
    }

    /// The profile's browsing history and most-visited sites. An incognito
    /// profile keeps no history; its ``CefHistory`` methods throw.
    public var history: CefHistory {
        let stores = chromiumStores
        if let history = stores.history { return history }
        let made = CefHistory(profile: self)
        stores.history = made
        return made
    }

    /// Omnibox-ranked address-bar suggestions. Experimental.
    public var autocomplete: CefAutocomplete {
        let stores = chromiumStores
        if let autocomplete = stores.autocomplete { return autocomplete }
        let made = CefAutocomplete(profile: self)
        stores.autocomplete = made
        return made
    }

    /// What CefChromium keeps for the profile.
    var chromiumStores: ChromiumStores { moduleState { ChromiumStores() } }

    /// Calls the history service with `timeout`, starting its host if it
    /// is not running.
    @_spi(Testing) public func pingHistoryService(timeout: Duration) async throws {
        _ = try await serviceHosts.call(CefHistory.historyModule, "async () => true", timeout: timeout)
    }

    /// Calls the history service with a function that answers after
    /// `duration`, or rejects as soon as its call's signal aborts: for
    /// checks of cancellation and of a host that stops mid-call.
    @_spi(Testing) public func slowHistoryCall(lasting duration: Duration, isIdempotent: Bool) async throws {
        _ = try await serviceHosts.call(
            CefHistory.historyModule,
            """
            (s, a, c) => new Promise((resolve, reject) => {
              const timer = setTimeout(() => resolve(true), a.ms);
              c.signal.addEventListener('abort', () => { clearTimeout(timer); reject(c.signal.reason); }, { once: true });
            })
            """,
            ["ms": .number(Double(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000))],
            as: Bool.self, isIdempotent: isIdempotent)
    }
}

/// A profile's stores, held weakly so each can hold the profile, and the
/// bookmark state that outlives one ``CefBookmarks``.
@MainActor
final class ChromiumStores {
    weak var bookmarks: CefBookmarks?
    weak var history: CefHistory?
    weak var autocomplete: CefAutocomplete?
    weak var extensions: CefExtensions?

    var bookmarkReadSource = CefBookmarks.ReadSource.automatic
    /// When the last change made through ``CefBookmarks`` finished, until
    /// Chromium's `Bookmarks` file is seen saved after it.
    var unsavedBookmarkWrite: Date?
    /// The `Bookmarks` file as last parsed, with the stamp it had.
    var bookmarkFile: (stamp: BookmarkFileStamp, file: CefBookmarkFile)?
}

/// What tells one save of Chromium's `Bookmarks` file from another.
struct BookmarkFileStamp: Equatable {
    var modified: Date?
    var size: Int?
    var inode: Int?
}

extension CefServiceHost {
    /// `chrome.bookmarks`, `chrome.tabs` and `chrome://favicon2`.
    static let bookmarks = CefServiceHost(
        name: "bookmarks", document: "chrome://bookmarks/strings.m.js", isAvailableInIncognito: true)
    /// `history.mojom.PageHandler` and `chrome://favicon2`.
    static let history = CefServiceHost(
        name: "history", document: "chrome://history/strings.m.js", isAvailableInIncognito: false)
    /// `most_visited.mojom.MostVisitedPageHandlerFactory`, on the new tab
    /// page Chromium uses with third-party search engines, whose WebUI
    /// controller does the least work.
    static let mostVisited = CefServiceHost(
        name: "most-visited", document: "chrome://new-tab-page-third-party/strings.m.js",
        isAvailableInIncognito: false)
    /// `mojom.OmniboxPageHandler`, the address bar's autocomplete controller.
    static let omnibox = CefServiceHost(
        name: "omnibox", document: "chrome://omnibox/strings.m.js", isAvailableInIncognito: true)
}
