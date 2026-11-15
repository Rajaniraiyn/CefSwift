import AppKit
import CCef
import Foundation
import Observation
import CefBase

extension CefPage {
    /// Progress of a find-in-page session.
    public struct FindResult: Sendable, Equatable {
        public var matchCount: Int
        /// 1-based index of the highlighted match; 0 when there is none.
        public var activeMatchIndex: Int
        /// Whether the search has finished counting.
        public var isFinal: Bool
        /// Where the highlighted match is, in the page's view points
        /// (top-left origin); nil when Chromium did not say.
        public var selectionRect: CGRect?

        /// Creates a value of your own, for previews and tests.
        public init(matchCount: Int, activeMatchIndex: Int, isFinal: Bool = true, selectionRect: CGRect? = nil) {
            self.matchCount = matchCount
            self.activeMatchIndex = activeMatchIndex
            self.isFinal = isFinal
            self.selectionRect = selectionRect
        }
    }
}

// MARK: - CefPage

/// One Chromium page: its web content, its navigation state, and every
/// command you can send it.
///
/// `CefPage` wraps CEF's `cef_browser_t` (Chromium's WebContents).
///
/// A `CefPage` is an observable model object. Create it up front, bind UI
/// to its state, and hand it to a `CefWebView` or ``CefWindow`` — the
/// underlying Chromium page is created when it is first shown.
///
/// ```swift
/// @State private var page = CefPage(url: URL(string: "https://example.com")!)
///
/// var body: some View {
///     VStack {
///         Text(page.title)
///         CefWebView(page)
///     }
/// }
/// ```
@MainActor
@Observable
public final class CefPage: Identifiable {

    /// Where the page is in its lifetime.
    public enum State: Sendable, Equatable {
        /// Not yet created in Chromium. Navigation is remembered and applied
        /// at creation.
        case pending
        /// Created and usable.
        case live
        /// Closed. Create a new `CefPage` to browse again.
        case closed
    }

    // MARK: Observable state

    public internal(set) var state: State = .pending {
        didSet { if state == .closed, oldValue != .closed { loads.pageDidClose() } }
    }
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
    /// Image(nsImage: page.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
    /// ```
    public internal(set) var favicon: NSImage?
    /// Whether the page is in HTML fullscreen.
    public internal(set) var isFullscreen = false
    /// Status text, such as the URL of the link under the pointer.
    public internal(set) var statusText = ""
    /// Downloads started by this page, oldest first.
    /// ``CefProfile/downloads`` lists those of every page of its profile.
    public internal(set) var downloads: [CefDownload] = []
    /// Progress of a back or forward swipe
    /// (``CefPage/Configuration/allowsBackForwardNavigationGestures``): 0 at
    /// rest, moving toward -1 while swiping back and toward 1 while swiping
    /// forward. At -1 or 1 and beyond, releasing navigates. Use it to draw
    /// an indicator of your own over the page; in a ``CefWindow``, turn off
    /// ``CefPage/Configuration/showsChromiumNavigationGestureIndicator``
    /// and draw it in ``CefWindow/pageOverlay``.
    public internal(set) var navigationGestureProgress = 0.0
    /// The latest result of ``find(_:backwards:caseSensitive:)``.
    public internal(set) var findResult: CefPage.FindResult?
    /// Whether the page responds to input. Chromium reports a page whose
    /// renderer has not handled input for 15 seconds as unresponsive; see
    /// ``CefPageDelegate/pageIsUnresponsive(_:)``.
    public internal(set) var isResponsive = true
    /// How the page shown was loaded: TLS, its certificate, insecure
    /// content. `nil` before the first page commits.
    public internal(set) var connectionSecurity: CefConnectionSecurity?
    /// The page's frames connected to a renderer, the main frame first and
    /// the others in the order they attached. Empty before the page is
    /// created, while it is discarded and after it closes.
    ///
    /// ```swift
    /// let embeds = page.frames.filter { !$0.isMain }.compactMap(\.url)
    /// ```
    public internal(set) var frames: [CefFrame] = []
    /// The page's top-level frame; `nil` when ``frames`` is empty.
    public var mainFrame: CefFrame? { frames.first(where: \.isMain) }

    /// Whether the page has been unloaded to free its memory by
    /// ``discard()``.
    ///
    /// A discarded page keeps its ``url``, ``title`` and ``favicon`` and
    /// stays in your UI; dim its tab, for instance. It loads its page again
    /// when it is shown, navigated or used, and this turns `false` as that
    /// load starts.
    public internal(set) var isDiscarded = false {
        didSet { if isDiscarded != oldValue { CefRuntime.shared.lifecycleCoordinator.setNeedsUpdate() } }
    }
    /// The page as it looked just before it was discarded, to show in its
    /// place while it loads again. `nil` when the page is not discarded
    /// or the capture failed; released once the page has loaded again.
    public internal(set) var discardSnapshot: NSImage?
    /// Where the page is in its lifecycle: whether the user can see it,
    /// whether it has their input, or whether it is discarded. The page's
    /// `document.visibilityState` agrees with it. See ``Lifecycle``.
    public internal(set) var lifecycle = Lifecycle.hidden {
        didSet { if lifecycle != oldValue { lifecycleChangedAt = .now } }
    }
    /// When ``lifecycle`` last changed. While it is
    /// ``Lifecycle/hidden``, the page has been out of sight since then:
    ///
    /// ```swift
    /// let hiddenFor = page.lifecycle == .hidden ? .now - page.lifecycleChangedAt : .zero
    /// ```
    public internal(set) var lifecycleChangedAt = ContinuousClock.now

    // MARK: Configuration

    /// The object that makes policy decisions and receives one-shot events
    /// for this page.
    ///
    /// The page holds its delegate weakly, as `WKWebView` does: keep a
    /// strong reference to it elsewhere — in your view model, window
    /// controller or app delegate — for as long as the page lives. A
    /// popup inherits its opener's delegate. Without a delegate, each
    /// decision gets the default implementation from
    /// ``CefPageDelegate``.
    @ObservationIgnored public weak var delegate: CefPageDelegate?
    /// The creation-time settings the page was made with.
    @ObservationIgnored public let configuration: Configuration
    /// The profile the page browses with: its configuration's, or the
    /// default profile. The profile's request filter, scheme handlers,
    /// user scripts, bridges, attachments and delegate apply to the page
    /// unless its own configuration or delegate overrides them.
    public var profile: CefProfile { configuration.profile ?? .default }
    /// Chromium's identifier for this page; `-1` until created.
    @ObservationIgnored public internal(set) var identifier: Int32 = -1
    /// The page that opened this one, for popups.
    @ObservationIgnored public internal(set) weak var opener: CefPage?
    /// For a popup, the window features its page asked for — the size to
    /// give the popup's window, for instance.
    @ObservationIgnored public internal(set) var popupFeatures: CefPopupFeatures?

    /// Find in page as an observable model, for a find bar of your own.
    @ObservationIgnored public private(set) lazy var findSession = CefFindSession(page: self)

    /// Chrome DevTools Protocol access to this page.
    ///
    /// The protocol attaches to the page the first time anything uses
    /// it, and stays attached until the page closes; pages can observe
    /// some of what it does. CefKit uses it only for the features the
    /// guide's "Compatibility with bot protection" lists.
    @ObservationIgnored public private(set) lazy var devTools = CefDevTools(page: self)

    /// Bridges, user scripts and evaluation through the helper's renderer.
    @ObservationIgnored private(set) lazy var pageScripting = CefPageScripting(page: self)

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    // MARK: Internals

    @ObservationIgnored var raw: CefRef<cef_browser_t>?
    @ObservationIgnored var client: CefBrowserClient?
    /// The offscreen host a page discarded by closing it is created
    /// again in.
    @ObservationIgnored weak var restoringOffscreenHost: CefOffscreenHost?
    @ObservationIgnored var initialURL: URL?
    @ObservationIgnored var isBootstrapping = false
    /// The creation to run once the page's profile is loaded, and the
    /// host it creates the page in; see `profileAllowsCreation(for:_:)`.
    /// It is the token the profile's loading checks: a host that lets go of
    /// the page (``stopHosting(in:)``), a close or a quit clears it, and
    /// nothing is created then.
    @ObservationIgnored var creationAwaitingProfile: DeferredCreation?

    struct DeferredCreation {
        weak var host: AnyObject?
        var create: @MainActor (CefPage) -> Void
    }
    /// The main frame's navigations, for ``waitUntilLoaded(timeout:)``.
    @ObservationIgnored let loads = CefLoadTracker()
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
    @ObservationIgnored package internal(set) var isChromeStyle = false
    @ObservationIgnored var isEmbeddedView = false
    /// How far discarding has got; see `CefPage+Discarding.swift`.
    @ObservationIgnored var discardPhase = DiscardPhase.none
    /// Counts the main frame's document loads; a discard checks it has not
    /// moved on since its checks ran.
    @ObservationIgnored var navigationGeneration = 0
    /// Calls waiting for a discarded page to load its page again.
    @ObservationIgnored let restoreWaiters = CefPendingOperations<Void>()
    /// Commands that arrived while the page was discarded, run once its
    /// page has loaded again.
    @ObservationIgnored var commandsAfterRestore: [@MainActor () -> Void] = []
    /// The page's own user scripts: its configuration's, then those added
    /// with ``addUserScript(_:)``, less those removed. Installed again
    /// when a page discarded by closing it is created anew.
    @ObservationIgnored private lazy var ownUserScripts: [CefUserScript] = configuration.userScripts
    /// The attachments that set this page up: its profile's, then its
    /// configuration's, as they were when it was first created.
    @ObservationIgnored lazy var attachments: [any CefPageAttachment] =
        (usesProfileDefaults ? profile.attachments : []) + configuration.attachments
    /// What the page captures now: video (a camera, or the screen, a
    /// window or a tab) and audio (a microphone, or the sound the Mac
    /// plays), as Chromium reports it (`on_media_access_change`). Empty
    /// when it captures nothing. Observable; show a recording indicator
    /// from it, as Safari and Chrome do in the tab.
    ///
    /// ```swift
    /// if page.mediaCapture.contains(.video) { Image(systemName: "video.fill") }
    /// ```
    public internal(set) var mediaCapture: MediaCapture = []

    /// The parts of the page that move its window when dragged, as the page
    /// declares them with `-webkit-app-region: drag` and `no-drag`, for a
    /// title bar drawn in web content (a window with
    /// `.fullSizeContentView` and a transparent title bar). Empty for a
    /// page that declares none. Observable.
    ///
    /// ``CefWindowedPageView`` and ``CefOffscreenPageView`` move
    /// their window when a drag starts in a draggable region, and zoom it
    /// on a double click, as a title bar does; the page does not get those
    /// clicks. A host of your own asks ``isDraggable(at:)``.
    public internal(set) var draggableRegions: [DraggableRegion] = []

    /// Whether the page uses the camera, microphone or screen capture.
    var isCapturingMedia: Bool { !mediaCapture.isEmpty }
    /// The view hosting this page: the parent of a windowed page's
    /// native view, or the offscreen host.
    @ObservationIgnored public internal(set) weak var hostView: NSView?
    /// Whether the offscreen host last reported that it cannot be seen
    /// (``hostViewDidHide()``).
    @ObservationIgnored var isHostViewHidden = false
    /// A windowed page's native view while no host shows it. CEF closes
    /// a page whose view is deallocated (`CefPageHostView`'s
    /// `dealloc`), so a view withdrawn from its host, as SwiftUI does when
    /// a `CefWebView` leaves the hierarchy, is kept here until a host shows
    /// it again or the page closes.
    @ObservationIgnored var parkedNativeView: NSView?
    /// Whether the Chromium page is closing: its view must then go, for
    /// the close to finish, and is not kept.
    @ObservationIgnored var isChromiumBrowserClosing = false
    /// How many times the host told Chromium its size changed
    /// (``hostViewDidResize()``), for SelfTest's animation measurements.
    @ObservationIgnored @_spi(Testing) public internal(set) var resizeNotificationCount = 0
    /// Whether the lifecycle coordinator hid a windowed page's native
    /// view, and the responder to give focus back to when it shows it.
    @ObservationIgnored var lifecycleHidNativeView = false
    @ObservationIgnored weak var responderBeforeLifecycleHide: NSResponder?
    /// The offscreen frame rate the lifecycle coordinator last set; `nil`
    /// for the rate the page was created with.
    @ObservationIgnored var appliedOffscreenFrameRate: Int?
    /// The rate set through ``offscreenFrameRate``; `nil` for the
    /// configuration's.
    @ObservationIgnored var preferredOffscreenFrameRate: Int?

    /// Whether Chromium is building the page's accessibility tree for an
    /// offscreen page. See ``CefPage/Configuration/offscreenAccessibility``.
    public internal(set) var isAccessibilityEnabled = false
    /// The page's accessibility tree, for offscreen pages while
    /// ``isAccessibilityEnabled`` is on; empty otherwise.
    @ObservationIgnored public private(set) lazy var accessibilityTree = CefAccessibilityTree()
    /// Whether the tree was asked for before the page was created.
    @ObservationIgnored var wantsAccessibility = false

    /// Creates a page model. Nothing is created in Chromium until the
    /// page is hosted.
    ///
    /// - Parameters:
    ///   - url: The page the page opens with.
    ///   - configuration: Creation-time settings.
    ///   - delegate: The page's ``delegate``, held weakly. Keep your own
    ///     strong reference to it; a delegate created inline, such as
    ///     `CefPage(url: url, delegate: Policy())`, is released at once.
    public init(url: URL? = nil, configuration: Configuration = .init(), delegate: CefPageDelegate? = nil) {
        self.url = url
        self.initialURL = url
        self.configuration = configuration
        self.delegate = delegate
    }

    /// Wraps a page Chromium created on its own (popup, Chrome UI tab).
    /// It takes the configuration of `origin`: the opener of a popup, or
    /// the first page of the window a tab opened in, whose client and
    /// `extra_info` Chromium gives it.
    init(
        adopting raw: CefRef<cef_browser_t>, client: CefBrowserClient, opener: CefPage?,
        configurationOf origin: CefPage?, profile: CefProfile?
    ) {
        var configuration = origin?.configuration ?? CefPage.Configuration()
        configuration.profile = profile
        self.configuration = configuration
        self.client = client
        self.opener = opener
        self.isChromeStyle = opener?.isChromeStyle ?? true
        bridges.forEach { $0.attach(to: self) }
        adopt(raw)
    }

    // MARK: Page state

    var observedZoomLevel = 0.0

    var observedAudioMuted = false

    /// A zoom level set while the page had nothing in Chromium, applied
    /// when its first page starts loading (Chromium keeps zoom per site).
    @ObservationIgnored var pendingZoomLevel: Double?
    /// A mute set while the page had nothing in Chromium, applied when
    /// Chromium creates it.
    @ObservationIgnored var pendingAudioMuted: Bool?

    /// The page's tooltip while one shows; nil otherwise. Observable. It
    /// goes when the pointer moves off, and when the user scrolls or types
    /// in an offscreen page, the page navigates, the page loses
    /// focus, closes or is discarded. See ``TooltipPolicy``.
    public internal(set) var tooltip: Tooltip?

    /// Who shows ``tooltip``: ``TooltipPolicy/automatic`` (the default)
    /// leaves it to Chromium or the offscreen view, ``TooltipPolicy/custom``
    /// to the app. Takes effect with the next tooltip.
    @ObservationIgnored public var tooltipPolicy = TooltipPolicy.automatic

    /// The last point sent to an offscreen page, for its tooltip.
    @ObservationIgnored var lastPointerLocation = CGPoint.zero

    @ObservationIgnored var lastFindText: String?

    /// Whether this page's DevTools window is open.
    ///
    /// The value is observable. CEF reports no change, so CefKit reads the
    /// state back after ``showDevTools(inspecting:)`` and
    /// ``closeDevTools()``, and whenever any page, a DevTools window's
    /// included, is created or closes.
    public internal(set) var isShowingDevTools = false

    // MARK: Navigation

    /// Navigates the main frame. Before creation, sets the page the page
    /// opens with.
    ///
    /// Returns the navigation, to wait until it has loaded:
    ///
    /// ```swift
    /// try await page.load(url).waitUntilLoaded(timeout: .seconds(30))
    /// ```
    ///
    /// For a closed page the navigation has failed already, with
    /// ``CefError/pageClosed``.
    @discardableResult
    public func load(_ url: URL) -> CefNavigation {
        guard state != .closed else { return CefNavigation(url: url, failure: CefError.pageClosed) }
        let navigation = requestNavigation(to: url)
        startLoad(url)
        return navigation
    }

    /// Navigates the main frame without tracking it as a ``CefNavigation``.
    func startLoad(_ url: URL) {
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
    /// let title = try await page.evaluateJavaScript("document.title").stringValue
    /// ```
    ///
    /// The helper's renderer code runs the script in the page's main world
    /// with the V8 API, without the DevTools protocol, and the page sees
    /// only what the script does. A script that returns a promise is
    /// awaited through the promise's `then`.
    ///
    /// - Parameters:
    ///   - userGesture: Runs the script as if the user had just
    ///     clicked, as some APIs require (opening popups, entering
    ///     fullscreen, `beforeunload` prompts). Only the DevTools protocol can
    ///     grant that, so the call attaches ``devTools`` to the page,
    ///     which stays attached; see the guide's "Compatibility with bot
    ///     protection".
    ///   - timeout: How long to wait for the value; `nil` waits for as long
    ///     as it takes. When it runs out the call throws
    ///     ``CefError/timedOut``. Only the wait ends: the script, and a
    ///     promise it returned, go on running in the page.
    @discardableResult
    public func evaluateJavaScript(
        _ script: String, userGesture: Bool = false, timeout: Duration? = nil
    ) async throws -> CefJSON {
        try await withOptionalDeadline(timeout) { [self] in try await evaluateInMainFrame(script, userGesture: userGesture) }
    }

    private func evaluateInMainFrame(_ script: String, userGesture: Bool) async throws -> CefJSON {
        guard userGesture else { return try await pageScripting.evaluate(script, as: CefJSON.self) }
        let reply = try await devTools.send(
            "Runtime.evaluate",
            ["expression": .string(script), "returnByValue": true, "awaitPromise": true, "userGesture": true])
        if let exception = reply["exceptionDetails"].objectValue {
            throw CefJavaScriptError(exceptionDetails: .object(exception))
        }
        return reply["result"]["value"]
    }

    /// Evaluates JavaScript and decodes its value as `T`, as
    /// ``evaluateJavaScript(_:userGesture:timeout:)`` does.
    public func evaluateJavaScript<T: Decodable>(
        _ script: String, as type: T.Type = T.self, userGesture: Bool = false, timeout: Duration? = nil
    ) async throws -> T {
        try await withOptionalDeadline(timeout) { [self] () async throws -> T in
            // Without a gesture the value decodes straight from the renderer's
            // reply, with no JSON or `CefJSON` in between.
            guard userGesture else { return try await pageScripting.evaluate(script, as: T.self) }
            return try await evaluateInMainFrame(script, userGesture: true).decode(T.self)
        }
    }

    /// Injects `script` into every document loaded from now on, before the
    /// page's own scripts. For scripts known up front prefer
    /// ``CefPage/Configuration/userScripts``, which also cover the first page.
    ///
    /// The script reaches every renderer process that shows the page's
    /// frames now. A renderer process that the page moves to later (a
    /// navigation to another site) learns of it as that process's first
    /// document of the page starts, and runs it from its next document.
    public func addUserScript(_ script: CefUserScript) {
        ownUserScripts.append(script)
        pageScripting.configurationDidChange()
    }

    /// Stops injecting `script`, one of the page's own: from its
    /// configuration or added with ``addUserScript(_:)``. Documents that
    /// start loading afterwards no longer run it; a document already
    /// loaded keeps what it did until it is reloaded. Remove a profile's
    /// script from ``CefProfile/userScripts``.
    public func removeUserScript(_ script: CefUserScript) {
        let count = ownUserScripts.count
        ownUserScripts.removeAll { $0 == script }
        if ownUserScripts.count != count { pageScripting.configurationDidChange() }
    }

    /// Whether the profile's page defaults (user scripts, bridges,
    /// attachments) apply: everywhere but CefKit's hidden service pages.
    var usesProfileDefaults: Bool { !CefRuntime.shared.isServicePage(self) }

    /// The scripts the page's documents run: its profile's, then its own.
    var userScripts: [CefUserScript] {
        (usesProfileDefaults ? profile.userScripts : []) + ownUserScripts
    }

    /// The bridges the page's documents get: its own, then its profile's
    /// whose names none of its own has.
    var bridges: [CefBridge] {
        let own = configuration.bridges
        guard usesProfileDefaults else { return own }
        let names = Set(own.map(\.name))
        return own + profile.bridges.filter { !names.contains($0.name) }
    }

    // MARK: Lifetime

    /// Closes the page. Unless `force` is set, a page's `beforeunload`
    /// handler may ask the user to stay.
    public func close(force: Bool = false) {
        loads.pageWillClose()
        if raw != nil {
            isChromiumBrowserClosing = true
            parkedNativeView = nil
        }
        guard raw != nil else {
            // Not created yet, or Chromium is still creating it: it closes
            // now, and a page Chromium finishes creating after this
            // closes at once (`CefBrowserClient.wrapper(adopting:)`).
            if state == .pending { handleClosed() }
            // Discarded by closing its Chromium page: nothing is left
            // to close.
            if state == .live, isDiscarded { handleClosed() }
            return
        }
        if let signInPromptURL, signInPromptURL == url {
            // With `CefRuntime.AuthenticationPromptPolicy.chromium`, Chromium's sign-in
            // window for an Alloy-style page crashes the process when its
            // page closes under it. A navigation dismisses the window, so
            // leave the page first and close once the window has gone.
            self.signInPromptURL = nil
            let cefWindows = Set(CefWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
            let chromiumWindows = NSApp.windows.filter {
                $0.isVisible && $0 !== hostWindow && !cefWindows.contains(ObjectIdentifier($0))
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
    /// an Alloy-style page. While the page still shows it, Chromium
    /// may be showing its own sign-in window for it.
    @ObservationIgnored var signInPromptURL: URL?

    /// Suspends until the page exists in Chromium and can be used,
    /// restoring it first if it is discarded.
    ///
    /// When an attachment prepares before the first document
    /// (``CefPageAttachment/preparesBeforeFirstDocument``), and after a
    /// discard, that includes the set-up before the first page: every
    /// attachment's ``CefPageAttachment/pageDidCreate(_:)`` (or
    /// ``CefPageAttachment/pageDidRestore(_:)``) has returned, and
    /// after a discard the DevTools domains enabled before are on again.
    /// Otherwise this does not wait for attachments, which are told of the
    /// creation as it returns and may still be setting up.
    ///
    /// A page on a persistent profile Chromium is still loading is
    /// created once it has (``CefProfile/ready()``).
    ///
    /// Throws ``CefError/pageClosed`` if the page closes first (as
    /// quitting closes one still waiting for its profile),
    /// ``CefError/profileUnavailable(_:)`` if it closed because Chromium
    /// could not load its profile, and `CancellationError` if the calling
    /// task is cancelled.
    public func ready() async throws {
        // The set-up itself runs while the page is not ready yet, and
        // needs only the native page.
        if Self.settingUp == id {
            guard state == .live, raw != nil else { throw CefError.pageClosed }
            return
        }
        if isDiscarded {
            restore()
            try await restoreWaiters.wait()
        }
        switch state {
        case .live where !isBootstrapping: return
        case .closed:
            // No page is ever created on a profile Chromium could not
            // load: that is why this one closed.
            if case .failed(let reason) = (configuration.profile ?? .default).readiness {
                throw CefError.profileUnavailable(reason)
            }
            throw CefError.pageClosed
        case .pending, .live:
            try await readyWaiters.wait()
        }
    }

    /// Whether the page is setting itself up before its first page.
    @_spi(Testing) public var isSettingUp: Bool { isBootstrapping }

    /// The page whose set-up (`bootstrap()`) the current task runs.
    @TaskLocal static var settingUp: ObjectIdentifier?

    /// The NSView Chromium created for a windowed page.
    public var nativeView: NSView? {
        withHost { host -> NSView? in
            guard let handle = host.pointee.get_window_handle(host) else { return nil }
            return Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
        } ?? nil
    }

    /// The window currently showing this page, if any.
    public var hostWindow: NSWindow? {
        hostView?.window ?? nativeView?.window
    }

    /// Whether this page renders offscreen.
    public var isOffscreen: Bool { client?.isOffscreen ?? false }
}

// MARK: - Host / frame access

extension CefPage {
    /// Runs `body` with the page host, or returns nil when not live.
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
        loads.pageWillClose()
        return withHost { $0.pointee.try_close_browser($0) != 0 } ?? true
    }
}

// MARK: - Supporting types

/// A JavaScript exception thrown by code passed to
/// ``CefPage/evaluateJavaScript(_:)``.
public struct CefJavaScriptError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var column: Int

    /// Creates a value of your own, for previews and tests.
    public init(message: String, line: Int = 0, column: Int = 0) {
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
