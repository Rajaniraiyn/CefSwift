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
        // The page being left is not the one an unresponsive question,
        // or the reload it asked for, was about.
        endUnresponsiveEpisode()
        pageScripting.mainFrameDidStartLoading()
        let wasDiscarded = isDiscarded
        // The document has committed, so a level set before the browser
        // existed applies to its site.
        applyPendingZoomLevel(for: url)
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
        let callback = ImageDownload { [weak self] image in
            // A newer icon, or a new page, may have replaced this one.
            guard let self, self.faviconURL == url else { return }
            self.favicon = image
        }.makeCallback()
        let started: Void? = withHost { host in
            CefStringUtil.withCefString(url.absoluteString) {
                host.pointee.download_image(host, $0, 1, UInt32(ImageDownload.maximumFaviconSize), 0, callback)
            }
        }
        if started == nil { cefRelease(callback) }
    }

    /// The image at `url`, as Chromium decodes it for the page, at its
    /// full size; `nil` when it cannot be loaded.
    func downloadImage(_ url: URL) async -> NSImage? {
        // The image stays on the main actor from the callback to the
        // caller; the box only carries it through the continuation.
        await withCheckedContinuation { (continuation: CheckedContinuation<DownloadedImage, Never>) in
            let callback = ImageDownload { image in
                continuation.resume(returning: DownloadedImage(image: image))
            }.makeCallback()
            let started: Void? = withHost { host in
                CefStringUtil.withCefString(url.absoluteString) {
                    host.pointee.download_image(host, $0, 0, 0, 0, callback)
                }
            }
            if started == nil {
                cefRelease(callback)
                continuation.resume(returning: DownloadedImage(image: nil))
            }
        }.image
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
        // Modules that handle commands in CefWindows (CefChromium).
        if let window = CefWindow.hosting(self), window.intercept(command) { return true }
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

    func applyDownload(_ snapshot: CefDownload.Snapshot, control: CefRef<cef_download_item_callback_t>?) {
        let download = effectiveProfile.trackDownload(snapshot, startedBy: self)
        download.apply(snapshot)
        // Kept while the download can go on, paused or interrupted included.
        download.control = download.state.isFinished ? nil : control
    }

    /// Routes a window-open request. Returns `true` when CEF must not create
    /// its own popup or tab.
    func route(_ request: CefWindowOpenRequest) -> Bool {
        let decided = (delegate ?? CefDefaultBrowserDelegate.shared).browser(self, decideWindowOpenFor: request)
        switch CefWindowOpenPolicy.resolve(decided, for: request) {
        case .allowNativePopup where attachmentsPrepareBeforeFirstDocument:
            // Chromium would create it and run its first document before
            // the attachments are in place; see openPopupInNewBrowser.
            openPopupInNewBrowser(request)
            return true
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

    /// Opens what a page asked for in a browser CefKit creates, for a
    /// browser with an attachment that prepares before the first document
    /// (``CefBrowserAttachment/preparesBeforeFirstDocument``).
    ///
    /// A native popup is created by Chromium and runs its first document
    /// at once, before an attachment can prepare it. This browser instead
    /// has the opener's configuration and is bootstrapped as every browser
    /// CefKit creates is: the attachments are in place before its first
    /// document starts. It arrives where a
    /// native popup would: ``CefBrowserDelegate/browser(_:didOpen:)``, then
    /// the opener's window's ``CefWindow/onPopup``, or a window of
    /// its own. The page cannot script it: `window.open` returns `null` and
    /// the popup has no `window.opener`. A blank popup (no URL) is refused.
    func openPopupInNewBrowser(_ request: CefWindowOpenRequest) {
        guard let url = request.targetURL else { return }
        let popup = CefBrowser(url: url, configuration: configuration, delegate: delegate)
        popup.opener = self
        popup.popupFeatures = request.features
        delegate?.browser(self, didOpen: popup)
        let openerWindow = CefWindow.hosting(self)
        var windowConfiguration = openerWindow?.configuration ?? CefWindow.Configuration()
        windowConfiguration.frame = nil
        let window = CefWindow(browser: popup, configuration: windowConfiguration)
        if let onPopup = openerWindow?.onPopup {
            onPopup(window)
        } else {
            window.show()
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
    package enum DecisionScope: Equatable {
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
    /// returns, which tells CEF the request was not answered. The check
    /// that the decision is still pending and `apply` run together on the
    /// main actor, with no suspension between them, so nothing can end the
    /// decision after it is found valid and before it is applied.
    func decide<Decision: Sendable>(
        _ scope: DecisionScope,
        _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision,
        then apply: @escaping @MainActor (Decision) -> Void
    ) {
        startDecision(scope, ask, then: apply)
    }

    /// Asks a question tracked as ``decide(_:_:then:)`` tracks the
    /// delegate's, such as one a module's own delegate answers, and returns
    /// the answer, or `nil` when the decision ended first: `ask`'s task is
    /// cancelled when `scope` ends or the browser closes.
    ///
    /// The answer was valid when the decision was consumed, but the caller
    /// resumes after that, so a caller that applies it through further
    /// suspensions must check again that what it applies to still exists.
    package func decision<Decision: Sendable>(
        _ scope: DecisionScope, _ ask: @escaping @MainActor () async -> Decision
    ) async -> Decision? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Decision?, Never>) in
            // Exactly one of the two runs: the asking task always finishes.
            startDecision(
                scope, { _ in await ask() },
                then: { continuation.resume(returning: $0) }, ended: { continuation.resume(returning: nil) })
        }
    }

    /// Registers the decision, then asks. `ended` runs instead of `apply`
    /// when the decision ended before the delegate answered.
    private func startDecision<Decision: Sendable>(
        _ scope: DecisionScope,
        _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision,
        then apply: @escaping @MainActor (Decision) -> Void,
        ended: @escaping @MainActor () -> Void = {}
    ) {
        let delegate = delegate ?? CefDefaultBrowserDelegate.shared
        nextDecisionID += 1
        let id = nextDecisionID
        // Runs after this returns, so the decision is registered first.
        let task = Task { @MainActor in
            let decision = await ask(delegate)
            // Check-and-consume, then apply, with no suspension between.
            guard pendingDecisions.removeValue(forKey: id) != nil else {
                ended()
                return
            }
            apply(decision)
        }
        pendingDecisions[id] = PendingDecision(scope: scope, cancel: task.cancel)
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
        // Closed while waiting for its profile: nothing is created later.
        dropDeferredCreation()
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
        for download in downloads { download.control = nil }
        for attachment in configuration.attachments { attachment.browserDidClose(self) }
        accessibilityDidClose()
        cancelDecisions { _ in true }
        endUnresponsiveEpisode()
        devTools.invalidate()
        pageScripting.failPendingEvaluations()
        readyWaiters.completeAll(.failure(CefError.browserClosed))
        delegate?.browserDidClose(self)
        raw = nil
        client = nil
        CefRuntime.shared.unregister(self)
    }
}

/// Receives an image, such as a favicon, from `download_image` and
/// converts it to an `NSImage` with one representation per scale factor
/// Chromium decoded.
final class ImageDownload: Sendable {
    /// The largest favicon asked for, in points.
    static let maximumFaviconSize = 32

    private let completion: @MainActor @Sendable (NSImage?) -> Void

    init(completion: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        self.completion = completion
    }

    /// The returned +1 reference is consumed by `download_image`.
    func makeCallback() -> UnsafeMutablePointer<cef_download_image_callback_t> {
        let callback = cefAllocate(cef_download_image_callback_t.self, owner: self)
        callback.pointee.on_download_image_finished = { s, _, _, image in
            defer { cefRelease(image) }
            guard let owner = cefOwner(ImageDownload.self, s) else { return }
            nonisolated(unsafe) let image = image
            MainActor.assumeIsolated { owner.completion(image.flatMap(ImageDownload.makeImage)) }
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

/// An image on its way through a continuation, made and used on the main
/// actor.
private struct DownloadedImage: @unchecked Sendable {
    let image: NSImage?
}
