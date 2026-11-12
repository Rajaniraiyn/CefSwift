import AppKit
import CCef
import Foundation
import Observation

// MARK: - Options

/// How a browser's pixels reach the screen.
public enum CefRendering: Sendable, Equatable {
    /// Chromium draws into its own native view inside yours. Input, IME and
    /// accessibility are handled by Chromium. Native views cannot be layered
    /// over the page.
    case windowed
    /// Chromium renders offscreen into a shared `IOSurface` that CefSwift
    /// composites in a layer — a true subview that native UI can overlap.
    /// Requires ``CefConfiguration/isOffscreenRenderingEnabled``.
    case offscreen(frameRate: Int = 60)

    public static var offscreen: CefRendering { .offscreen() }
}

/// Creation-time settings for a ``CefBrowser``.
@MainActor
public struct CefBrowserOptions {
    /// How the browser renders when hosted in a `CefWebView`.
    public var rendering: CefRendering = .windowed
    /// Runtime style. Browsers embedded in a view always use Alloy; only
    /// ``CefBrowserWindow`` hosts Chrome style.
    public var runtimeStyle: CefRuntimeStyle = .default
    /// Background shown before the page paints.
    public var backgroundColor: NSColor?
    /// The profile (cookies, storage, cache, preferences) to browse with.
    /// `nil` uses ``CefProfile/default``.
    public var profile: CefProfile?
    /// JavaScript bridges exposed to pages in this browser.
    public var bridges: [CefBridge] = []
    /// Scripts injected into every document before its own scripts run.
    public var userScripts: [CefUserScript] = []
    /// Shapes the context menu: hide built-in entries, add your own.
    public var contextMenu = CefContextMenuConfiguration()
    /// Inspects — and may block, redirect or amend — every network request.
    public var requestFilter: CefRequestFilter?
    /// Whether horizontal swipes navigate back and forward (offscreen
    /// rendering; Chrome-style windows follow the system setting).
    public var allowsBackForwardNavigationGestures = false
    /// (Offscreen only) Forward raw trackpad touches to Chromium instead of
    /// translating gestures natively.
    public var forwardsRawTouchEvents = false

    public init() {}
}

/// A script injected into every document a browser loads, before the page's
/// own scripts run.
///
/// Scripts run on every page the browser shows, Chromium's own `chrome://`
/// pages included, which makes them the tool for customizing those pages:
///
/// ```swift
/// options.userScripts = [
///     // Hide Chromium's update status on the settings About page.
///     .styleSheet("settings-about-page #updateStatusContainer { display: none }",
///                 matching: "chrome://settings/*"),
/// ]
/// ```
public struct CefUserScript: Sendable, Equatable {
    public var source: String
    /// Limits the script to pages whose URL matches this pattern, where `*`
    /// stands for any run of characters: `"chrome://settings/*"`,
    /// `"https://*.example.com/*"`. `nil` runs it everywhere. A scoped script
    /// runs inside a function, so its top-level declarations are not global.
    public var urlPattern: String?
    /// Run in an isolated world with this name instead of the page's own
    /// JavaScript context (the page cannot see or tamper with it).
    public var isolatedWorldName: String?

    public init(source: String, matching urlPattern: String? = nil, isolatedWorldName: String? = nil) {
        self.source = source
        self.urlPattern = urlPattern
        self.isolatedWorldName = isolatedWorldName
    }

    /// A script that adds `css` to matching pages.
    ///
    /// Pages built from web components — every `chrome://` page — keep their
    /// markup inside shadow roots that ordinary stylesheets cannot reach.
    /// With `includingShadowRoots` the rules are applied inside each shadow
    /// root as well — including roots whose component later sets its own
    /// `adoptedStyleSheets` — so a selector written for a component's
    /// internals matches there. Selectors still cannot cross a shadow
    /// boundary: `settings-section #row` matches nothing when `#row` lives in
    /// the section's shadow root; write `#row`.
    public static func styleSheet(
        _ css: String, matching urlPattern: String? = nil, includingShadowRoots: Bool = true
    ) -> CefUserScript {
        // Covers shadow roots that already exist and those created later.
        // Components commonly assign their own `adoptedStyleSheets` after
        // attaching a shadow root (Lit does), which would drop the sheet, so
        // such assignments keep it.
        let shadowRoots = """
              const visit = root => {
                for (const element of root.querySelectorAll('*')) {
                  if (element.shadowRoot) { adopt(element.shadowRoot); visit(element.shadowRoot); }
                }
              };
              const sheets = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, 'adoptedStyleSheets');
              if (sheets?.set) {
                Object.defineProperty(ShadowRoot.prototype, 'adoptedStyleSheets', {
                  ...sheets,
                  set(value) { sheets.set.call(this, [...value].includes(sheet) ? value : [...value, sheet]); },
                });
              }
              visit(document);
              const attachShadow = Element.prototype.attachShadow;
              Element.prototype.attachShadow = function (options) {
                const root = attachShadow.call(this, options);
                adopt(root);
                return root;
              };
            """
        return CefUserScript(
            source: """
                (() => {
                  const sheet = new CSSStyleSheet();
                  sheet.replaceSync(\(CefJSON.string(css).text));
                  const adopt = root => { root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet]; };
                  adopt(document);
                \(includingShadowRoots ? shadowRoots : "")
                })();
                """,
            matching: urlPattern)
    }

    /// The source as injected: wrapped in a URL check when scoped.
    var injectedSource: String {
        guard let urlPattern else { return source }
        let expression = NSRegularExpression.escapedPattern(for: urlPattern).replacingOccurrences(of: "\\*", with: ".*")
        return """
            (() => {
              if (!new RegExp(\(CefJSON.string("^" + expression + "$").text)).test(location.href)) return;
              \(source)
            })();
            """
    }
}

/// Progress of a find-in-page session.
public struct CefFindResult: Sendable, Equatable {
    public var matchCount: Int
    /// 1-based index of the highlighted match; 0 when there is none.
    public var activeMatchIndex: Int
    /// Whether the search has finished counting.
    public var isFinal: Bool
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

    public private(set) var state: State = .pending
    /// The main frame's URL.
    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// Load progress of the current navigation, 0…1.
    public private(set) var estimatedProgress = 0.0
    /// The address of the page's icon, as the page declares it. `nil` until
    /// the page reports one, and again when a new page starts loading.
    public private(set) var faviconURL: URL?
    /// The page's icon, downloaded from ``faviconURL`` at up to 32 points
    /// (with Retina representations when the site offers them). `nil` until
    /// it arrives, for pages without an icon, and again when a new page
    /// starts loading.
    ///
    /// ```swift
    /// Image(nsImage: browser.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
    /// ```
    public private(set) var favicon: NSImage?
    /// Whether the page is in HTML fullscreen.
    public private(set) var isFullscreen = false
    /// Status text, such as the URL of the link under the pointer.
    public private(set) var statusText = ""
    /// Downloads started by this browser, oldest first.
    public private(set) var downloads: [CefDownload] = []
    /// Progress of an in-flight swipe-to-navigate gesture: 0 at rest, toward
    /// -1 while swiping back, toward 1 while swiping forward. Draw your own
    /// indicator from it. CefSwiftUI's offscreen view updates it; offscreen
    /// rendering only.
    public package(set) var navigationGestureProgress = 0.0
    /// The latest result of ``find(_:backwards:caseSensitive:)``.
    public private(set) var findResult: CefFindResult?

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
    @ObservationIgnored public let options: CefBrowserOptions
    /// Chromium's identifier for this browser; `-1` until created.
    @ObservationIgnored public private(set) var identifier: Int32 = -1
    /// The browser that opened this one, for popups.
    @ObservationIgnored public private(set) weak var opener: CefBrowser?
    /// For a popup, the window features its page asked for — the size to
    /// give the popup's window, for instance.
    @ObservationIgnored public internal(set) var popupFeatures: CefPopupFeatures?

    /// Chrome DevTools Protocol access to this browser.
    @ObservationIgnored public private(set) lazy var devTools = CefDevTools(browser: self)

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    // MARK: Internals

    @ObservationIgnored private(set) var raw: CefRef<cef_browser_t>?
    @ObservationIgnored private(set) var client: CefBrowserClient?
    @ObservationIgnored private var initialURL: URL?
    @ObservationIgnored private(set) var isBootstrapping = false
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    @ObservationIgnored private var downloadControls: [UInt32: CefRef<cef_download_item_callback_t>] = [:]
    @ObservationIgnored private(set) var isChromeStyle = false
    @ObservationIgnored private var isEmbeddedView = false
    /// The view hosting this browser: the parent of a windowed browser's
    /// native view, or the offscreen host.
    @ObservationIgnored public internal(set) weak var hostView: NSView?

    /// Creates a browser model. Nothing is created in Chromium until the
    /// browser is hosted.
    ///
    /// - Parameters:
    ///   - url: The page the browser opens with.
    ///   - options: Creation-time settings.
    ///   - delegate: The browser's ``delegate``, held weakly. Keep your own
    ///     strong reference to it; a delegate created inline, such as
    ///     `CefBrowser(url: url, delegate: Policy())`, is released at once.
    public init(url: URL? = nil, options: CefBrowserOptions = .init(), delegate: CefBrowserDelegate? = nil) {
        self.url = url
        self.initialURL = url
        self.options = options
        self.delegate = delegate
    }

    /// Wraps a browser Chromium created on its own (popup, Chrome UI tab).
    init(adopting raw: CefRef<cef_browser_t>, client: CefBrowserClient, opener: CefBrowser?) {
        self.options = opener?.options ?? CefBrowserOptions()
        self.client = client
        self.opener = opener
        self.isChromeStyle = opener?.isChromeStyle ?? true
        adopt(raw)
    }

    // MARK: Navigation

    /// Navigates the main frame. Before creation, sets the page the browser
    /// opens with.
    public func load(_ url: URL) {
        guard state != .closed else { return }
        guard raw != nil, !isBootstrapping else {
            initialURL = url
            self.url = url
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
        guard let raw = raw?.pointer else { return }
        if ignoringCache {
            raw.pointee.reload_ignore_cache(raw)
        } else {
            raw.pointee.reload(raw)
        }
    }

    // MARK: JavaScript

    /// Runs JavaScript in the main frame without waiting for a result.
    public func executeJavaScript(_ script: String) {
        withMainFrame { frame in
            CefStringUtil.withCefString(script) { code in
                frame.pointee.execute_java_script(frame, code, nil, 0)
            }
        }
    }

    /// Evaluates JavaScript in the main frame and returns its value.
    ///
    /// Promises are awaited. A thrown JavaScript exception surfaces as
    /// ``CefJavaScriptError``.
    ///
    /// ```swift
    /// let title = try await browser.evaluateJavaScript("document.title").stringValue
    /// ```
    @discardableResult
    public func evaluateJavaScript(_ script: String) async throws -> CefJSON {
        let reply = try await devTools.send(
            "Runtime.evaluate",
            ["expression": .string(script), "returnByValue": true, "awaitPromise": true, "userGesture": true])
        if let exception = reply["exceptionDetails"].objectValue {
            throw CefJavaScriptError(exceptionDetails: .object(exception))
        }
        return reply["result"]["value"]
    }

    /// Evaluates JavaScript and decodes its value as `T`.
    public func evaluateJavaScript<T: Decodable>(_ script: String, as type: T.Type = T.self) async throws -> T {
        try await evaluateJavaScript(script).decode(T.self)
    }

    /// Injects `script` into every document loaded from now on, before the
    /// page's own scripts. For scripts known up front prefer
    /// ``CefBrowserOptions/userScripts``, which also cover the first page.
    public func addUserScript(_ script: CefUserScript) async throws {
        var params: [String: CefJSON] = ["source": .string(script.injectedSource)]
        if let world = script.isolatedWorldName {
            params["worldName"] = .string(world)
        }
        try await devTools.send("Page.addScriptToEvaluateOnNewDocument", .object(params))
    }

    // MARK: Page controls

    /// The page's zoom level: 0 is 100%, and each step of 1 scales the page
    /// by 20% (1.2ⁿ).
    ///
    /// The value is observable. Besides your own changes, it follows the
    /// zoom Chromium applies itself: the level it remembers for each site,
    /// which changes as the browser moves between sites and when another
    /// browser zooms the same site, and Chrome's zoom commands
    /// (``CefChromeCommand/zoomIn``, ``CefChromeCommand/zoomOut``,
    /// ``CefChromeCommand/resetZoom``), whether run through
    /// ``execute(_:disposition:)`` or chosen in a Chrome-style browser. CEF
    /// reports no zoom changes, so CefKit reads the level back after each of
    /// those events; a change Chromium makes in any other way shows up at
    /// the next navigation.
    ///
    /// In a windowed browser, pinching magnifies the page without changing
    /// its zoom level; `CefOffscreenBrowserView` turns pinches into
    /// zoom-level changes. Setting the level before the browser is live
    /// has no effect.
    public var zoomLevel: Double {
        get { observedZoomLevel }
        set {
            withHost { $0.pointee.set_zoom_level($0, newValue) }
            // Chromium applies the level per site, so other browsers on the
            // same site follow.
            CefBrowser.refreshZoomLevels()
        }
    }

    private var observedZoomLevel = 0.0

    /// Reads the zoom level back from Chromium.
    func refreshZoomLevel() {
        let level = withHost { $0.pointee.get_zoom_level($0) } ?? observedZoomLevel
        if level != observedZoomLevel { observedZoomLevel = level }
    }

    /// Reads every browser's zoom level back, now and once Chromium has
    /// finished applying an asynchronous change.
    static func refreshZoomLevels() {
        let refresh = { CefRuntime.shared.browsers.forEach { $0.refreshZoomLevel() } }
        refresh()
        Task {
            await Task.yield()
            refresh()
            try? await Task.sleep(for: .milliseconds(250))
            refresh()
        }
    }

    public var isAudioMuted: Bool {
        get { withHost { $0.pointee.is_audio_muted($0) != 0 } ?? false }
        set { withHost { $0.pointee.set_audio_muted($0, newValue ? 1 : 0) } }
    }

    /// Searches the page, or advances to the next match when `text` repeats
    /// the previous search — the previous one when `backwards` is set.
    /// Results arrive in ``findResult``.
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) {
        let isRepeat = text == lastFindText
        lastFindText = text
        withHost { host in
            CefStringUtil.withCefString(text) {
                host.pointee.find(host, $0, backwards ? 0 : 1, caseSensitive ? 1 : 0, isRepeat ? 1 : 0)
            }
        }
    }

    /// Ends the find session.
    public func stopFinding(clearingSelection: Bool = true) {
        lastFindText = nil
        findResult = nil
        withHost { $0.pointee.stop_finding($0, clearingSelection ? 1 : 0) }
    }

    @ObservationIgnored private var lastFindText: String?

    /// Opens the system print dialog for the page.
    public func print() {
        withHost { $0.pointee.print($0) }
    }

    /// Renders the page to a PDF file.
    public func printToPDF(at destination: URL) async throws {
        try await ready()
        let succeeded: Bool = await withCheckedContinuation { continuation in
            let callback = PDFPrintCallback(continuation: continuation).makeCallback()
            var settings = cef_pdf_print_settings_t()
            settings.size = MemoryLayout<cef_pdf_print_settings_t>.stride
            settings.print_background = 1
            let started: Void? = withHost { host in
                CefStringUtil.withCefString(destination.path) {
                    host.pointee.print_to_pdf(host, $0, &settings, callback)
                }
            }
            if started == nil {
                cefRelease(callback)
            }
        }
        guard succeeded else { throw CefError.operationFailed("print_to_pdf did not produce \(destination.path)") }
    }

    /// Captures the visible page as PNG data.
    public func snapshot() async throws -> Data {
        let reply = try await devTools.send("Page.captureScreenshot", ["format": "png"])
        guard let base64 = reply["data"].stringValue, let data = Data(base64Encoded: base64) else {
            throw CefError.operationFailed("Page.captureScreenshot returned no image data")
        }
        return data
    }

    // MARK: DevTools

    /// Opens Chrome DevTools for this browser in its own window, optionally
    /// inspecting the element at `point` (view coordinates).
    public func showDevTools(inspecting point: CGPoint? = nil) {
        withHost { host in
            var windowInfo = cef_window_info_t()
            windowInfo.size = MemoryLayout<cef_window_info_t>.stride
            windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: 900, height: 700)
            var settings = cef_browser_settings_t()
            settings.size = MemoryLayout<cef_browser_settings_t>.stride
            if let point {
                var target = cef_point_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()))
                host.pointee.show_dev_tools(host, &windowInfo, nil, &settings, &target)
            } else {
                host.pointee.show_dev_tools(host, &windowInfo, nil, &settings, nil)
            }
        }
    }

    public func closeDevTools() {
        withHost { $0.pointee.close_dev_tools($0) }
    }

    /// Whether this browser's DevTools window is open.
    public var isShowingDevTools: Bool {
        withHost { $0.pointee.has_dev_tools($0) != 0 } ?? false
    }

    // MARK: Chrome commands

    /// Whether Chrome can currently run `command` for this browser.
    /// Chrome-style browsers only.
    public func canExecute(_ command: CefChromeCommand) -> Bool {
        withHost { $0.pointee.can_execute_chrome_command($0, Int32(command.rawValue)) != 0 } ?? false
    }

    /// Runs one of Chrome's own commands — open history, zoom, find, print,
    /// bookmark, and so on. Chrome-style browsers only.
    public func execute(_ command: CefChromeCommand, disposition: CefWindowOpenDisposition = .currentTab) {
        withHost { $0.pointee.execute_chrome_command($0, Int32(command.rawValue), disposition.cefValue) }
        if command.isZoomCommand { CefBrowser.refreshZoomLevels() }
    }

    // MARK: Downloads

    public func cancelDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.cancel($0.pointer) }
    }

    public func pauseDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.pause($0.pointer) }
    }

    public func resumeDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.resume($0.pointer) }
    }

    /// Downloads `url` as if the user had clicked a download link.
    public func startDownload(_ url: URL) {
        withHost { host in
            CefStringUtil.withCefString(url.absoluteString) { host.pointee.start_download(host, $0) }
        }
    }

    // MARK: Lifetime

    /// Closes the browser. Unless `force` is set, a page's `beforeunload`
    /// handler may ask the user to stay.
    public func close(force: Bool = false) {
        guard raw != nil else {
            if state == .pending { state = .closed }
            return
        }
        if let signInPromptURL, signInPromptURL == url {
            // Chromium's sign-in window for an Alloy-style browser crashes
            // the process when its browser closes under it. A navigation
            // dismisses the window, so leave the page first and close once
            // the window has gone.
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
    @ObservationIgnored private var signInPromptURL: URL?

    /// Suspends until the browser exists in Chromium. Throws if it closes
    /// first.
    public func ready() async throws {
        switch state {
        case .live: return
        case .closed: throw CefError.browserClosed
        case .pending:
            try await withCheckedThrowingContinuation { readyWaiters.append($0) }
        }
    }

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

// MARK: - Creation

extension CefBrowser {
    private struct Blueprint {
        var client: UnsafeMutablePointer<cef_client_t>
        var settings: cef_browser_settings_t
        var url: String
        var requestContext: UnsafeMutablePointer<cef_request_context_t>?
    }

    /// Builds everything browser creation needs. Each returned reference is
    /// consumed by the CEF creation call it is passed to.
    private func makeBlueprint(offscreenHost: CefOffscreenHost? = nil, frameRate: Int = 0) -> Blueprint {
        precondition(CefRuntime.shared.isInitialized, "Create browsers after CefRuntime.shared.initialize().")
        precondition(state == .pending && client == nil, "This CefBrowser has already been created.")

        let client = CefBrowserClient(
            browser: self,
            requestFilter: options.requestFilter,
            chromeUI: CefRuntime.shared.configuration?.chromeUI ?? .init())
        client.offscreenHost = offscreenHost
        self.client = client

        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        settings.windowless_frame_rate = Int32(frameRate)
        if let color = options.backgroundColor {
            settings.background_color = cefColor(color.cgColor)
        }

        // Bridges and user scripts must be installed before the first real
        // document, so such browsers start blank and navigate once set up.
        isBootstrapping = !options.bridges.isEmpty || !options.userScripts.isEmpty
        let url = isBootstrapping ? "about:blank" : (initialURL?.absoluteString ?? "about:blank")

        return Blueprint(
            client: client.makeClient(),
            settings: settings,
            url: url,
            requestContext: (options.profile ?? .default).makeRequestContext())
    }

    /// Shows the browser as a native child view of `parentView`: creates it
    /// on first use, and afterwards moves its view there. `CefWebView` calls
    /// this; call it yourself to host a browser in AppKit.
    public func host(windowedIn parentView: NSView) {
        guard state != .closed else { return }
        if client == nil {
            createWindowed(in: parentView)
        }
        guard let native = nativeView else { return }
        if native.superview !== parentView {
            native.removeFromSuperview()
            parentView.addSubview(native)
        }
        native.frame = parentView.bounds
        native.autoresizingMask = [.width, .height]
        hostView = parentView
    }

    /// Shows the browser through an offscreen host: creates it on first
    /// use, and afterwards redirects its frames and input to `host`.
    public func host(offscreenIn host: CefOffscreenHost, size: CGSize) {
        guard state != .closed else { return }
        guard let client else {
            createOffscreen(host: host, size: size)
            return
        }
        guard client.offscreenHost !== host else { return }
        client.offscreenHost = host
        hostView = host as? NSView
        hostViewDidResize()
        setNeedsDisplay()
    }

    private func createWindowed(in parentView: NSView) {
        var blueprint = makeBlueprint()
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.bounds = cef_rect_t(parentView.bounds)
        windowInfo.parent_view = Unmanaged.passUnretained(parentView).toOpaque()
        var style = options.runtimeStyle
        if style == .default, let configured = CefRuntime.shared.configuration?.defaultRuntimeStyle {
            style = configured
        }
        windowInfo.runtime_style = style.cefValue
        hostView = parentView
        isEmbeddedView = true

        // on_after_created adopts the browser before this returns.
        let created = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser_sync(
                &windowInfo, blueprint.client, $0, &blueprint.settings, nil, blueprint.requestContext)
        }
        cefRelease(created)
        if created == nil { creationFailed() }
    }

    private func createOffscreen(host: CefOffscreenHost, size: CGSize) {
        precondition(
            CefRuntime.shared.configuration?.isOffscreenRenderingEnabled == true,
            "Offscreen browsers need CefConfiguration.isOffscreenRenderingEnabled = true at initialize().")
        var frameRate = 60
        if case .offscreen(let requested) = options.rendering { frameRate = requested }
        var blueprint = makeBlueprint(offscreenHost: host, frameRate: frameRate)

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.windowless_rendering_enabled = 1
        windowInfo.shared_texture_enabled = 1
        // The host drives frames from a display link, so painting follows
        // the real refresh rate.
        windowInfo.external_begin_frame_enabled = 1
        windowInfo.bounds = cef_rect_t(CGRect(origin: .zero, size: size))
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        hostView = host as? NSView

        let started = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser(
                &windowInfo, blueprint.client, $0, &blueprint.settings, nil, blueprint.requestContext)
        }
        if started == 0 { creationFailed() }
    }

    /// Creates a Chrome-style browser view for a ``CefBrowserWindow``.
    /// Returns a +1 `cef_browser_view_t`.
    func createBrowserView(
        delegate: UnsafeMutablePointer<cef_browser_view_delegate_t>
    ) -> UnsafeMutablePointer<cef_browser_view_t>? {
        var blueprint = makeBlueprint()
        isChromeStyle = true
        return CefStringUtil.withCefString(blueprint.url) {
            cef_browser_view_create(blueprint.client, $0, &blueprint.settings, nil, blueprint.requestContext, delegate)
        }
    }

    /// Creates the browser in a window owned and drawn entirely by Chrome:
    /// tab strip, omnibox, menus, extensions toolbar.
    func createInChromeUIWindow(frame: CGRect?) {
        var blueprint = makeBlueprint()
        isChromeStyle = true
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME
        if let frame {
            windowInfo.bounds = cef_rect_t(screenRect: frame)
        }
        let started = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser(
                &windowInfo, blueprint.client, $0, &blueprint.settings, nil, blueprint.requestContext)
        }
        if started == 0 { creationFailed() }
    }

    private func creationFailed() {
        client = nil
        handleClosed()
    }

    /// Takes over the live `cef_browser_t` once Chromium has created it.
    func adopt(_ raw: CefRef<cef_browser_t>) {
        self.raw = raw
        identifier = raw.pointer.pointee.get_identifier(raw.pointer)
        state = .live
        CefRuntime.shared.register(self)
        readyWaiters.forEach { $0.resume() }
        readyWaiters = []
        refreshZoomLevel()
        delegate?.browserDidCreate(self)
        if isBootstrapping {
            Task { await bootstrap() }
        }
    }

    /// Installs bridges and user scripts, then performs the real first load.
    private func bootstrap() async {
        do {
            for script in options.userScripts {
                try await addUserScript(script)
            }
            for bridge in options.bridges {
                try await bridge.install(in: self)
            }
        } catch {
            CefLog.error("page bootstrap failed for browser \(identifier): \(error)")
        }
        isBootstrapping = false
        if let initialURL, state == .live {
            load(initialURL)
        }
    }
}

// MARK: - Callbacks from the client

extension CefBrowser {
    /// Chromium does not run document-start scripts in its own `chrome://`
    /// pages, so user scripts are evaluated there as each page starts
    /// loading instead.
    func mainFrameDidStartLoading(_ url: URL?) {
        guard !isBootstrapping else { return }
        // The new document reports its own icon.
        faviconURL = nil
        favicon = nil
        guard url?.scheme == "chrome", !options.userScripts.isEmpty else { return }
        Task {
            for script in options.userScripts where script.isolatedWorldName == nil {
                _ = try? await devTools.send("Runtime.evaluate", ["expression": .string(script.injectedSource)])
            }
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

    func mainFrameDidFailLoad(_ error: CefLoadError) {
        // ERR_INVALID_AUTH_CREDENTIALS: Chromium asks for credentials itself.
        if error.code == -338, !isChromeStyle { signInPromptURL = error.url }
        delegate?.browser(self, didFailLoad: error)
    }

    func applyFullscreen(_ isFullscreen: Bool) { self.isFullscreen = isFullscreen }
    func applyStatusText(_ text: String) { statusText = text }
    func applyFindResult(_ result: CefFindResult) { findResult = result }

    func applyDownload(_ download: CefDownload, control: CefRef<cef_download_item_callback_t>?) {
        if let index = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[index] = download
        } else {
            downloads.append(download)
        }
        downloadControls[download.id] = (download.isComplete || download.isCancelled) ? nil : control
        delegate?.browser(self, downloadDidUpdate: download)
    }

    /// Routes a window-open request. Returns `true` when CEF must not create
    /// its own popup.
    func route(_ request: CefWindowOpenRequest) -> Bool {
        let decided = (delegate ?? CefDefaultBrowserDelegate.shared).browser(self, decideWindowOpenFor: request)
        switch CefWindowOpenPolicy.resolve(decided, for: request) {
        case .allowNativePopup:
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

    /// Asks the delegate an asynchronous question and applies the answer.
    func decide<Decision: Sendable>(
        _ ask: @escaping @MainActor (CefBrowserDelegate) async -> Decision,
        then apply: @escaping @MainActor (Decision) -> Void
    ) {
        let delegate = delegate ?? CefDefaultBrowserDelegate.shared
        Task { apply(await ask(delegate)) }
    }

    func handleClosed() {
        guard state != .closed else { return }
        state = .closed
        isLoading = false
        canGoBack = false
        canGoForward = false
        downloadControls = [:]
        devTools.invalidate()
        readyWaiters.forEach { $0.resume(throwing: CefError.browserClosed) }
        readyWaiters = []
        delegate?.browserDidClose(self)
        raw = nil
        client = nil
        CefRuntime.shared.unregister(self)
    }
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

/// Receives a favicon from `download_image` and converts it to an
/// `NSImage` with one representation per scale factor Chromium decoded.
private final class FaviconDownload: @unchecked Sendable {
    /// The largest icon asked for, in points.
    static let maximumSize = 32

    private let completion: @MainActor (NSImage?) -> Void

    init(completion: @escaping @MainActor (NSImage?) -> Void) {
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

/// Bridges `cef_pdf_print_callback_t` to a continuation, which resumes with
/// `false` if CEF drops the callback without calling it.
private final class PDFPrintCallback: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    deinit {
        continuation?.resume(returning: false)
    }

    func makeCallback() -> UnsafeMutablePointer<cef_pdf_print_callback_t> {
        let callback = cefAllocate(cef_pdf_print_callback_t.self, owner: self)
        callback.pointee.on_pdf_print_finished = { s, _, ok in
            guard let owner = cefOwner(PDFPrintCallback.self, s) else { return }
            owner.continuation?.resume(returning: ok != 0)
            owner.continuation = nil
        }
        return callback
    }
}

extension cef_rect_t {
    /// A view-local rectangle, rounded to whole points and at least 1×1.
    init(_ rect: CGRect) {
        self.init(
            x: Int32(rect.origin.x.rounded()), y: Int32(rect.origin.y.rounded()),
            width: Int32(max(1, rect.width.rounded())), height: Int32(max(1, rect.height.rounded())))
    }

    /// An AppKit screen rectangle (bottom-left origin) in CEF's screen
    /// coordinates (top-left origin of the primary display).
    @MainActor
    init(screenRect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenRect.maxY
        self.init(
            x: Int32(screenRect.origin.x.rounded()), y: Int32((primaryHeight - screenRect.maxY).rounded()),
            width: Int32(screenRect.width.rounded()), height: Int32(screenRect.height.rounded()))
    }
}
