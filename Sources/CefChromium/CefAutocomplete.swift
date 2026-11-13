import CefKit
import Foundation

extension CefAutocomplete {
    /// One ranked suggestion for text typed into an address bar.
    public struct Suggestion: Sendable, Identifiable, Hashable {
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
}

extension CefAutocomplete {
    /// The suggestions for one text, as far as Chromium's providers have
    /// answered.
    public struct Result: Sendable, Hashable {
        /// The text the suggestions are for.
        public var text: String
        /// Ranked suggestions, best first.
        public var suggestions: [CefAutocomplete.Suggestion]
        /// Whether every provider has answered. The last result of a query
        /// is complete; earlier ones lack the providers still working, such
        /// as the search engine's suggestions while the network answers.
        public var isComplete: Bool
    }
}

/// Address-bar suggestions for a ``CefProfile``, ranked by Chromium's own
/// omnibox — history, bookmarks, open tabs, and the default search engine's
/// suggestions, in the order Chrome's omnibox shows them.
///
/// ```swift
/// for try await result in CefProfile.default.autocomplete.results(for: "swi") {
///     print(result.suggestions.map(\.text))  // local matches first, then the search engine's
/// }
/// ```
///
/// The latest query wins: starting one stops the profile's query still
/// running, in Chromium as well, so an address bar can query on every
/// keystroke without debouncing or cancelling anything itself.
/// ``results(following:currentURL:allowsInlineCompletion:)`` takes the
/// typed text as a sequence and does exactly that.
///
/// - Important: Experimental. Chromium has no public interface for omnibox
///   ranking; this drives the Mojo interface of the `chrome://omnibox`
///   debugging page from a hidden service host. Of the internal-page APIs
///   it is the most likely to change when Chromium updates.
///
/// Search-engine suggestions are fetched over the network like Chrome's
/// omnibox does; filter on ``CefAutocomplete/Suggestion/kind`` to keep only
/// local results.
@MainActor
public final class CefAutocomplete {
    /// Held, so the profile lives as long as this object is in use.
    private let profile: CefProfile
    /// The query running, which the next one stops.
    private var running: (generation: Int, task: Task<Void, Never>)?
    private var generation = 0

    init(profile: CefProfile) {
        self.profile = profile
    }

    /// Ranked suggestions for `text`, typed with the caret at its end, as
    /// Chromium's providers answer: matches from history, bookmarks and
    /// open tabs within milliseconds, the search engine's when the network
    /// answers. The stream ends after the result that
    /// ``Result/isComplete``.
    ///
    /// A newer query of the profile (this method,
    /// ``suggestions(for:currentURL:allowsInlineCompletion:)`` or
    /// ``results(following:currentURL:allowsInlineCompletion:)``) ends this
    /// stream, and ending the consuming task stops the query in Chromium.
    /// A consumer slower than the providers gets the newest result.
    ///
    /// - Parameters:
    ///   - currentURL: The page the address bar belongs to, which some
    ///     providers take into account.
    ///   - allowsInlineCompletion: Pass `false` after the user deletes text,
    ///     as Chrome does, so the top suggestion does not complete inline.
    public func results(
        for text: String, currentURL: URL? = nil, allowsInlineCompletion: Bool = true
    ) -> AsyncThrowingStream<CefAutocomplete.Result, Error> {
        let (stream, continuation) = AsyncThrowingStream<CefAutocomplete.Result, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        running?.task.cancel()
        generation += 1
        let generation = generation
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            running = nil
            continuation.yield(CefAutocomplete.Result(text: text, suggestions: [], isComplete: true))
            continuation.finish()
            return stream
        }
        let arguments: CefJSON = [
            "text": .string(text),
            "url": .string(currentURL?.absoluteString ?? ""),
            "preventInline": .bool(!allowsInlineCompletion),
        ]
        let task = Task { @MainActor [profile] in
            do {
                let final = try await profile.serviceHosts.call(
                    Self.module, "(s, a, c) => s.query(a.text, a.url, a.preventInline, c)", arguments,
                    as: [MatchRecord]?.self, isIdempotent: true
                ) { (partial: [MatchRecord]) in
                    continuation.yield(CefAutocomplete.Result(
                        text: text, suggestions: partial.map(CefAutocomplete.Suggestion.init), isComplete: false))
                }
                if !Task.isCancelled {
                    continuation.yield(CefAutocomplete.Result(
                        text: text, suggestions: (final ?? []).map(CefAutocomplete.Suggestion.init), isComplete: true))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            if self.running?.generation == generation { self.running = nil }
        }
        running = (generation, task)
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The complete ranked suggestions for `text`, typed with the caret at
    /// its end: the last result of
    /// ``results(for:currentURL:allowsInlineCompletion:)``.
    ///
    /// The latest query wins: one superseded by a newer query of the
    /// profile throws `CancellationError`, as does one whose task is
    /// cancelled, and Chromium stops working on it.
    public func suggestions(
        for text: String, currentURL: URL? = nil, allowsInlineCompletion: Bool = true
    ) async throws -> [CefAutocomplete.Suggestion] {
        var last: CefAutocomplete.Result?
        for try await result in results(for: text, currentURL: currentURL, allowsInlineCompletion: allowsInlineCompletion) {
            last = result
        }
        guard let last, last.isComplete else { throw CancellationError() }
        return last.suggestions
    }

    /// Suggestions for each text `texts` delivers — the contents of an
    /// address field as the user types — each query stopping the one
    /// before. Yields each query's results as they arrive; ends when
    /// `texts` ends and its last query has completed, or with the first
    /// error.
    ///
    /// ```swift
    /// let (texts, typed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
    /// // In the field's change handler: typed.yield(field.stringValue)
    /// for try await result in CefProfile.default.autocomplete.results(following: texts) {
    ///     print(result.text, result.suggestions.count)
    /// }
    /// ```
    public func results(
        following texts: AsyncStream<String>, currentURL: URL? = nil, allowsInlineCompletion: Bool = true
    ) -> AsyncThrowingStream<CefAutocomplete.Result, Error> {
        Self.latest(following: texts) { [self] text in
            results(for: text, currentURL: currentURL, allowsInlineCompletion: allowsInlineCompletion)
        }
    }

    /// The results of `query` for each of `texts`, each query's stream
    /// ended (and so its query cancelled) when the next text arrives.
    static func latest<Element: Sendable>(
        following texts: AsyncStream<String>,
        query: @escaping @MainActor (String) -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { @MainActor in
            var current: Task<Void, Never>?
            for await text in texts {
                current?.cancel()
                let results = query(text)
                current = Task { @MainActor in
                    do {
                        for try await result in results {
                            // A result that arrives as the next text does is stale.
                            if Task.isCancelled { break }
                            continuation.yield(result)
                        }
                    } catch is CancellationError {
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            // The consumer went away: its query stops too.
            if Task.isCancelled { current?.cancel() }
            await current?.value
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Binds an own `mojom.OmniboxPageHandler`, sends each response of the
    /// debug controller for the latest query as progress, and resolves with
    /// the one Chromium marks done.
    ///
    /// The handler has no call that stops a query. A query for no text is
    /// how its controller is stopped: `AutocompleteController::Start` stops
    /// every provider first (their network requests included), and no
    /// provider answers empty input.
    static let module = CefServiceHost.Module(
        name: "omnibox", hosts: [.omnibox],
        setup: """
        async () => {
          const m = await import('chrome://omnibox/omnibox_internals.mojom-webui.js');
          const router = new m.OmniboxPageCallbackRouter();
          const handler = m.OmniboxPageHandler.getRemote();
          handler.setClientPage(router.$.bindNewPipeAndPassRemote());
          const service = { pending: null };
          const settle = (pending, results) => {
            if (service.pending !== pending) return false;
            service.pending = null;
            clearTimeout(pending.timer);
            pending.resolve(results);
            return true;
          };
          const stop = () => handler.startOmniboxQuery('', false, 0, false, true, false, '', 0);
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
            if (response.done) settle(pending, response.combinedResults.map(convert));
            else pending.progress(response.combinedResults.map(convert));
          });
          router.handleNewAutocompleteQuery.addListener(() => {});
          router.handleAnswerIconImageData.addListener(() => {});
          service.query = (text, url, preventInline, { signal, progress }) => new Promise((resolve, reject) => {
            // A query still running when the next starts was superseded.
            if (service.pending) settle(service.pending, null);
            const pending = { text, resolve, progress, latest: [] };
            // Providers that never finish (a slow network) yield what has arrived.
            pending.timer = setTimeout(() => settle(pending, pending.latest.map(convert)), 5000);
            signal.addEventListener('abort', () => {
              if (settle(pending, null)) stop();
              reject(signal.reason);
            }, { once: true });
            service.pending = pending;
            handler.startOmniboxQuery(text, false, text.length, false, preventInline, false, url, url ? 4 : 0);
          });
          return service;
        }
        """)
}

struct MatchRecord: Decodable {
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

extension CefAutocomplete.Suggestion {
    init(_ match: MatchRecord) {
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
