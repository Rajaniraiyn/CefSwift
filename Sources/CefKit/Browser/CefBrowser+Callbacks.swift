import AppKit
import CCef
import Foundation
import Observation
import CefBase

// MARK: - Callbacks from the client

extension CefBrowser {
    func mainFrameDidStartLoading(_ url: URL?) {
        guard !isBootstrapping else { return }
        cancelDecisions { $0 == .page }
        pageScripting.mainFrameDidStartLoading()
        let wasDiscarded = isDiscarded
        pageDidStartLoading()
        // The new document reports its own icon. A restored page keeps the
        // one it had until then, so its tab does not flash empty.
        if !wasDiscarded {
            faviconURL = nil
            favicon = nil
        }
    }

    func applyTitle(_ title: String) {
        guard !isBootstrapping else { return }
        self.title = title
    }

    func applyURL(_ urlString: String) {
        guard !isBootstrapping else { return }
        url = URL(string: urlString)
    }

    func applyLoadingState(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard !isBootstrapping else { return }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isLoading { estimatedProgress = 1 }
        // Chromium restores each site's own zoom level as it navigates.
        refreshZoomLevel()
        refreshAudioMuted()
        if !isLoading { pageDidFinishLoading() }
    }

    func applyProgress(_ progress: Double) {
        guard !isBootstrapping else { return }
        estimatedProgress = progress
    }

    /// The page reported its icons, best first; downloads the first.
    func applyFavicon(_ candidates: [URL]) {
        guard !isBootstrapping else { return }
        let url = candidates.first
        guard url != faviconURL || (url != nil && favicon == nil) else { return }
        faviconURL = url
        // The previous icon stays until the new one arrives, so the tab
        // does not flash empty when a page swaps its icon.
        guard let url else {
            favicon = nil
            return
        }
        let callback = FaviconDownload { [weak self] image in
            // A newer icon, or a new page, may have replaced this one.
            guard let self, self.faviconURL == url else { return }
            self.favicon = image
        }.makeCallback()
        let started: Void? = withHost { host in
            CefStringUtil.withCefString(url.absoluteString) {
                host.pointee.download_image(host, $0, 1, UInt32(FaviconDownload.maximumSize), 0, callback)
            }
        }
        if started == nil { cefRelease(callback) }
    }

    func mainFrameDidFinishLoad(status: Int) {
        guard !isBootstrapping else { return }
        delegate?.browser(self, didFinishLoadWithStatus: status)
    }

    /// Asks the delegate about a main-frame navigation; `true` cancels it.
    func cancelsNavigation(_ action: CefNavigationAction) -> Bool {
        guard let delegate, !isBootstrapping else { return false }
        return delegate.browser(self, decidePolicyFor: action) == .cancel
    }

    func mainFrameDidFailLoad(_ error: CefLoadError) {
        // ERR_INVALID_AUTH_CREDENTIALS: with `CefRuntime.AuthenticationPromptPolicy.chromium`,
        // Chromium asks for credentials itself, in a window of its own.
        if error.code == -338, !isChromeStyle, CefRuntime.shared.configuration?.authenticationPrompt == .chromium {
            signInPromptURL = error.url
        }
        delegate?.browser(self, didFailLoad: error)
    }

    func renderProcessDidTerminate(_ reason: CefTerminationReason) {
        pageScripting.failPendingEvaluations()
        delegate?.browser(self, renderProcessDidTerminate: reason)
        renderProcessEnded()
    }

    /// A command from Chrome's UI or shortcuts. Returns `true` when it was
    /// handled and Chrome must not run it.
    func handleChromeCommand(_ command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        if delegate?.browser(self, handleChromeCommand: command, disposition: disposition) == true { return true }
        // Surfaces the window replaces or hides.
        if let window = CefBrowserWindow.hosting(self), window.handleSurfaceCommand(command) { return true }
        // Chrome runs the command after this returns.
        if command.isZoomCommand { CefBrowser.refreshZoomLevels() }
        return false
    }

    func applyFullscreen(_ isFullscreen: Bool) { self.isFullscreen = isFullscreen }
    func applyStatusText(_ text: String) { statusText = text }
    func applyFindResult(_ result: CefBrowser.FindResult) {
        findResult = result
        findSession.didReceive(result)
    }

    func applyDownload(_ download: CefDownload, control: CefRef<cef_download_item_callback_t>?) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index] = download
        } else {
            downloads.append(download)
        }
        // Kept while the download can go on, paused or interrupted included.
        downloadControls[download.id] = download.state.isFinished ? nil : control
        delegate?.browser(self, downloadDidUpdate: download)
    }

    /// Routes a window-open request. Returns `true` when CEF must not create
    /// its own popup or tab.
    func route(_ request: CefWindowOpenRequest) -> Bool {
        let decided = (delegate ?? CefDefaultBrowserDelegate.shared).browser(self, decideWindowOpenFor: request)
        switch CefWindowOpenPolicy.resolve(decided, for: request) {
        case .allowNativePopup:
            // Chromium opens it next, in a popup or a tab of its own window.
            CefRuntime.shared.chromiumWillOpen(request.targetURL, from: self, disposition: request.disposition)
            return false
        case .openInCurrentBrowser:
            if let url = request.targetURL { load(url) }
            return true
        case .deny, .handled:
            return true
        }
    }

    /// For a browser embedded as a child view: removes Chromium's view from
    /// the app's hierarchy, which is what lets Chromium finish closing it.
    /// Returns `false` for browsers that own their window or have no view.
    func detachEmbeddedView() -> Bool {
        guard isEmbeddedView, let native = nativeView else { return false }
        DispatchQueue.main.async { native.removeFromSuperview() }
        return true
    }

    /// What a pending delegate decision belongs to, which decides when it
    /// stops mattering.
    enum DecisionScope: Equatable {
        /// The current page: ends when the main frame starts loading
        /// another document.
        case page
        /// A JavaScript dialog: ends when Chromium resets dialog state.
        case dialog
        /// A permission prompt: ends when Chromium dismisses the prompt.
        case permissionPrompt(UInt64)
        /// An unresponsive page: ends when the page responds again.
        case unresponsive
        /// The browser: ends when it closes.
        case browser
    }

    struct PendingDecision {
        var scope: DecisionScope
        var cancel: () -> Void
    }

    /// Asks the delegate an asynchronous question and applies the answer.
    ///
    /// Every decision also ends when the browser closes. A decision that
    /// ends first has its task cancelled (so the default sheets dismiss
    /// themselves) and its answer is never applied; `apply` and what it
    /// holds, such as CEF's callback, are released when the delegate
    /// returns, which tells CEF the request was not answered.
    func decide<Decision: Sendable>(
        _ scope: DecisionScope,
        _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision,
        then apply: @escaping @MainActor (Decision) -> Void
    ) {
        let task = startDecision(scope, ask)
        Task {
            if let decision = await task.value { apply(decision) }
        }
    }

    /// Asks the delegate as ``decide(_:_:then:)`` does and returns the
    /// answer, or `nil` when the decision ended first.
    func decision<Decision: Sendable>(
        _ scope: DecisionScope, _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision
    ) async -> Decision? {
        await startDecision(scope, ask).value
    }

    private func startDecision<Decision: Sendable>(
        _ scope: DecisionScope, _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision
    ) -> Task<Decision?, Never> {
        let delegate = delegate ?? CefDefaultBrowserDelegate.shared
        nextDecisionID += 1
        let id = nextDecisionID
        // Runs after this returns, so the decision is registered first.
        let task = Task { () -> Decision? in
            let decision = await ask(delegate)
            guard pendingDecisions.removeValue(forKey: id) != nil else { return nil }
            return decision
        }
        pendingDecisions[id] = PendingDecision(scope: scope, cancel: task.cancel)
        return task
    }

    /// Ends the pending decisions whose scope matches.
    func cancelDecisions(where matches: (DecisionScope) -> Bool) {
        for (id, decision) in pendingDecisions where matches(decision.scope) {
            pendingDecisions[id] = nil
            decision.cancel()
        }
    }

    /// How many delegate decisions are waiting for an answer.
    @_spi(Testing) public var pendingDecisionCount: Int { pendingDecisions.count }

    func handleClosed() {
        guard state != .closed else { return }
        if discardPhase == .closing {
            browserDidCloseForDiscard()
            return
        }
        discardPhase = .none
        isDiscarded = false
        discardSnapshot = nil
        commandsAfterRestore = []
        restoreWaiters.completeAll(.failure(CefError.browserClosed))
        state = .closed
        isLoading = false
        canGoBack = false
        canGoForward = false
        isShowingDevTools = false
        frames = []
        downloadControls = [:]
        passkeyAuthenticator?.stop()
        passkeyAuthenticator = nil
        accessibilityDidClose()
        cancelDecisions { _ in true }
        devTools.invalidate()
        pageScripting.failPendingEvaluations()
        readyWaiters.completeAll(.failure(CefError.browserClosed))
        delegate?.browserDidClose(self)
        raw = nil
        client = nil
        CefRuntime.shared.unregister(self)
    }
}

/// Receives a favicon from `download_image` and converts it to an
/// `NSImage` with one representation per scale factor Chromium decoded.
private final class FaviconDownload: Sendable {
    /// The largest icon asked for, in points.
    static let maximumSize = 32

    private let completion: @MainActor @Sendable (NSImage?) -> Void

    init(completion: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        self.completion = completion
    }

    /// The returned +1 reference is consumed by `download_image`.
    func makeCallback() -> UnsafeMutablePointer<cef_download_image_callback_t> {
        let callback = cefAllocate(cef_download_image_callback_t.self, owner: self)
        callback.pointee.on_download_image_finished = { s, _, _, image in
            defer { cefRelease(image) }
            guard let owner = cefOwner(FaviconDownload.self, s) else { return }
            nonisolated(unsafe) let image = image
            MainActor.assumeIsolated { owner.completion(image.flatMap(FaviconDownload.makeImage)) }
        }
        return callback
    }

    @MainActor
    static func makeImage(_ image: UnsafeMutablePointer<cef_image_t>) -> NSImage? {
        let size = NSSize(width: image.pointee.get_width(image), height: image.pointee.get_height(image))
        guard size.width > 0, size.height > 0 else { return nil }
        let result = NSImage(size: size)
        // Exact representations first; failing those, whatever is closest to 1x.
        var scales: [Float] = [1, 2, 3].filter { image.pointee.has_representation(image, $0) != 0 }
        if scales.isEmpty { scales = [1] }
        for scale in scales {
            var width: Int32 = 0, height: Int32 = 0
            guard let png = image.pointee.get_as_png(image, scale, 1, &width, &height) else { continue }
            defer { cefRelease(png) }
            var data = Data(count: png.pointee.get_size(png))
            let count = data.count
            data.withUnsafeMutableBytes { _ = png.pointee.get_data(png, $0.baseAddress, count, 0) }
            guard let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = size
            result.addRepresentation(representation)
        }
        return result.representations.isEmpty ? nil : result
    }
}
