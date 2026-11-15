import AppKit
import CCef
import CefBase

/// A page Chromium opened in one of its own tabbed windows, passed to
/// ``CefRuntime/onChromeTab``.
///
/// Chromium opens these by itself: a link from `chrome://settings` to the
/// password manager, a ⌘-click or ⇧-click that a Chrome-style page's
/// delegate left to Chromium (``CefWindowOpenDecision/allowNativePopup``),
/// Chrome commands such as ``CefChromeCommand/newTab``, and tabs restored
/// from an earlier session. The page exists and has started loading;
/// its window is kept off screen until the handler answers.
@MainActor
public struct CefChromeTabRequest {
    /// The page Chromium created. It is live, and listed in
    /// ``CefRuntime/pages``.
    public let page: CefPage
    /// The page it opens.
    public let url: URL
    /// The profile it belongs to; `nil` for a profile Chromium made itself,
    /// such as the one behind its own incognito windows.
    public let profile: CefProfile?
    /// The page that asked for it, for a link opened in a new tab
    /// or window; `nil` when Chromium opened it on its own.
    public let opener: CefPage?
    /// Where the opener's page asked for it to open; ``CefWindowOpenDisposition/unknown``
    /// when Chromium opened it on its own.
    public let disposition: CefWindowOpenDisposition
}

/// The answer to a ``CefChromeTabRequest``.
public enum CefChromeTabDecision: Sendable, Equatable {
    /// Show the page in Chromium's window, with Chrome's tab strip and
    /// toolbar. The page then reaches ``CefRuntime/onPageCreated``.
    case showInChromeWindow
    /// Close the page, and Chromium's window with it unless that window
    /// shows other tabs. Return this once you have opened
    /// ``CefChromeTabRequest/url`` in your own UI.
    case close
}

@MainActor private var chromeTabHandler: ((CefChromeTabRequest) -> CefChromeTabDecision)?
@MainActor private var pendingOpens = CefPendingChromiumOpens()

extension CefRuntime {
    /// Decides what happens to each page Chromium opens in a tabbed
    /// window of its own design (see ``CefChromeTabRequest``). Open the
    /// request's URL in your own window or tab and answer
    /// ``CefChromeTabDecision/close``, or answer
    /// ``CefChromeTabDecision/showInChromeWindow``:
    ///
    /// ```swift
    /// CefRuntime.shared.onChromeTab = { request in
    ///     tabs.open(request.url, profile: request.profile, after: request.opener)
    ///     return .close
    /// }
    /// ```
    ///
    /// Chromium's window is never seen while the handler decides. CEF
    /// cannot move a page out of Chromium's tab strip, so a page
    /// shown elsewhere is a new one, which starts from the URL: Chromium's
    /// page has no back-forward list yet, and a form submission
    /// (POST) opened in a new tab is loaded again as a plain request.
    ///
    /// Popups and new tabs a ``CefWindow`` opens in a view of its
    /// own — `window.open`, and links with `target=_blank` — do not come
    /// here: ``CefWindow/onPopup`` takes those pages themselves,
    /// with their opener and history. DevTools does not come here either.
    /// Pages CefKit keeps in hidden windows (internal service hosts, for
    /// tab discarding and CefChromium's stores) that Chromium restores
    /// from a crashed session are closed, never handed over.
    ///
    /// When `nil`, Chromium shows these pages in its own windows. Leave
    /// it `nil` in apps that use
    /// ``openChromeWindow(url:frame:configuration:delegate:)``, whose new tabs
    /// Chromium opens the same way.
    public var onChromeTab: ((CefChromeTabRequest) -> CefChromeTabDecision)? {
        get { chromeTabHandler }
        set { chromeTabHandler = newValue }
    }

    /// Notes that `opener`'s page asked Chromium to open `url`; the page
    /// Chromium creates for it next is matched with the request.
    func chromiumWillOpen(_ url: URL?, from opener: CefPage, disposition: CefWindowOpenDisposition) {
        pendingOpens.record(CefPendingChromiumOpens.Entry(
            openerID: opener.identifier, url: url, disposition: disposition), now: .now)
    }

    /// Takes the request a popup Chromium hosts in a view answered, so it
    /// is not matched with a later page.
    func chromiumDidOpenPopup(from opener: CefPage) {
        pendingOpens.removeFirst(openerID: opener.identifier)
    }

    /// Hands `page`, which Chromium just created without an opener, to
    /// ``onChromeTab``. Returns whether it did; otherwise the page is
    /// announced through ``onPageCreated`` at once.
    ///
    /// Either way, a restored service page is closed: Chromium saves the
    /// hidden windows of ``CefServiceHosts`` in its session like any
    /// other and reopens them after a crash.
    func routeChromiumPage(_ page: CefPage, profile: CefProfile?) -> Bool {
        guard page.opener == nil else { return false }
        let entry = pendingOpens.take(now: .now)
        guard chromeTabHandler != nil else {
            Task {
                if let url = await page.firstNavigationURL(), CefServiceHosts.isServicePage(url) {
                    page.close(force: true)
                }
            }
            return false
        }
        let hider = ChromiumWindowHider(page: page)
        Task {
            let url = await page.firstNavigationURL() ?? entry?.url
            guard page.state != .closed else { return hider.stop() }
            guard let url, !CefServiceHosts.isServicePage(url), let handler = chromeTabHandler else {
                page.close(force: true)
                return
            }
            let request = CefChromeTabRequest(
                page: page, url: url, profile: profile,
                opener: entry.flatMap { self.page(withIdentifier: $0.openerID) },
                disposition: entry?.disposition ?? .unknown)
            switch handler(request) {
            case .close:
                page.close(force: true)
            case .showInChromeWindow:
                hider.reveal()
                onPageCreated?(page)
            }
        }
        return true
    }
}

/// Page requests to open a tab or window that Chromium handles itself, in
/// the order made. CEF does not say which request a page it creates
/// answers, but creates that page at once, before it handles another.
struct CefPendingChromiumOpens {
    struct Entry: Equatable {
        var openerID: Int32
        var url: URL?
        var disposition: CefWindowOpenDisposition
        var date: ContinuousClock.Instant = .now
    }

    /// How long a request waits for its page. Chromium creates it in
    /// the same task; one it blocked or aborted never comes.
    static let lifetime: Duration = .seconds(2)

    private(set) var entries: [Entry] = []

    mutating func record(_ entry: Entry, now: ContinuousClock.Instant) {
        var entry = entry
        entry.date = now
        entries.append(entry)
    }

    /// The oldest request still waiting, removed; expired ones are dropped.
    mutating func take(now: ContinuousClock.Instant) -> Entry? {
        entries.removeAll { now - $0.date > Self.lifetime }
        return entries.isEmpty ? nil : entries.removeFirst()
    }

    mutating func removeFirst(openerID: Int32) {
        if let index = entries.firstIndex(where: { $0.openerID == openerID }) { entries.remove(at: index) }
    }
}

/// Keeps the window Chromium shows one page in off screen until
/// ``reveal()`` or the page closes.
///
/// Chromium creates and shows that window after announcing the page,
/// and fades it in, which leaves time to take it off screen before it is
/// seen. The window is the one holding the page's own view; a window
/// that was on screen already (Chromium added the page to it as a tab)
/// is left alone, as is every other window.
@MainActor
private final class ChromiumWindowHider {
    private weak var page: CefPage?
    private var observer: NSObjectProtocol?
    private var hidden: NSWindow?
    private let alreadyVisible: Set<ObjectIdentifier>

    init(page: CefPage) {
        self.page = page
        alreadyVisible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            // Holds the hider until stop().
            MainActor.assumeIsolated { self.update() }
        }
        update()
    }

    private func update() {
        guard let page, page.state != .closed else { return stop() }
        if hidden == nil, let window = page.nativeView?.window, !alreadyVisible.contains(ObjectIdentifier(window)) {
            hidden = window
        }
        guard let hidden, hidden.isVisible || hidden.alphaValue > 0 else { return }
        hidden.alphaValue = 0
        hidden.orderOut(nil)
    }

    /// Shows the window as Chromium would have.
    func reveal() {
        let window = hidden ?? page?.nativeView?.window
        stop()
        guard let window else { return }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        hidden = nil
    }
}

extension CefPage {
    /// The first URL a page Chromium created navigates to; `nil` if it
    /// shows nothing within `timeout`.
    func firstNavigationURL(timeout: Duration = .seconds(3)) async -> URL? {
        let deadline = ContinuousClock.now + timeout
        while url == nil || url?.absoluteString == "about:blank", state != .closed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return url?.absoluteString == "about:blank" ? nil : url
    }
}
