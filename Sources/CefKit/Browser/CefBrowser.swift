import AppKit
import CCef
import Foundation
import Observation
import CefBase

extension CefBrowser {
    /// Progress of a find-in-page session.
    public struct FindResult: Sendable, Equatable {
        public var matchCount: Int
        /// 1-based index of the highlighted match; 0 when there is none.
        public var activeMatchIndex: Int
        /// Whether the search has finished counting.
        public var isFinal: Bool
    }
}

// MARK: - CefBrowser

/// One Chromium browser: a page, its navigation state, and every command you
/// can send it.
///
/// A `CefBrowser` is an observable model object. Create it up front, bind UI
/// to its state, and hand it to a `CefWebView` or ``CefBrowserWindow`` — the
/// underlying Chromium browser is created when it is first shown.
///
/// ```swift
/// @State private var browser = CefBrowser(url: URL(string: "https://example.com")!)
///
/// var body: some View {
///     VStack {
///         Text(browser.title)
///         CefWebView(browser)
///     }
/// }
/// ```
@MainActor
@Observable
public final class CefBrowser: Identifiable {

    /// Where the browser is in its lifetime.
    public enum State: Sendable, Equatable {
        /// Not yet created in Chromium. Navigation is remembered and applied
        /// at creation.
        case pending
        /// Created and usable.
        case live
        /// Closed. Create a new `CefBrowser` to browse again.
        case closed
    }

    // MARK: Observable state

    public internal(set) var state: State = .pending
    /// The main frame's URL.
    public internal(set) var url: URL?
    public internal(set) var title = ""
    public internal(set) var isLoading = false
    public internal(set) var canGoBack = false
    public internal(set) var canGoForward = false
    /// Load progress of the current navigation, 0…1.
    public internal(set) var estimatedProgress = 0.0
    /// The address of the page's icon, as the page declares it. `nil` until
    /// the page reports one, and again when a new page starts loading.
    public internal(set) var faviconURL: URL?
    /// The page's icon, downloaded from ``faviconURL`` at up to 32 points
    /// (with Retina representations when the site offers them). `nil` until
    /// it arrives, for pages without an icon, and again when a new page
    /// starts loading.
    ///
    /// ```swift
    /// Image(nsImage: browser.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
    /// ```
    public internal(set) var favicon: NSImage?
    /// Whether the page is in HTML fullscreen.
    public internal(set) var isFullscreen = false
    /// Status text, such as the URL of the link under the pointer.
    public internal(set) var statusText = ""
    /// Downloads started by this browser, oldest first.
    public internal(set) var downloads: [CefDownload] = []
    /// Progress of a back or forward swipe
    /// (``CefBrowser/Configuration/allowsBackForwardNavigationGestures``): 0 at
    /// rest, moving toward -1 while swiping back and toward 1 while swiping
    /// forward. At -1 or 1 and beyond, releasing navigates. Use it to draw
    /// your own indicator with
    /// ``CefBrowser/Configuration/navigationGestureIndicator`` set to `.hidden`.
    public package(set) var navigationGestureProgress = 0.0
    /// The latest result of ``find(_:backwards:caseSensitive:)``.
    public internal(set) var findResult: CefBrowser.FindResult?
    /// Whether the page responds to input. Chromium reports a page whose
    /// renderer has not handled input for 15 seconds as unresponsive; see
    /// ``CefBrowserDelegate/browserPageIsUnresponsive(_:)``.
    public internal(set) var isResponsive = true
    /// How the page shown was loaded: TLS, its certificate, insecure
    /// content. `nil` before the first page commits.
    public internal(set) var connectionSecurity: CefConnectionSecurity?
    /// The page's frames connected to a renderer, the main frame first and
    /// the others in the order they attached. Empty before the browser is
    /// created, while it is discarded and after it closes.
    ///
    /// ```swift
    /// let embeds = browser.frames.filter { !$0.isMain }.compactMap(\.url)
    /// ```
    public internal(set) var frames: [CefFrame] = []
    /// The page's top-level frame; `nil` when ``frames`` is empty.
    public var mainFrame: CefFrame? { frames.first(where: \.isMain) }

    /// Whether the page has been unloaded to free its memory, by
    /// ``discard()`` or ``CefRuntime/discardPolicy``.
    ///
    /// A discarded browser keeps its ``url``, ``title`` and ``favicon`` and
    /// stays in your UI; dim its tab, for instance. It loads its page again
    /// when it is shown, navigated or used, and this turns `false` as that
    /// load starts.
    public internal(set) var isDiscarded = false {
        didSet { if isDiscarded != oldValue { CefRuntime.shared.lifecycleCoordinator.setNeedsUpdate() } }
    }
    /// The page as it looked just before it was discarded, to show in its
    /// place while it loads again. `nil` when the browser is not discarded
    /// or the capture failed; released once the page has loaded again.
    public internal(set) var discardSnapshot: NSImage?
    /// Whether ``CefRuntime/discardPolicy`` and ``discard()`` may discard this
    /// browser. Turn it off for tabs the user pinned, or pages that must
    /// keep running.
    public var allowsDiscarding = true
    /// Where the page is in its lifecycle: whether the user can see it,
    /// whether it has their input, or whether it is discarded. The page's
    /// `document.visibilityState` agrees with it. See ``Lifecycle``.
    public internal(set) var lifecycle = Lifecycle.hidden

    // MARK: Configuration

    /// The object that makes policy decisions and receives one-shot events
    /// for this browser.
    ///
    /// The browser holds its delegate weakly, as `WKWebView` does: keep a
    /// strong reference to it elsewhere — in your view model, window
    /// controller or app delegate — for as long as the browser lives. A
    /// popup inherits its opener's delegate. Without a delegate, each
    /// decision gets the default implementation from
    /// ``CefBrowserDelegate``.
    @ObservationIgnored public weak var delegate: CefBrowserDelegate?
    /// The creation-time settings the browser was made with.
    @ObservationIgnored public let configuration: Configuration
    /// Chromium's identifier for this browser; `-1` until created.
    @ObservationIgnored public internal(set) var identifier: Int32 = -1
    /// The browser that opened this one, for popups.
    @ObservationIgnored public internal(set) weak var opener: CefBrowser?
    /// For a popup, the window features its page asked for — the size to
    /// give the popup's window, for instance.
    @ObservationIgnored public internal(set) var popupFeatures: CefPopupFeatures?

    /// Find in page as an observable model, for a find bar of your own.
    @ObservationIgnored public private(set) lazy var findSession = CefFindSession(browser: self)

    /// Chrome DevTools Protocol access to this browser.
    ///
    /// The protocol attaches to the browser the first time anything uses
    /// it, and stays attached until the browser closes; pages can observe
    /// some of what it does. CefKit uses it only for the features the
    /// guide's "Compatibility with bot protection" lists.
    @ObservationIgnored public private(set) lazy var devTools = CefDevTools(browser: self)

    /// Bridges, user scripts and evaluation through the helper's renderer.
    @ObservationIgnored private(set) lazy var pageScripting = CefPageScripting(browser: self)

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    // MARK: Internals

    @ObservationIgnored var raw: CefRef<cef_browser_t>?
    @ObservationIgnored var client: CefBrowserClient?
    /// The offscreen host a browser discarded by closing it is created
    /// again in.
    @ObservationIgnored weak var restoringOffscreenHost: CefOffscreenHost?
    @ObservationIgnored var initialURL: URL?
    @ObservationIgnored var isBootstrapping = false
    @ObservationIgnored var passkeyAuthenticator: CefPasskeyAuthenticator?
    /// Calls waiting for ``ready()``.
    @ObservationIgnored let readyWaiters = CefPendingOperations<Void>()
    /// Delegate decisions waiting for an answer; see ``decide(_:_:then:)``.
    @ObservationIgnored var pendingDecisions: [Int: PendingDecision] = [:]
    @ObservationIgnored var nextDecisionID = 0
    /// Counts unresponsive-page questions; an answer applies only while
    /// its question is the current one. See `CefUnresponsivePage.swift`.
    @ObservationIgnored var unresponsiveEpisode = 0
    /// Whether the current renderer's ending reloads the page: the answer
    /// to its unresponsive question was ``CefUnresponsivePageDecision/reload``.
    @ObservationIgnored var reloadsWhenRendererEnds = false
    @ObservationIgnored var downloadControls: [UInt32: CefRef<cef_download_item_callback_t>] = [:]
    @ObservationIgnored var isChromeStyle = false
    @ObservationIgnored var isEmbeddedView = false
    /// How far discarding has got; see `CefBrowser+Discarding.swift`.
    @ObservationIgnored var discardPhase = DiscardPhase.none
    /// Counts the main frame's document loads; a discard checks it has not
    /// moved on since its checks ran.
    @ObservationIgnored var navigationGeneration = 0
    /// Calls waiting for a discarded browser to load its page again.
    @ObservationIgnored let restoreWaiters = CefPendingOperations<Void>()
    /// Commands that arrived while the browser was discarded, run once its
    /// page has loaded again.
    @ObservationIgnored var commandsAfterRestore: [@MainActor () -> Void] = []
    /// Scripts added with ``addUserScript(_:)``, installed again when a
    /// browser discarded by closing it is created anew.
    @ObservationIgnored private var addedUserScripts: [CefUserScript] = []
    /// Whether the page uses the camera, microphone or screen capture.
    @ObservationIgnored var isCapturingMedia = false
    /// The view hosting this browser: the parent of a windowed browser's
    /// native view, or the offscreen host.
    @ObservationIgnored public internal(set) weak var hostView: NSView?
    /// Whether the offscreen host last reported that it cannot be seen
    /// (``hostViewDidHide()``).
    @ObservationIgnored var isHostViewHidden = false
    /// Whether the lifecycle coordinator hid a windowed browser's native
    /// view, and the responder to give focus back to when it shows it.
    @ObservationIgnored var lifecycleHidNativeView = false
    @ObservationIgnored weak var responderBeforeLifecycleHide: NSResponder?
    /// The offscreen frame rate the lifecycle coordinator last set; `nil`
    /// for the rate the browser was created with.
    @ObservationIgnored var appliedOffscreenFrameRate: Int?

    /// Whether Chromium is building the page's accessibility tree for an
    /// offscreen browser. See ``CefBrowser/Configuration/offscreenAccessibility``.
    public internal(set) var isAccessibilityEnabled = false
    /// The page's accessibility tree, for offscreen browsers while
    /// ``isAccessibilityEnabled`` is on; empty otherwise.
    @ObservationIgnored public private(set) lazy var accessibilityTree = CefAccessibilityTree()
    /// Whether the tree was asked for before the browser was created.
    @ObservationIgnored var wantsAccessibility = false

    /// Creates a browser model. Nothing is created in Chromium until the
    /// browser is hosted.
    ///
    /// - Parameters:
    ///   - url: The page the browser opens with.
    ///   - configuration: Creation-time settings.
    ///   - delegate: The browser's ``delegate``, held weakly. Keep your own
    ///     strong reference to it; a delegate created inline, such as
    ///     `CefBrowser(url: url, delegate: Policy())`, is released at once.
    public init(url: URL? = nil, configuration: Configuration = .init(), delegate: CefBrowserDelegate? = nil) {
        self.url = url
        self.initialURL = url
        self.configuration = configuration
        self.delegate = delegate
    }

    /// Wraps a browser Chromium created on its own (popup, Chrome UI tab).
    init(adopting raw: CefRef<cef_browser_t>, client: CefBrowserClient, opener: CefBrowser?, profile: CefProfile?) {
        var configuration = opener?.configuration ?? CefBrowser.Configuration()
        configuration.profile = profile
        self.configuration = configuration
        self.client = client
        self.opener = opener
        self.isChromeStyle = opener?.isChromeStyle ?? true
        configuration.bridges.forEach { $0.attach(to: self) }
        adopt(raw)
    }

    // MARK: Page state

    var observedZoomLevel = 0.0

    var observedAudioMuted = false

    @ObservationIgnored var lastFindText: String?

    /// Whether this browser's DevTools window is open.
    ///
    /// The value is observable. CEF reports no change, so CefKit reads the
    /// state back after ``showDevTools(inspecting:)`` and
    /// ``closeDevTools()``, and whenever any browser, a DevTools window's
    /// included, is created or closes.
    public internal(set) var isShowingDevTools = false

    // MARK: Navigation

    /// Navigates the main frame. Before creation, sets the page the browser
    /// opens with.
    public func load(_ url: URL) {
        guard state != .closed else { return }
        guard raw != nil, !isBootstrapping else {
            initialURL = url
            self.url = url
            if isDiscarded { restore() }
            return
        }
        withMainFrame { frame in
            CefStringUtil.withCefString(url.absoluteString) { frame.pointee.load_url(frame, $0) }
        }
    }

    public func goBack() { raw.map { $0.pointer.pointee.go_back($0.pointer) } }
    public func goForward() { raw.map { $0.pointer.pointee.go_forward($0.pointer) } }
    public func stopLoading() { raw.map { $0.pointer.pointee.stop_load($0.pointer) } }

    public func reload(ignoringCache: Bool = false) {
        guard let raw = raw?.pointer else {
            if isDiscarded { restore() }
            return
        }
        if ignoringCache {
            raw.pointee.reload_ignore_cache(raw)
        } else {
            raw.pointee.reload(raw)
        }
    }

    // MARK: JavaScript

    /// Runs JavaScript in the main frame without waiting for a result.
    public func executeJavaScript(_ script: String) {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.executeJavaScript(script) }
            return
        }
        withMainFrame { frame in
            CefStringUtil.withCefString(script) { code in
                frame.pointee.execute_java_script(frame, code, nil, 0)
            }
        }
    }

    /// Evaluates JavaScript in the main frame and returns its value.
    ///
    /// Promises are awaited. A thrown JavaScript exception surfaces as
    /// ``CefJavaScriptError``. The value comes back as JSON: objects with
    /// their own enumerable properties, `undefined` as `null`.
    ///
    /// ```swift
    /// let title = try await browser.evaluateJavaScript("document.title").stringValue
    /// ```
    ///
    /// The helper's renderer code runs the script in the page's main world
    /// with the V8 API, without the DevTools protocol, and the page sees
    /// only what the script does. A script that returns a promise is
    /// awaited through the promise's `then`.
    ///
    /// - Parameter userGesture: Runs the script as if the user had just
    ///   clicked, as some APIs require (opening popups, entering
    ///   fullscreen, `beforeunload` prompts). Only the DevTools protocol can
    ///   grant that, so the call attaches ``devTools`` to the browser,
    ///   which stays attached; see the guide's "Compatibility with bot
    ///   protection".
    @discardableResult
    public func evaluateJavaScript(_ script: String, userGesture: Bool = false) async throws -> CefJSON {
        guard userGesture else { return try await pageScripting.evaluate(script, as: CefJSON.self) }
        let reply = try await devTools.send(
            "Runtime.evaluate",
            ["expression": .string(script), "returnByValue": true, "awaitPromise": true, "userGesture": true])
        if let exception = reply["exceptionDetails"].objectValue {
            throw CefJavaScriptError(exceptionDetails: .object(exception))
        }
        return reply["result"]["value"]
    }

    /// Evaluates JavaScript and decodes its value as `T`.
    public func evaluateJavaScript<T: Decodable>(
        _ script: String, as type: T.Type = T.self, userGesture: Bool = false
    ) async throws -> T {
        // Without a gesture the value decodes straight from the renderer's
        // reply, with no JSON or `CefJSON` in between.
        guard userGesture else { return try await pageScripting.evaluate(script, as: T.self) }
        return try await evaluateJavaScript(script, userGesture: true).decode(T.self)
    }

    /// Injects `script` into every document loaded from now on, before the
    /// page's own scripts. For scripts known up front prefer
    /// ``CefBrowser/Configuration/userScripts``, which also cover the first page.
    ///
    /// The script reaches every renderer process that shows the browser's
    /// frames now. A renderer process that the browser moves to later (a
    /// navigation to another site) learns of it as that process's first
    /// document of the browser starts, and runs it from its next document.
    public func addUserScript(_ script: CefUserScript) {
        addedUserScripts.append(script)
        pageScripting.configurationDidChange()
    }

    /// The user scripts of the options and those added at runtime.
    var userScripts: [CefUserScript] { configuration.userScripts + addedUserScripts }

    // MARK: Lifetime

    /// Closes the browser. Unless `force` is set, a page's `beforeunload`
    /// handler may ask the user to stay.
    public func close(force: Bool = false) {
        guard raw != nil else {
            // Not created yet, or Chromium is still creating it: it closes
            // now, and a browser Chromium finishes creating after this
            // closes at once (`CefBrowserClient.wrapper(adopting:)`).
            if state == .pending { handleClosed() }
            // Discarded by closing its Chromium browser: nothing is left
            // to close.
            if state == .live, isDiscarded { handleClosed() }
            return
        }
        if let signInPromptURL, signInPromptURL == url {
            // With `CefRuntime.AuthenticationPromptPolicy.chromium`, Chromium's sign-in
            // window for an Alloy-style browser crashes the process when its
            // browser closes under it. A navigation dismisses the window, so
            // leave the page first and close once the window has gone.
            self.signInPromptURL = nil
            let browserWindows = Set(CefBrowserWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
            let chromiumWindows = NSApp.windows.filter {
                $0.isVisible && $0 !== hostWindow && !browserWindows.contains(ObjectIdentifier($0))
                    && NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow"
            }.map { WeakWindow(window: $0) }
            load(URL(string: "about:blank")!)
            Task {
                let deadline = ContinuousClock.now + .seconds(3)
                while chromiumWindows.contains(where: { $0.window?.isVisible == true }), state == .live,
                      ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                withHost { $0.pointee.close_browser($0, force ? 1 : 0) }
            }
            return
        }
        withHost { $0.pointee.close_browser($0, force ? 1 : 0) }
    }

    /// The address that last failed with `ERR_INVALID_AUTH_CREDENTIALS` in
    /// an Alloy-style browser. While the browser still shows it, Chromium
    /// may be showing its own sign-in window for it.
    @ObservationIgnored var signInPromptURL: URL?

    /// Suspends until the browser exists in Chromium and has set up what
    /// its page relies on (passkeys, and after a discard the DevTools
    /// domains enabled before), restoring it first if it is discarded.
    ///
    /// Throws ``CefError/browserClosed`` if the browser closes first, and
    /// `CancellationError` if the calling task is cancelled.
    public func ready() async throws {
        // The set-up itself runs while the browser is not ready yet, and
        // needs only the native browser.
        if Self.settingUp == id {
            guard state == .live, raw != nil else { throw CefError.browserClosed }
            return
        }
        if isDiscarded {
            restore()
            try await restoreWaiters.wait()
        }
        switch state {
        case .live where !isBootstrapping: return
        case .closed: throw CefError.browserClosed
        case .pending, .live:
            try await readyWaiters.wait()
        }
    }

    /// Whether the browser is setting itself up before its first page.
    @_spi(Testing) public var isSettingUp: Bool { isBootstrapping }

    /// The browser whose set-up (`bootstrap()`) the current task runs.
    @TaskLocal static var settingUp: ObjectIdentifier?

    /// The NSView Chromium created for a windowed browser.
    public var nativeView: NSView? {
        withHost { host -> NSView? in
            guard let handle = host.pointee.get_window_handle(host) else { return nil }
            return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
        } ?? nil
    }

    /// The window currently showing this browser, if any.
    public var hostWindow: NSWindow? {
        hostView?.window ?? nativeView?.window
    }

    /// Whether this browser renders offscreen.
    public var isOffscreen: Bool { client?.offscreenHost != nil }
}

// MARK: - Host / frame access

extension CefBrowser {
    /// Runs `body` with the browser host, or returns nil when not live.
    @discardableResult
    func withHost<R>(_ body: (UnsafeMutablePointer<cef_browser_host_t>) -> R) -> R? {
        guard let raw = raw?.pointer, let host = raw.pointee.get_host(raw) else { return nil }
        defer { cefRelease(host) }
        return body(host)
    }

    func withMainFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw = raw?.pointer, let frame = raw.pointee.get_main_frame(raw) else { return }
        defer { cefRelease(frame) }
        body(frame)
    }

    /// `try_close_browser`: lets `beforeunload` run, then reports whether the
    /// hosting window may close now.
    func tryClose() -> Bool {
        withHost { $0.pointee.try_close_browser($0) != 0 } ?? true
    }
}

// MARK: - Supporting types

/// A JavaScript exception thrown by code passed to
/// ``CefBrowser/evaluateJavaScript(_:)``.
public struct CefJavaScriptError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var column: Int

    package init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }

    init(exceptionDetails details: CefJSON) {
        message = details["exception"]["description"].stringValue
            ?? details["text"].stringValue ?? "JavaScript exception"
        line = details["lineNumber"].intValue ?? 0
        column = details["columnNumber"].intValue ?? 0
    }

    public var description: String { message }
}

private struct WeakWindow {
    weak var window: NSWindow?
}
