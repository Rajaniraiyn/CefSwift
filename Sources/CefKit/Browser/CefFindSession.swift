import Foundation
import Observation

/// Find in page, as an observable model for a find bar of your own.
///
/// Each browser has one, ``CefBrowser/findSession``. Setting ``text``
/// searches as the user types; ``matchCount`` and ``activeMatch`` follow
/// Chromium's results; ``next()`` and ``previous()`` move between matches;
/// ``end()`` clears the highlights.
///
/// ```swift
/// struct FindBar: View {
///     @Bindable var session: CefFindSession
///
///     var body: some View {
///         HStack {
///             TextField("Find", text: $session.text)
///             Text("\(session.activeMatch) of \(session.matchCount)")
///             Button("Previous", systemImage: "chevron.up", action: session.previous)
///             Button("Next", systemImage: "chevron.down", action: session.next)
///             Button("Done", action: session.end)
///         }
///     }
/// }
/// ```
///
/// In a ``CefWindow`` whose find bar CefChromium presents with your
/// own interface (`setCustomPresentation(for: .findBar)` or `setFindBar(_:)`),
/// ⌘F and ``CefChromeCommand/find`` begin the session instead of showing
/// Chromium's find bar.
@MainActor
@Observable
public final class CefFindSession {
    /// The text searched for. Setting it searches from the top of the
    /// page; an empty string clears the highlights.
    public var text = "" {
        didSet {
            guard text != oldValue else { return }
            search(backwards: false, isNewSearch: true)
        }
    }

    /// Whether matches must have the same case as ``text``.
    public var isCaseSensitive = false {
        didSet {
            guard isCaseSensitive != oldValue else { return }
            search(backwards: false, isNewSearch: true)
        }
    }

    /// Whether a find bar should show: from ``begin()`` until ``end()``.
    public private(set) var isActive = false

    /// How many matches the page has, as counted so far.
    public var matchCount: Int { browser?.findResult?.matchCount ?? 0 }
    /// The highlighted match, from 1; 0 when there is none.
    public var activeMatch: Int { browser?.findResult?.activeMatchIndex ?? 0 }
    /// Whether Chromium has finished counting matches.
    public var isComplete: Bool { browser?.findResult?.isFinal ?? true }

    @ObservationIgnored private weak var browser: CefBrowser?

    init(browser: CefBrowser) {
        self.browser = browser
    }

    /// Starts a session, keeping the last search text, as a find bar
    /// opening does, and searches for it again.
    public func begin() {
        isActive = true
        if !text.isEmpty { search(backwards: false, isNewSearch: true) }
    }

    /// Highlights the next match.
    public func next() {
        search(backwards: false, isNewSearch: false)
    }

    /// Highlights the previous match.
    public func previous() {
        search(backwards: true, isNewSearch: false)
    }

    /// Ends the session and clears the highlights, keeping the selection on
    /// the active match, as closing Chrome's find bar does.
    public func end() {
        guard isActive else { return }
        isActive = false
        browser?.stopFinding(clearingSelection: false)
    }

    /// Whether the search just started still has to select its first match.
    @ObservationIgnored private var selectsFirstMatch = false

    private func search(backwards: Bool, isNewSearch: Bool) {
        guard let browser else { return }
        if text.isEmpty {
            selectsFirstMatch = false
            browser.stopFinding()
        } else {
            // A new search only highlights the matches: Chromium reports
            // them with no active match (ordinal 0, empty selection) until
            // the next find request. didReceive(_:) makes that request once.
            selectsFirstMatch = isNewSearch
            browser.find(text, backwards: backwards, caseSensitive: isCaseSensitive)
        }
    }

    /// Selects the first match of a new search once Chromium has counted
    /// them, as Chrome's find bar does.
    func didReceive(_ result: CefBrowser.FindResult) {
        guard selectsFirstMatch, result.isFinal else { return }
        selectsFirstMatch = false
        guard result.matchCount > 0, result.activeMatchIndex <= 0, !text.isEmpty else { return }
        browser?.find(text, backwards: false, caseSensitive: isCaseSensitive)
    }
}
