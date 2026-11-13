import CCef
import Foundation

/// How a main-frame navigation finished.
public struct CefLoadResult: Sendable, Equatable {
    /// The address the main frame ended on, after redirects.
    public var url: URL?
    /// The HTTP status of the main document; `nil` when it has none: a
    /// same-document navigation, or a document Chromium reports no status
    /// for, such as `about:blank`.
    public var httpStatus: Int?
    /// Whether the navigation stayed in the document already shown, as a
    /// change of fragment does. It finishes as the address changes.
    public var isSameDocument: Bool

    public init(url: URL?, httpStatus: Int?, isSameDocument: Bool = false) {
        self.url = url
        self.httpStatus = httpStatus
        self.isSameDocument = isSameDocument
    }
}

/// One main-frame navigation started by ``CefBrowser/load(_:)``, to wait
/// for.
///
/// ```swift
/// let result = try await browser.load(url).waitUntilLoaded(timeout: .seconds(30))
/// print(result.httpStatus ?? 0)
/// ```
///
/// CEF gives navigations no identity, so the navigation is the first
/// main-frame navigation that starts as a direct load (a `load(_:)`, not a
/// link, script, reload or history step) after `load(_:)` was called. It
/// ends in one of these ways:
///
/// - **Finished**: the main frame's document committed and its `load`
///   event ran. A server redirect, or a client redirect (a script or
///   `<meta http-equiv="refresh">` navigating before the page finished),
///   is part of the navigation; ``CefLoadResult/url`` is where it ended.
/// - **Same document**: an address that differs from the page's only in
///   its fragment finishes as the address changes, with
///   ``CefLoadResult/isSameDocument`` set.
/// - **Failed**: ``CefLoadError``, as ``CefBrowserDelegate`` hears of it. A
///   navigation that never shows a new page — a download, a 204 or 205
///   response, ``CefBrowser/stopLoading()``, a ``CefNavigationDecision/cancel``
///   from the delegate — fails with `ERR_ABORTED`
///   (``CefLoadError/isCancellation``).
/// - **Superseded**: another main-frame navigation (a second `load(_:)`, a
///   link, a script, back or forward) started first:
///   ``CefError/navigationSuperseded``.
/// - **Crashed**: the page's render process ended while the committed
///   document loaded: ``CefError/renderProcessTerminated(_:)``.
/// - **Closed**: the browser closed: ``CefError/browserClosed``.
///
/// A navigation asked of a browser that is not created yet, still setting
/// up or discarded starts once the browser is (it is not superseded by the
/// browser's own set-up). Waiting ends on cancellation of the waiting task
/// (`CancellationError`) or when its `timeout` runs out
/// (``CefError/timedOut``); the navigation itself goes on.
@MainActor
public final class CefNavigation {
    /// The address passed to ``CefBrowser/load(_:)``.
    public let url: URL

    /// How the navigation ended; `nil` while it goes on.
    public private(set) var outcome: Result<CefLoadResult, any Error>?

    private let waiters = CefPendingOperations<CefLoadResult>()

    /// Whether only the fragment differs from the page shown when it was
    /// asked for, which Chromium navigates within the document.
    let isSameDocumentCandidate: Bool

    init(url: URL, isSameDocumentCandidate: Bool = false) {
        self.url = url
        self.isSameDocumentCandidate = isSameDocumentCandidate
    }

    /// A navigation that ended before it started.
    init(url: URL, failure: any Error) {
        self.url = url
        self.isSameDocumentCandidate = false
        outcome = .failure(failure)
    }

    /// Suspends until the navigation has finished and returns how; throws
    /// how it failed otherwise. See ``CefNavigation`` for each outcome.
    ///
    /// - Parameter timeout: How long to wait; `nil` waits for as long as
    ///   it takes. When it runs out the call throws ``CefError/timedOut``
    ///   and the navigation goes on.
    @discardableResult
    public func waitUntilLoaded(timeout: Duration? = nil) async throws -> CefLoadResult {
        try await withOptionalDeadline(timeout) { [self] in
            if let outcome { return try outcome.get() }
            return try await waiters.wait()
        }
    }

    /// Ends the navigation, once.
    func finish(_ result: Result<CefLoadResult, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiters.completeAll(result)
    }
}

// MARK: - Waiting for the browser

extension CefBrowser {
    /// Suspends until the browser has finished loading whatever it loads
    /// now, and returns how its last navigation finished; returns at once
    /// when it has loaded already.
    ///
    /// ```swift
    /// let browser = CefBrowser(url: url)
    /// // …once it is hosted:
    /// try await browser.waitUntilLoaded(timeout: .seconds(30))
    /// ```
    ///
    /// The wait covers every navigation that starts before it ends: a
    /// navigation another one supersedes is followed to the one that
    /// replaced it, and so is a ``load(_:)`` that has not started yet. To
    /// wait for one particular navigation, await the ``CefNavigation`` that
    /// ``load(_:)`` returns instead.
    ///
    /// - A browser not created yet, or still setting up, waits for its
    ///   first page; one that is never shown waits until `timeout`.
    /// - A discarded browser is restored, and the wait covers that load.
    /// - When the last navigation failed, the call throws its
    ///   ``CefLoadError`` (or ``CefError/renderProcessTerminated(_:)`` when
    ///   the page's renderer ended since), also when the browser has
    ///   settled already.
    /// - A navigation the page starts itself counts once Chromium has
    ///   started it.
    /// - It throws ``CefError/browserClosed`` when the browser closes,
    ///   `CancellationError` when the calling task is cancelled, and
    ///   ``CefError/timedOut`` when `timeout` runs out first.
    @discardableResult
    public func waitUntilLoaded(timeout: Duration? = nil) async throws -> CefLoadResult {
        try await withOptionalDeadline(timeout) { [self] in
            if state == .closed { throw CefError.browserClosed }
            if isDiscarded {
                restore()
            } else if state == .live, !isBootstrapping, !isLoading, loads.isIdle, let settled = loads.settledOutcome {
                return try settled.get()
            }
            return try await loads.waitUntilSettled()
        }
    }

    // MARK: Events, from the client

    /// `on_before_browse` for the main frame.
    func trackNavigationWillStart(url: URL?, transition: cef_transition_type_t, isRedirect: Bool, isCancelled: Bool) {
        guard !isBootstrapping else { return }
        loads.navigationWillStart(
            url: url, transition: CefLoadTracker.Transition(transition), isRedirect: isRedirect, isCancelled: isCancelled)
    }

    /// `on_load_start` for the main frame.
    func trackMainFrameDidCommit(url: URL?, transition: cef_transition_type_t) {
        guard !isBootstrapping else { return }
        loads.mainFrameDidCommit(url: url, transition: CefLoadTracker.Transition(transition))
    }

    /// `on_load_end` for the main frame.
    func trackMainFrameDidFinish(url: URL?, httpStatus: Int) {
        guard !isBootstrapping else { return }
        loads.mainFrameDidFinish(url: url, httpStatus: httpStatus)
    }

    /// `on_load_error` for the main frame.
    func trackMainFrameDidFail(_ error: CefLoadError) {
        guard !isBootstrapping else { return }
        loads.mainFrameDidFail(error)
    }

    /// `on_address_change` for the main frame.
    func trackMainFrameAddressDidChange(_ url: URL?) {
        guard !isBootstrapping else { return }
        loads.mainFrameAddressDidChange(url)
    }

    /// `on_loading_state_change`.
    func trackLoadingStateDidChange(isLoading: Bool) {
        guard !isBootstrapping else { return }
        loads.loadingDidChange(isLoading: isLoading, currentURL: url)
    }

    /// The page's render process ended.
    func trackRenderProcessDidTerminate(_ reason: CefTerminationReason) {
        loads.renderProcessDidTerminate(reason)
    }

    /// Registers a navigation ``load(_:)`` is about to start.
    func requestNavigation(to url: URL) -> CefNavigation {
        let shown = raw != nil && !isBootstrapping && !isDiscarded ? self.url : nil
        return loads.request(url, shownURL: shown)
    }
}

// MARK: - Tracking

/// Follows the main frame's navigations from CEF's load and request
/// handler events, and completes the ``CefNavigation``s and the
/// ``CefBrowser/waitUntilLoaded(timeout:)`` calls they end.
///
/// Pure state: the browser forwards CEF's events (main frame only, none
/// while it sets itself up), so it can be driven by tests too.
@MainActor
final class CefLoadTracker {
    /// The flags of a `cef_transition_type_t` the tracker reads.
    struct Transition: Sendable, Equatable {
        /// Started by `load_url`, `load_request` or browser creation.
        var isDirectLoad: Bool
        /// A script or `<meta>` refresh navigating before the page loaded.
        var isClientRedirect: Bool

        init(isDirectLoad: Bool = false, isClientRedirect: Bool = false) {
            self.isDirectLoad = isDirectLoad
            self.isClientRedirect = isClientRedirect
        }

        init(_ raw: cef_transition_type_t) {
            let value = raw.rawValue
            isDirectLoad = value & TT_DIRECT_LOAD_FLAG.rawValue != 0 && value & TT_FORWARD_BACK_FLAG.rawValue == 0
            isClientRedirect = value & TT_CLIENT_REDIRECT_FLAG.rawValue != 0
        }
    }

    /// A navigation that has started.
    private struct Ongoing {
        /// The ``CefNavigation`` it is; `nil` for one nobody asked for.
        var navigation: CefNavigation?
        /// Where it is going, after redirects.
        var url: URL?
        /// Whether its document has committed (`on_load_start`).
        var hasCommitted = false
    }

    /// The latest navigation asked for that has not started yet.
    private(set) var requested: CefNavigation?
    private var ongoing: Ongoing?
    /// How the last navigation ended, while nothing is loading.
    private(set) var settledOutcome: Result<CefLoadResult, any Error>?
    private let settleWaiters = CefPendingOperations<CefLoadResult>()
    /// An abort of ``ongoing`` that ends it on the next turn of the main
    /// actor, unless something tells first why it ended: Chromium reports
    /// the abort of a navigation another one replaces, and loading stopping
    /// for a renderer that crashed, before it reports the cause.
    private var heldAbort: CefLoadError?
    private var heldAbortGeneration = 0
    /// Whether the browser was asked to close. Chromium aborts its loads
    /// well before it reports the browser closed; until it does, or the
    /// close turns out cancelled, aborts wait.
    private var isClosing = false

    /// Whether no navigation is asked for or under way.
    var isIdle: Bool { requested == nil && ongoing == nil }

    /// Registers a navigation about to be asked of Chromium. A previous
    /// one that has not started is superseded.
    func request(_ url: URL, shownURL: URL?) -> CefNavigation {
        let navigation = CefNavigation(url: url, isSameDocumentCandidate: Self.differOnlyInFragment(url, shownURL))
        requested?.finish(.failure(CefError.navigationSuperseded))
        requested = navigation
        return navigation
    }

    /// Suspends until nothing is asked for or under way, and returns how
    /// the last navigation ended.
    func waitUntilSettled() async throws -> CefLoadResult {
        try await settleWaiters.wait()
    }

    // MARK: Events

    func navigationWillStart(url: URL?, transition: Transition, isRedirect: Bool, isCancelled: Bool) {
        if !isRedirect {
            // A new document: what aborted the one before is known now.
            heldAbort = nil
            isClosing = false
        }
        if isRedirect, ongoing != nil {
            ongoing?.url = url
        } else if transition.isDirectLoad, let requested {
            // The navigation `load(_:)` asked for.
            self.requested = nil
            replaceOngoing(with: Ongoing(navigation: requested, url: url))
        } else if transition.isClientRedirect, ongoing != nil {
            // The loading page moves on: the same navigation, to a new
            // document.
            ongoing?.url = url
            ongoing?.hasCommitted = false
        } else {
            replaceOngoing(with: Ongoing(navigation: nil, url: url))
        }
        if isCancelled {
            complete(.failure(CefLoadError(code: -3, message: "The delegate cancelled the navigation.", url: url)))
        }
    }

    func mainFrameDidCommit(url: URL?, transition: Transition) {
        isClosing = false
        if ongoing == nil {
            // No `on_before_browse` came for it.
            if transition.isDirectLoad, let requested {
                self.requested = nil
                ongoing = Ongoing(navigation: requested)
            } else {
                ongoing = Ongoing(navigation: nil)
            }
        }
        ongoing?.url = url
        ongoing?.hasCommitted = true
    }

    func mainFrameDidFinish(url: URL?, httpStatus: Int) {
        // A document this navigation replaced may report late.
        guard let ongoing, ongoing.hasCommitted else { return }
        complete(.success(CefLoadResult(url: url ?? ongoing.url, httpStatus: httpStatus > 0 ? httpStatus : nil)))
    }

    func mainFrameDidFail(_ error: CefLoadError) {
        guard let ongoing else { return }
        // A navigation this one replaced may report its abort late.
        if let failed = error.url, let going = ongoing.url, failed.absoluteString != going.absoluteString { return }
        if error.isCancellation {
            holdAbort(error)
        } else {
            complete(.failure(error))
        }
    }

    func mainFrameAddressDidChange(_ url: URL?) {
        guard ongoing == nil, let requested, requested.isSameDocumentCandidate,
              let url, url.absoluteString == requested.url.absoluteString
        else { return }
        self.requested = nil
        let result = CefLoadResult(url: url, httpStatus: nil, isSameDocument: true)
        requested.finish(.success(result))
        settle(.success(result))
    }

    /// CEF reports loading as stopped after every `on_load_end` and
    /// `on_load_error` of the load.
    func loadingDidChange(isLoading: Bool, currentURL: URL?) {
        guard !isLoading else { return }
        if let ongoing {
            guard heldAbort == nil else { return }
            let message = ongoing.hasCommitted
                ? "The page stopped loading before it finished."
                : "The navigation ended without showing a new page."
            holdAbort(CefLoadError(code: -3, message: message, url: ongoing.url))
        } else if isIdle {
            settle(settledOutcome ?? .success(CefLoadResult(url: currentURL, httpStatus: nil)))
        }
    }

    func renderProcessDidTerminate(_ reason: CefTerminationReason) {
        let error = CefError.renderProcessTerminated(reason)
        // Chromium sends these to the renderer without navigating.
        if let requested, Self.isRendererDebugURL(requested.url) {
            self.requested = nil
            requested.finish(.failure(error))
        }
        if ongoing?.hasCommitted == true {
            complete(.failure(error))
        } else if ongoing == nil {
            settle(.failure(error))
        }
    }

    /// The browser was asked to close.
    func browserWillClose() {
        isClosing = true
    }

    func browserDidClose() {
        heldAbort = nil
        let error = CefError.browserClosed
        requested?.finish(.failure(error))
        requested = nil
        ongoing?.navigation?.finish(.failure(error))
        ongoing = nil
        settledOutcome = .failure(error)
        settleWaiters.completeAll(.failure(error))
    }

    // MARK: Completion

    private func replaceOngoing(with next: Ongoing) {
        ongoing?.navigation?.finish(.failure(CefError.navigationSuperseded))
        ongoing = next
    }

    /// Ends ``ongoing`` with `abort` on the next turn, unless another
    /// navigation, a crash or the browser closing ends it first.
    private func holdAbort(_ abort: CefLoadError) {
        heldAbort = abort
        heldAbortGeneration &+= 1
        let generation = heldAbortGeneration
        Task { @MainActor [weak self] in self?.endHeldAbort(generation) }
    }

    private func endHeldAbort(_ generation: Int) {
        guard generation == heldAbortGeneration, let abort = heldAbort else { return }
        // Closing: the browser reports closed later, and ends it then.
        guard !isClosing else { return }
        complete(.failure(abort))
    }

    private func complete(_ result: Result<CefLoadResult, any Error>) {
        heldAbort = nil
        let ended = ongoing
        ongoing = nil
        ended?.navigation?.finish(result)
        settle(result)
    }

    /// Records how the last navigation ended, and completes the waiters
    /// once nothing else is under way.
    private func settle(_ result: Result<CefLoadResult, any Error>) {
        settledOutcome = result
        guard isIdle else { return }
        settleWaiters.completeAll(result)
    }

    /// Whether `url` is one of Chromium's addresses that crash or kill the
    /// renderer instead of loading (`chrome://crash`, `chrome://kill`, …).
    static func isRendererDebugURL(_ url: URL) -> Bool {
        guard url.scheme == "chrome" || url.scheme == "about", let host = url.host() else { return false }
        return ["crash", "kill", "hang", "shorthang", "memory-exhaust", "crashdump", "badcastcrash"].contains(host)
    }

    /// Whether `url` has a fragment and is `shown` otherwise.
    static func differOnlyInFragment(_ url: URL, _ shown: URL?) -> Bool {
        guard url.fragment != nil, let shown else { return false }
        func withoutFragment(_ url: URL) -> String? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string
        }
        return withoutFragment(url) != nil && withoutFragment(url) == withoutFragment(shown)
    }
}

/// Runs `operation`, under ``withDeadline(_:timeoutError:onTimeout:_:)``
/// throwing ``CefError/timedOut`` when there is a `timeout`.
@MainActor
func withOptionalDeadline<T>(
    _ timeout: Duration?, _ operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    guard let timeout else { return try await operation() }
    return try await withDeadline(timeout, timeoutError: CefError.timedOut, operation)
}
