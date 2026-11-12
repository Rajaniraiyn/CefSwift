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
/// In a ``CefBrowserWindow`` whose ``CefChromiumUI`` presents
/// ``CefChromiumSurface/Kind/findBar`` as ``CefChromiumSurface/Presentation/custom``,
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
            search(backwards: false)
        }
    }

    /// Whether matches must have the same case as ``text``.
    public var isCaseSensitive = false {
        didSet {
            guard isCaseSensitive != oldValue else { return }
            search(backwards: false)
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
        if !text.isEmpty { search(backwards: false) }
    }

    /// Highlights the next match.
    public func next() {
        search(backwards: false)
    }

    /// Highlights the previous match.
    public func previous() {
        search(backwards: true)
    }

    /// Ends the session and clears the highlights, keeping the selection on
    /// the active match, as closing Chrome's find bar does.
    public func end() {
        guard isActive else { return }
        isActive = false
        browser?.stopFinding(clearingSelection: false)
    }

    private func search(backwards: Bool) {
        guard let browser else { return }
        if text.isEmpty {
            browser.stopFinding()
        } else {
            browser.find(text, backwards: backwards, caseSensitive: isCaseSensitive)
        }
    }
}
