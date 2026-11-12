import Foundation

/// One ranked suggestion for text typed into an address bar.
public struct CefAutocompleteSuggestion: Sendable, Identifiable, Hashable {
    /// Where a suggestion comes from.
    public enum Kind: Sendable, Hashable {
        /// The typed text, taken as an address.
        case typedURL
        /// A page from history.
        case history
        /// A bookmark.
        case bookmark
        /// A tab that is already open.
        case openTab
        /// A web search for the typed text.
        case search
        /// A query suggested by the search engine, or a past search.
        case searchSuggestion
        /// A page suggested by the search engine.
        case navigationSuggestion
        /// Anything else: calculator answers, actions, clipboard, …
        case other
    }

    public var id: String { "\(kind)|\(url?.absoluteString ?? "")|\(text)" }
    public var kind: Kind
    /// The main line: an address, or a search query.
    public var text: String
    /// The secondary line: a page title or search engine name.
    public var detail: String
    /// Where choosing the suggestion navigates (for searches, the results
    /// page).
    public var url: URL?
    /// What an address bar shows when the suggestion is selected.
    public var replacementText: String
    /// Text to complete inline after the caret, as Chrome's omnibox does,
    /// when this is the top suggestion. Empty when there is none.
    public var inlineCompletion: String
    /// Chromium's relevance score; higher ranks first within a group.
    public var relevance: Int
    /// Whether the suggestion may be the default (top, Return-key) match.
    public var canBeDefault: Bool
    public var isBookmarked: Bool
    /// Whether choosing it runs a search rather than opening a page.
    public var isSearch: Bool
}

/// Address-bar suggestions for a ``CefProfile``, ranked by Chromium's own
/// omnibox — history, bookmarks, open tabs, and the default search engine's
/// suggestions, in the order Chrome's omnibox shows them.
///
/// ```swift
/// let suggestions = try await CefProfile.default.autocomplete.suggestions(for: "swi")
/// if let top = suggestions.first, top.canBeDefault { field.complete(with: top.inlineCompletion) }
/// ```
///
/// - Important: Experimental. Chromium has no public interface for omnibox
///   ranking; this drives the Mojo interface of the `chrome://omnibox`
///   debugging page from a hidden service host. Of the internal-page APIs
///   it is the most likely to change when Chromium updates.
///
/// Search-engine suggestions are fetched over the network like Chrome's
/// omnibox does; filter on ``CefAutocompleteSuggestion/kind`` to keep only
/// local results.
@MainActor
public final class CefAutocomplete {
    /// Held, so the profile lives as long as this object is in use.
    private let profile: CefProfile

    init(profile: CefProfile) {
        self.profile = profile
    }

    /// Ranked suggestions for `text`, as typed with the caret at its end.
    ///
    /// A newer request supersedes one still running, which then returns no
    /// suggestions — call this on every keystroke.
    ///
    /// - Parameters:
    ///   - currentURL: The page the address bar belongs to, which some
    ///     providers take into account.
    ///   - allowsInlineCompletion: Pass `false` after the user deletes text,
    ///     as Chrome does, so the top suggestion does not complete inline.
    public func suggestions(
        for text: String, currentURL: URL? = nil, allowsInlineCompletion: Bool = true
    ) async throws -> [CefAutocompleteSuggestion] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try await profile.services.call(
            Self.module,
            "(s, a) => s.query(a.text, a.url, a.preventInline)",
            [
                "text": .string(text),
                "url": .string(currentURL?.absoluteString ?? ""),
                "preventInline": .bool(!allowsInlineCompletion),
            ]
        ).decode([MatchRecord]?.self)?.map(CefAutocompleteSuggestion.init) ?? []
    }

    /// Binds an own `mojom.OmniboxPageHandler` and collects the debug
    /// controller's final response for the latest query.
    static let module = CefServiceModule(
        name: "omnibox", hosts: [.omnibox],
        setup: """
        async () => {
          const m = await import('chrome://omnibox/omnibox_internals.mojom-webui.js');
          const router = new m.OmniboxPageCallbackRouter();
          const handler = m.OmniboxPageHandler.getRemote();
          handler.setClientPage(router.$.bindNewPipeAndPassRemote());
          const service = { pending: null };
          const finish = results => {
            const pending = service.pending;
            if (!pending) return;
            service.pending = null;
            clearTimeout(pending.timer);
            pending.resolve(results);
          };
          const convert = r => ({
            type: r.type, contents: r.contents, description: r.description,
            url: r.destinationUrl, fill: r.fillIntoEdit, inline: r.inlineAutocompletion,
            relevance: r.relevance, canBeDefault: r.allowedToBeDefaultMatch,
            starred: r.starred, isSearch: r.isSearchType,
          });
          router.handleNewAutocompleteResponse.addListener((type, response) => {
            const pending = service.pending;
            if (!pending || type !== m.AutocompleteControllerType.kDebug) return;
            if (response.inputText !== pending.text.trimStart()) return;
            pending.latest = response.combinedResults;
            if (response.done) finish(response.combinedResults.map(convert));
          });
          router.handleNewAutocompleteQuery.addListener(() => {});
          router.handleAnswerIconImageData.addListener(() => {});
          service.query = (text, url, preventInline) => new Promise(resolve => {
            finish(null);  // superseded
            const pending = { text, resolve, latest: [] };
            // Providers that never finish (a slow network) yield what has arrived.
            pending.timer = setTimeout(() => service.pending === pending && finish(pending.latest.map(convert)), 5000);
            service.pending = pending;
            handler.startOmniboxQuery(text, false, text.length, false, preventInline, false, url, url ? 4 : 0);
          });
          return service;
        }
        """)
}

private struct MatchRecord: Decodable {
    var type: String
    var contents: String
    var description: String
    var url: String?
    var fill: String
    var inline: String
    var relevance: Int
    var canBeDefault: Bool
    var starred: Bool
    var isSearch: Bool
}

extension CefAutocompleteSuggestion {
    fileprivate init(_ match: MatchRecord) {
        kind =
            switch match.type {
            case "url-what-you-typed": .typedURL
            case "search-what-you-typed", "search-other-engine": .search
            case "navsuggest", "navsuggest-personalized": .navigationSuggestion
            case "open-tab": .openTab
            case let type where type.hasPrefix("bookmark"): .bookmark
            case let type where type.hasPrefix("history"): .history
            case let type where type.hasPrefix("search"): .searchSuggestion
            default: .other
            }
        text = match.contents
        detail = match.description
        url = match.url.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        replacementText = match.fill
        inlineCompletion = match.inline
        relevance = match.relevance
        canBeDefault = match.canBeDefault
        isBookmarked = match.starred
        isSearch = match.isSearch
    }
}
