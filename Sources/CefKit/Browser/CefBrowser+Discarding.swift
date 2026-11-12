import AppKit
import CCef
import Foundation

/// A reason a browser cannot be discarded right now.
public enum CefDiscardBlocker: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
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

    public var description: String { rawValue }
}

/// Why ``CefBrowser/discard()`` did not discard a browser.
public enum CefDiscardError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Something on the page, or the browser's situation, keeps it loaded.
    case blocked(Set<CefDiscardBlocker>)
    /// Chromium did not discard the page.
    case failed(String)

    public var description: String {
        switch self {
        case .blocked(let blockers): "not discardable: " + blockers.map(\.rawValue).sorted().joined(separator: ", ")
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
        let blockers = await discardBlockers()
        guard blockers.isEmpty else { throw .blocked(blockers) }
        // The page may have changed while the checks ran.
        guard !isDiscarded, discardPhase == .none, state == .live, raw != nil else { return }

        discardPhase = .discarding
        delegate?.browserWillDiscard(self)
        let snapshot = await withTimeout(.seconds(2)) { try await self.snapshot() }.flatMap(NSImage.init(data:))
        do {
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
    /// elements of the main frame.
    public func discardBlockers() async -> Set<CefDiscardBlocker> {
        guard !isDiscarded else { return [] }
        var blockers = Set<CefDiscardBlocker>()
        if !allowsDiscarding { blockers.insert(.exempt) }
        guard state == .live, raw != nil, !isBootstrapping, !isLoading, discardPhase == .none,
              let url, url.scheme != "devtools"
        else {
            blockers.insert(.notLoaded)
            return blockers
        }
        if isOnScreen { blockers.insert(.visible) }
        if isShowingDevTools { blockers.insert(.devToolsOpen) }
        if downloads.contains(where: { !$0.isComplete && !$0.isCancelled }) { blockers.insert(.downloading) }
        if isCapturingMedia { blockers.insert(.capturingMedia) }
        if await hasBeforeUnloadHandler() { blockers.insert(.beforeUnloadHandler) }
        if isChromeStyle {
            blockers.formUnion(await CefRuntime.shared.tabDiscarder.blockers(for: self))
        } else {
            blockers.formUnion(await pageContentBlockers())
        }
        return blockers
    }

    // MARK: Chrome style

    /// Has Chromium discard the tab in place: the WebContents, and with it
    /// this browser, its back/forward list and its DevTools session, stay.
    private func discardInChromium() async throws(CefDiscardError) {
        let discarder = CefRuntime.shared.tabDiscarder
        var attempt = 0
        while true {
            // CEF stops counting a tab's frames when Chromium discards it,
            // which tells which tab went. The count stays at zero after the
            // tab loads again, so it says nothing about a tab discarded before.
            let twins = CefRuntime.shared.browsers.filter {
                $0 !== self && $0.isChromeStyle && !$0.isDiscarded && $0.url == url && $0.frameCount > 0
            }
            let hadFrames = frameCount > 0
            let candidates = try await discarder.discard(self, candidate: attempt)
            let discardedTwins = twins.filter { $0.frameCount == 0 }
            if candidates == 1 || frameCount == 0 || (!hadFrames && discardedTwins.isEmpty) {
                discardPhase = .discarded
                isDiscarded = true
                isLoading = false
                return
            }
            // Chromium tells tabs apart only by address and title, and
            // discarded another hidden tab that shares both: bring that one
            // back and try the next.
            for twin in discardedTwins {
                twin.raw.map { $0.pointer.pointee.reload($0.pointer) }
            }
            attempt += 1
            guard attempt < candidates else {
                throw .failed("Chromium could not tell this browser's tab apart from another with the same address and title.")
            }
        }
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
        devTools.prepareForNewSession()
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
        guard isDiscarded, discardPhase == .discarded || discardPhase == .restoring else { return }
        isDiscarded = false
        discardPhase = .restoring
        let waiters = restoreWaiters
        restoreWaiters = []
        waiters.forEach { $0.resume() }
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
    /// the DevTools Protocol.
    private func hasBeforeUnloadHandler() async -> Bool {
        let group: CefJSON = "cefswift-discard"
        defer { Task { _ = try? await devTools.send("Runtime.releaseObjectGroup", ["objectGroup": group]) } }
        let listeners = await withTimeout(.seconds(3)) { () async throws -> [String] in
            let window = try await self.devTools.send(
                "Runtime.evaluate", ["expression": "window", "silent": true, "objectGroup": group])
            let reply = try await self.devTools.send(
                "DOMDebugger.getEventListeners", ["objectId": window["result"]["objectId"]])
            return reply["listeners"].arrayValue?.compactMap { $0["type"].stringValue } ?? []
        }
        return listeners?.contains("beforeunload") ?? false
    }

    /// For browsers Chromium's discard rules do not cover: playing media
    /// and edited form fields in the main frame.
    private func pageContentBlockers() async -> Set<CefDiscardBlocker> {
        let state = await withTimeout(.seconds(3)) {
            try await self.devTools.send("Runtime.evaluate", [
                "expression": """
                    ({
                      audio: [...document.querySelectorAll('audio, video')]
                        .some(m => !m.paused && !m.ended && !m.muted && m.volume > 0),
                      edited: [...document.querySelectorAll('input, textarea')].some(e =>
                        e.type === 'checkbox' || e.type === 'radio' ? e.checked !== e.defaultChecked
                          : e.type !== 'hidden' && e.type !== 'file' && e.value !== e.defaultValue),
                    })
                    """,
                "returnByValue": true, "silent": true,
            ])["result"]["value"]
        }
        var blockers = Set<CefDiscardBlocker>()
        if state?["audio"].boolValue == true { blockers.insert(.playingAudio) }
        if state?["edited"].boolValue == true { blockers.insert(.formInteraction) }
        return blockers
    }
}

/// Runs `body`, giving up after `timeout`.
@MainActor
func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @MainActor () async throws -> T) async -> T? {
    let once = Once<T?>()
    return await withCheckedContinuation { continuation in
        once.continuation = continuation
        Task { once.resume(try? await body()) }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(nil)
        }
    }
}

@MainActor
private final class Once<T: Sendable> {
    var continuation: CheckedContinuation<T, Never>?

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
