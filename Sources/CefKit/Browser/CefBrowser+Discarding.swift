import AppKit
import CCef
import CefBase
import Foundation

extension CefBrowser {
    /// A reason a browser cannot be discarded right now.
    ///
    /// Each one is a fact Chromium or CefKit knows natively, except
    /// ``beforeUnloadHandler``, which reads the page's listeners (not its
    /// content) through the DevTools Protocol.
    /// Chrome-style browsers can report all of them; browsers in a
    /// `CefWebView` all but ``exempt``, ``pictureInPicture`` and
    /// ``connectedToDevice``.
    public enum DiscardBlocker: Sendable, Hashable, CustomStringConvertible {
        /// The browser is on screen: the selected tab of a visible window, or
        /// a view in one.
        case visible
        /// Chromium protects the tab: an extension, pinning, or a setting
        /// or enterprise policy opted it out.
        case exempt
        /// The browser is not open, is still loading, or shows DevTools.
        case notLoaded
        /// The page is playing sound, or did so in the last minute.
        case playingAudio
        /// The page uses the camera, microphone or screen capture, or is being
        /// cast.
        case capturingMedia
        /// The page shows picture in picture (Chrome style only).
        case pictureInPicture
        /// The page is connected to a Bluetooth or USB device (Chrome style
        /// only).
        case connectedToDevice
        /// Chromium saw the user type into the page or change its form
        /// fields.
        case formInteraction
        /// A frame of the page, the main one or any `iframe`, has a
        /// `beforeunload` listener or `onbeforeunload` handler: it may ask
        /// before it is left.
        case beforeUnloadHandler
        /// The browser's DevTools window is open.
        case devToolsOpen
        /// A download the browser started is still in progress.
        case downloading
        /// CefKit could not tell whether the page may be unloaded, and keeps it:
        /// a check failed or timed out, Chromium gave a reason CefKit does not
        /// know, or Chromium lists no tab, or more than one, that could be this
        /// browser's. The string says which.
        case unknown(String)

        public var description: String {
            switch self {
            case .visible: "visible"
            case .exempt: "exempt"
            case .notLoaded: "notLoaded"
            case .playingAudio: "playingAudio"
            case .capturingMedia: "capturingMedia"
            case .pictureInPicture: "pictureInPicture"
            case .connectedToDevice: "connectedToDevice"
            case .formInteraction: "formInteraction"
            case .beforeUnloadHandler: "beforeUnloadHandler"
            case .devToolsOpen: "devToolsOpen"
            case .downloading: "downloading"
            case .unknown(let reason): "unknown(\(reason))"
            }
        }
    }
}

extension CefBrowser {
    /// Why ``CefBrowser/discard()`` did not discard a browser.
    public enum DiscardError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Something on the page, or the browser's situation, keeps it loaded.
        case blocked(Set<CefBrowser.DiscardBlocker>)
        /// Chromium did not discard the page.
        case failed(String)

        public var description: String {
            switch self {
            case .blocked(let blockers): "not discardable: " + blockers.map(\.description).sorted().joined(separator: ", ")
            case .failed(let message): message
            }
        }
    }
}

/// How far discarding a browser has got.
enum DiscardPhase {
    /// Loaded, or never loaded.
    case none
    /// Checks passed; the page is being captured and unloaded.
    case discarding
    /// Chromium discarded the page and kept the browser (Chrome style).
    case discarded
    /// The Chromium browser is closing (Alloy style)…
    case closing
    /// …and has closed; a new one is created when the browser is shown.
    case closed
    /// The page is loading again; commands that waited run when it is done.
    case restoring
}

/// The document a discard checked: unloading goes ahead only on the same one.
private struct DiscardCheckpoint: Equatable {
    var navigationGeneration: Int
    var url: URL?

    @MainActor init(_ browser: CefBrowser) {
        navigationGeneration = browser.navigationGeneration
        url = browser.url
    }
}

// MARK: - Discarding

extension CefBrowser {
    /// Frees the memory of this browser's page while keeping the browser:
    /// its renderer process exits, and the page loads again the moment the
    /// browser is shown, navigated or used.
    ///
    /// ```swift
    /// do {
    ///     try await tab.discard()
    /// } catch .blocked(let blockers) {
    ///     print("kept loaded:", blockers)
    /// }
    /// ```
    ///
    /// Only a browser that is off screen and that nothing in
    /// ``discardBlockers()`` holds can be discarded; the error lists what
    /// does. Discarding a discarded browser does nothing, and nothing is
    /// discarded once the app is quitting.
    ///
    /// CefKit never discards a browser on its own: when to discard (after
    /// a tab has been hidden a while, under memory pressure, never for
    /// tabs the user pinned) is the app's policy. ``lifecycle`` and
    /// ``lifecycleChangedAt`` say how long a browser has been hidden.
    ///
    /// A browser in a ``CefWindow`` or a Chrome UI window is
    /// discarded by Chromium itself and keeps its back/forward list and
    /// scroll position. A browser in a `CefWebView` is discarded by closing
    /// its Chromium browser and creating a new one in the same view when it
    /// comes back: it keeps its address, title, icon and zoom, but its
    /// back/forward list starts again from the current page. In both cases
    /// bridges and user scripts work as before, DevTools event streams keep
    /// delivering, and form input that was not submitted is lost.
    public func discard() async throws(CefBrowser.DiscardError) {
        guard !isDiscarded else { return }
        guard !CefRuntime.shared.isTerminating else { throw .failed("The app is quitting.") }
        guard discardPhase == .none else { throw .failed("The browser is already being discarded or restored.") }
        let checkpoint = DiscardCheckpoint(self)
        let blockers = await discardBlockers()
        guard blockers.isEmpty else { throw .blocked(blockers) }
        // The page may have changed while the checks ran.
        try checkStillDiscardable(since: checkpoint)

        discardPhase = .discarding
        delegate?.browserWillDiscard(self)
        let snapshot = await withTimeout(.seconds(2)) { try await self.snapshot() }.flatMap(NSImage.init(data:))
        do {
            // Immediately before unloading: nothing the delegate or the
            // snapshot waited for may have shown, navigated or busied it.
            try checkStillDiscardable(since: checkpoint)
            if isChromeStyle {
                try await discardInChromium()
            } else {
                try await discardByClosing()
            }
        } catch {
            if discardPhase == .discarding { discardPhase = .none }
            throw error
        }
        discardSnapshot = snapshot
        delegate?.browserDidDiscard(self)
    }

    /// Loads a discarded browser's page again now, even while it is hidden.
    /// Showing, navigating or using a browser does this by itself.
    public func restore() {
        guard isDiscarded else { return }
        switch discardPhase {
        case .discarded:
            // Chromium loads a discarded tab again on reload, as on show.
            raw.map { $0.pointer.pointee.reload($0.pointer) }
        case .closed:
            guard state == .live else { return }
            if case .offscreen = configuration.rendering, let offscreenHost = restoringOffscreenHost {
                host(offscreenIn: offscreenHost, size: offscreenHost.offscreenViewInfo.size)
            } else if let view = hostView, view.window != nil {
                host(windowedIn: view)
            }
            // Otherwise the browser is created as soon as a view hosts it.
        default:
            break
        }
    }

    /// What keeps this browser from being discarded now; empty when
    /// ``discard()`` would discard it.
    ///
    /// Every blocker but ``CefBrowser/DiscardBlocker/beforeUnloadHandler``
    /// is a fact Chromium or CefKit knows natively; that one reads the
    /// page's listeners through the DevTools Protocol, and only when
    /// nothing else blocks, so a set with another blocker may lack it. No
    /// check reads the page's content. A check that cannot be made counts
    /// as a blocker, ``CefBrowser/DiscardBlocker/unknown(_:)``. Where each
    /// comes from:
    ///
    /// - ``CefBrowser/DiscardBlocker/visible``, ``CefBrowser/DiscardBlocker/notLoaded``,
    ///   ``CefBrowser/DiscardBlocker/devToolsOpen``, ``CefBrowser/DiscardBlocker/downloading``
    ///   and ``CefBrowser/DiscardBlocker/capturingMedia``: the browser's own
    ///   state in CefKit (its view or window, CEF's load and DevTools state,
    ///   its downloads, `on_media_access_change`), for both runtime styles.
    /// - ``CefBrowser/DiscardBlocker/beforeUnloadHandler``: the window
    ///   listeners of every frame, `onbeforeunload` included, asked of the
    ///   DevTools Protocol (`DOMDebugger.getEventListeners`), for both
    ///   styles; a cross-site frame is asked in a session attached to it
    ///   for the call and detached again. Asked last, once every native
    ///   check has found nothing, it attaches the browser's DevTools
    ///   session (``CefBrowser/devTools``) if nothing had; no domain is
    ///   enabled. CEF keeps a browser's session attached until the browser
    ///   closes, or is discarded by closing it, and offers no way to detach
    ///   it. Chromium's page graph would have the answer without DevTools
    ///   (`has_nonempty_beforeunload`), but Blink never sets it.
    /// - Chrome style, everything else: Chromium's own discard rules for the
    ///   tab, from `chrome://discards` (`GetTabDiscardsInfo`): audio,
    ///   picture in picture, devices, form input, exemptions.
    /// - In a `CefWebView` (Alloy style), ``CefBrowser/DiscardBlocker/playingAudio``
    ///   and ``CefBrowser/DiscardBlocker/formInteraction``: Chromium's
    ///   performance-manager graph, from the Graph view of
    ///   `chrome://discards` (`discards.mojom.GraphDump`), for the page
    ///   whose main frame is this browser's. Audio counts in any frame,
    ///   from media elements and Web Audio alike, and for a minute after
    ///   it stops; a muted element does not, a browser muted with
    ///   ``isAudioMuted`` still does, as in Chrome. Form input is any frame's
    ///   form interaction or user edit Blink reported. Picture in picture,
    ///   devices and exemptions are not reported for these browsers.
    ///
    /// Both `chrome://discards` interfaces are Chromium-private; when one
    /// changes, the check becomes ``CefBrowser/DiscardBlocker/unknown(_:)``
    /// rather than reporting a page safe to discard. A call takes a few
    /// milliseconds while the `chrome://discards` service host runs; the
    /// first starts it (0.2 to 1.5 s measured), and it closes again after
    /// 30 seconds without calls.
    public func discardBlockers() async -> Set<CefBrowser.DiscardBlocker> {
        guard !isDiscarded else { return [] }
        var blockers = stateBlockers()
        if discardPhase != .none { blockers.insert(.notLoaded) }
        guard blockers.isEmpty else { return blockers }
        // Chromium's rules for a tab; for an Alloy browser, its page's
        // audio and form state in the performance-manager graph.
        blockers.formUnion(isChromeStyle
            ? await CefRuntime.shared.tabDiscarder.blockers(for: self) : await CefPageGraph.blockers(for: self))
        // Only a browser nothing native keeps is asked of DevTools, which
        // attaches its session for good: a visible, audible or edited
        // page, polled by a memory policy, stays unattached.
        guard blockers.isEmpty else { return blockers }
        switch await hasBeforeUnloadHandler() {
        case true?: blockers.insert(.beforeUnloadHandler)
        case false?: break
        case nil: blockers.insert(.unknown("Could not read the page's beforeunload listeners."))
        }
        return blockers
    }

    /// The blockers CefKit knows without asking the page.
    private func stateBlockers() -> Set<CefBrowser.DiscardBlocker> {
        var blockers = Set<CefBrowser.DiscardBlocker>()
        guard state == .live, raw != nil, !isBootstrapping, !isLoading, let url, url.scheme != "devtools" else {
            blockers.insert(.notLoaded)
            return blockers
        }
        if isOnScreen { blockers.insert(.visible) }
        if isShowingDevTools { blockers.insert(.devToolsOpen) }
        if downloads.contains(where: { !$0.state.isFinished }) { blockers.insert(.downloading) }
        if isCapturingMedia { blockers.insert(.capturingMedia) }
        return blockers
    }

    /// Throws unless the browser is still on the document `checkpoint` saw
    /// and nothing CefKit knows of keeps it loaded.
    private func checkStillDiscardable(since checkpoint: DiscardCheckpoint) throws(CefBrowser.DiscardError) {
        guard !isDiscarded, state == .live else { throw .failed("The browser was discarded, restored or closed meanwhile.") }
        let blockers = stateBlockers()
        guard blockers.isEmpty else { throw .blocked(blockers) }
        guard checkpoint == DiscardCheckpoint(self) else {
            throw .failed("The page navigated while the browser was being discarded.")
        }
    }

    // MARK: Chrome style

    /// Has Chromium discard the tab in place: the WebContents, and with it
    /// this browser, its back/forward list and its DevTools session, stay.
    ///
    /// Chromium's list of tabs carries no identifier CefKit can map to a
    /// browser, only each tab's address and title, so the discard goes ahead
    /// only when exactly one tab matches (``CefTabDiscarder``).
    private func discardInChromium() async throws(CefBrowser.DiscardError) {
        // CEF stops counting a tab's frames when Chromium discards it. A
        // browser of CefKit's that lost its frames although it was not the
        // one asked for was discarded in its place.
        let others = CefRuntime.shared.browsers.filter {
            $0 !== self && $0.isChromeStyle && !$0.isDiscarded && $0.frameCount > 0
        }
        let hadFrames = frameCount > 0
        try await CefRuntime.shared.tabDiscarder.discard(self)
        let wrong = others.filter { $0.frameCount == 0 }
        if !wrong.isEmpty, !hadFrames || frameCount > 0 {
            for other in wrong { other.raw.map { $0.pointer.pointee.reload($0.pointer) } }
            throw .failed("Chromium discarded another tab than this browser's; it is loading again.")
        }
        discardPhase = .discarded
        isDiscarded = true
        isLoading = false
    }

    /// CEF's identifier of the main frame, `"<render process id in hexadecimal>-<frame token>"`.
    var mainFrameIdentifier: String? {
        var identifier: String?
        withMainFrame { identifier = CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
        return identifier
    }

    /// The frames CEF knows of in the browser.
    private var frameCount: Int {
        raw.map { Int($0.pointer.pointee.get_frame_count($0.pointer)) } ?? 0
    }

    // MARK: Alloy style

    /// Closes the Chromium browser and keeps this one, to be created again
    /// in the same view.
    private func discardByClosing() async throws(CefBrowser.DiscardError) {
        discardPhase = .closing
        let closing: Void? = withHost { $0.pointee.close_browser($0, 1) }
        guard closing != nil else {
            discardPhase = .none
            throw .failed("The browser has no Chromium browser to close.")
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while discardPhase == .closing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard discardPhase == .closed else {
            throw .failed("Chromium did not close the browser.")
        }
    }

    /// `on_before_close` for a browser being discarded by closing it.
    func browserDidCloseForDiscard() {
        initialURL = url
        accessibilityDidCloseForDiscard()
        raw = nil
        client = nil
        isLoading = false
        canGoBack = false
        canGoForward = false
        isFullscreen = false
        statusText = ""
        findResult = nil
        isCapturingMedia = false
        for download in downloads { download.control = nil }
        cancelDecisions { _ in true }
        devTools.prepareForNewSession()
        pageScripting.failPendingEvaluations()
        CefRuntime.shared.forgetIdentifier(of: self)
        identifier = -1
        isDiscarded = true
        discardPhase = .closed
    }

    // MARK: Restoring

    /// Runs `command` once the browser has loaded its page again,
    /// restoring it now.
    func whenRestored(_ command: @escaping @MainActor () -> Void) {
        commandsAfterRestore.append(command)
        restore()
    }

    /// The main frame started loading a document.
    func pageDidStartLoading() {
        navigationGeneration &+= 1
        guard isDiscarded, discardPhase == .discarded || discardPhase == .restoring else { return }
        isDiscarded = false
        discardPhase = .restoring
        restoreWaiters.completeAll(.success(()))
        reassertAccessibilityState()
        delegate?.browserDidRestore(self)
    }

    /// The main frame stopped loading.
    func pageDidFinishLoading() {
        guard discardPhase == .restoring, !isDiscarded else { return }
        discardPhase = .none
        discardSnapshot = nil
        let commands = commandsAfterRestore
        commandsAfterRestore = []
        commands.forEach { $0() }
    }

    // MARK: Visibility

    /// Whether the browser is on screen: the selected tab of a visible,
    /// unminimized window, or a view in one.
    var isOnScreen: Bool {
        let window: NSWindow?
        if let view = hostView {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if !isDiscarded, isEmbeddedView, let native = nativeView, native.superview !== view { return false }
            window = view.window
        } else {
            window = CefWindow.hosting(self)?.window ?? nativeView?.window
        }
        guard let window, !window.isMiniaturized else { return false }
        if window.isVisible { return true }
        // A hidden app's windows report themselves invisible; count the
        // selected tab of each as on screen.
        return NSApp.isHidden && (window.tabGroup?.selectedWindow ?? window) === window
    }

    // MARK: Page checks

    /// Whether a frame of the page has a `beforeunload` listener, read with
    /// the DevTools Protocol (``CefBeforeUnloadListeners``); `nil` if it
    /// could not be read.
    private func hasBeforeUnloadHandler() async -> Bool? {
        await withTimeout(.seconds(3)) { try await CefBeforeUnloadListeners.present(in: self) }
    }
}

/// Runs `body`, giving up after `timeout`: `nil` when it throws or takes
/// longer, in which case it is cancelled. Returns once `body` has ended,
/// which CefKit's own suspensions (``CefBrowser/ready()``, scripts,
/// DevTools calls) do as soon as they are cancelled.
@MainActor
func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @MainActor () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await body() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}
