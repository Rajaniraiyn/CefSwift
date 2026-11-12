import AppKit
import CCef
import Foundation

/// A reason a browser cannot be discarded right now.
public enum CefDiscardBlocker: Sendable, Hashable, CustomStringConvertible {
    /// The browser is on screen: the selected tab of a visible window, or
    /// a view in one.
    case visible
    /// ``CefBrowser/allowsDiscarding`` is off, or an extension protects the
    /// tab.
    case exempt
    /// The browser is not open, is still loading, or shows DevTools.
    case notLoaded
    /// The page is playing sound, or did so in the last minute.
    case playingAudio
    /// The page uses the camera, microphone or screen capture, or is being
    /// cast.
    case capturingMedia
    /// The page shows picture in picture.
    case pictureInPicture
    /// The page is connected to a Bluetooth or USB device.
    case connectedToDevice
    /// The user has typed into the page or changed its form fields.
    case formInteraction
    /// The page has a `beforeunload` handler: it may ask before it is left.
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

/// Why ``CefBrowser/discard()`` did not discard a browser.
public enum CefDiscardError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Something on the page, or the browser's situation, keeps it loaded.
    case blocked(Set<CefDiscardBlocker>)
    /// Chromium did not discard the page.
    case failed(String)

    public var description: String {
        switch self {
        case .blocked(let blockers): "not discardable: " + blockers.map(\.description).sorted().joined(separator: ", ")
        case .failed(let message): message
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
struct DiscardCheckpoint: Equatable {
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
    /// does. Discarding a discarded browser does nothing.
    ///
    /// A browser in a ``CefBrowserWindow`` or a Chrome UI window is
    /// discarded by Chromium itself and keeps its back/forward list and
    /// scroll position. A browser in a `CefWebView` is discarded by closing
    /// its Chromium browser and creating a new one in the same view when it
    /// comes back: it keeps its address, title, icon and zoom, but its
    /// back/forward list starts again from the current page. In both cases
    /// bridges and user scripts work as before, DevTools event streams keep
    /// delivering, and form input that was not submitted is lost.
    public func discard() async throws(CefDiscardError) {
        guard !isDiscarded else { return }
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
        CefRuntime.shared.memorySaverMonitor.browserDidDiscard(self)
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
            if case .offscreen = options.rendering, let offscreenHost = restoringOffscreenHost {
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
    /// Besides the browser's own state, this asks the page: Chromium's
    /// discard rules for Chrome-style browsers (audio, media capture, form
    /// input and the rest), and for every browser whether the page has a
    /// `beforeunload` handler. Browsers in a `CefWebView` report audio and
    /// form input only for `<audio>`, `<video>`, `<input>` and `<textarea>`
    /// elements of the main frame. A check that cannot be made counts as a
    /// blocker, ``CefDiscardBlocker/unknown(_:)``.
    public func discardBlockers() async -> Set<CefDiscardBlocker> {
        guard !isDiscarded else { return [] }
        var blockers = stateBlockers()
        if discardPhase != .none { blockers.insert(.notLoaded) }
        guard !blockers.contains(.notLoaded) else { return blockers }
        switch await hasBeforeUnloadHandler() {
        case true?: blockers.insert(.beforeUnloadHandler)
        case false?: break
        case nil: blockers.insert(.unknown("Could not read the page's beforeunload listeners."))
        }
        if isChromeStyle {
            blockers.formUnion(await CefRuntime.shared.tabDiscarder.blockers(for: self))
        } else {
            blockers.formUnion(await pageContentBlockers())
        }
        return blockers
    }

    /// The blockers CefKit knows without asking the page.
    private func stateBlockers() -> Set<CefDiscardBlocker> {
        var blockers = Set<CefDiscardBlocker>()
        if !allowsDiscarding { blockers.insert(.exempt) }
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
    private func checkStillDiscardable(since checkpoint: DiscardCheckpoint) throws(CefDiscardError) {
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
    private func discardInChromium() async throws(CefDiscardError) {
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

    /// The frames CEF knows of in the browser.
    private var frameCount: Int {
        raw.map { Int($0.pointer.pointee.get_frame_count($0.pointer)) } ?? 0
    }

    // MARK: Alloy style

    /// Closes the Chromium browser and keeps this one, to be created again
    /// in the same view.
    private func discardByClosing() async throws(CefDiscardError) {
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
        downloadControls = [:]
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
            window = CefBrowserWindow.all.first { $0.browser === self }?.window ?? nativeView?.window
        }
        guard let window, !window.isMiniaturized else { return false }
        if window.isVisible { return true }
        // A hidden app's windows report themselves invisible; count the
        // selected tab of each as on screen.
        return NSApp.isHidden && (window.tabGroup?.selectedWindow ?? window) === window
    }

    // MARK: Page checks

    /// Whether the page's window has a `beforeunload` listener, read with
    /// the DevTools Protocol; `nil` if it could not be read.
    private func hasBeforeUnloadHandler() async -> Bool? {
        let group: CefJSON = "cefswift-discard"
        defer { Task { _ = try? await devTools.send("Runtime.releaseObjectGroup", ["objectGroup": group]) } }
        let listeners = await withTimeout(.seconds(3)) { () async throws -> [String] in
            let window = try await self.devTools.send(
                "Runtime.evaluate", ["expression": "window", "silent": true, "objectGroup": group])
            let reply = try await self.devTools.send(
                "DOMDebugger.getEventListeners", ["objectId": window["result"]["objectId"]])
            guard let listeners = reply["listeners"].arrayValue else {
                throw CefError.operationFailed("DOMDebugger.getEventListeners returned no listeners")
            }
            return listeners.compactMap { $0["type"].stringValue }
        }
        return listeners?.contains("beforeunload")
    }

    /// For browsers Chromium's discard rules do not cover: playing media
    /// and edited form fields in the main frame.
    private func pageContentBlockers() async -> Set<CefDiscardBlocker> {
        let state = await withTimeout(.seconds(3)) {
            try await self.pageScripting.evaluate("""
                ({
                  audio: [...document.querySelectorAll('audio, video')]
                    .some(m => !m.paused && !m.ended && !m.muted && m.volume > 0),
                  edited: [...document.querySelectorAll('input, textarea')].some(e =>
                    e.type === 'checkbox' || e.type === 'radio' ? e.checked !== e.defaultChecked
                      : e.type !== 'hidden' && e.type !== 'file' && e.value !== e.defaultValue),
                })
                """)
        }
        guard let audio = state?["audio"].boolValue, let edited = state?["edited"].boolValue else {
            return [.unknown("Could not read the page's media and form fields.")]
        }
        var blockers = Set<CefDiscardBlocker>()
        if audio { blockers.insert(.playingAudio) }
        if edited { blockers.insert(.formInteraction) }
        return blockers
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
