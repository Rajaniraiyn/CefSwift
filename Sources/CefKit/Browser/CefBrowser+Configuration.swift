import AppKit
import CCef
import Foundation
import Observation
import CefBase

extension CefBrowser {
    /// How a browser's pixels reach the screen.
    public enum Rendering: Sendable, Equatable {
        /// Chromium draws into its own native view inside yours. Input, IME and
        /// accessibility are handled by Chromium. Native views cannot be layered
        /// over the page.
        case windowed
        /// Chromium renders offscreen into a shared `IOSurface` that CefSwift
        /// composites in a layer — a true subview that native UI can overlap.
        /// Requires ``CefRuntime/Configuration/isOffscreenRenderingEnabled``.
        case offscreen(frameRate: Int = 60)

        public static var offscreen: CefBrowser.Rendering { .offscreen() }
    }
}

extension CefBrowser {
    /// Creation-time settings for a ``CefBrowser``.
    @MainActor
    public struct Configuration {
        /// How the browser renders when hosted in a `CefWebView`.
        public var rendering: CefBrowser.Rendering = .windowed
        /// The canvas: the color shown where the page paints nothing, as
        /// before its first paint, behind a page with no background of its
        /// own, and in the area a resize uncovers until the page repaints.
        ///
        /// White, as in Chrome and `WKWebView`, whatever the app's or the
        /// system's appearance. A page that opts into a dark color scheme
        /// (`<meta name="color-scheme" content="dark">`, or `light dark`
        /// while the app's appearance is dark) gets Chromium's dark
        /// canvas instead, as in Chrome, except in a Chrome-style browser,
        /// whose page has no canvas of its own and shows this color behind
        /// it (see the guide's "Background"). Chromium paints only opaque
        /// canvases, so the color's alpha is ignored; for a see-through
        /// page, turn off ``drawsBackground``. A dynamic color is resolved
        /// in the app's appearance when the browser is created.
        public var backgroundColor: NSColor = .white
        /// Whether Chromium paints the canvas. `false` leaves the parts of
        /// the page that paint nothing transparent, showing what is behind
        /// the view, as `WKWebView`'s `drawsBackground`. Offscreen browsers
        /// only: Chromium keeps the canvas of a windowed or Chrome-style
        /// browser opaque, and ignores this for them.
        public var drawsBackground = true
        /// The profile (cookies, storage, cache, preferences) to browse with.
        /// `nil` uses ``CefProfile/default``.
        public var profile: CefProfile?
        /// JavaScript bridges exposed to pages in this browser.
        public var bridges: [CefBridge] = []
        /// Scripts injected into every document before its own scripts run.
        public var userScripts: [CefUserScript] = []
        /// Shapes the context menu: hide built-in entries, add your own.
        public var contextMenu = CefBrowser.Configuration.ContextMenu()
        /// Inspects — and may block, redirect or amend — every network request.
        public var requestFilter: CefRequestFilter?
        /// Whether horizontal swipes navigate back and forward, as the system's
        /// "Swipe between pages" setting allows: two-finger scrolls that start
        /// sideways, and the dedicated navigation swipe. Chrome-style browsers
        /// (``CefWindow``) use Chrome's own swipe handling; views use
        /// CefSwift's. While a swipe is in progress,
        /// ``CefBrowser/navigationGestureProgress`` follows it.
        public var allowsBackForwardNavigationGestures = false
        /// Whether a Chrome-style browser (``CefWindow``) shows Chromium's
        /// own arrow while a swipe is in progress, as Chrome does. Turn it
        /// off to draw your own from ``CefBrowser/navigationGestureProgress``,
        /// in ``CefWindow/pageOverlay`` for instance. Alloy-style browsers in
        /// views have no indicator of Chromium's: draw one over the view.
        public var showsChromiumNavigationGestureIndicator = true
        /// (Offscreen only) Forward raw trackpad touches to Chromium instead of
        /// translating gestures natively.
        public var forwardsRawTouchEvents = false
        /// Code that sets up each browser made with this configuration, in
        /// order; see ``CefBrowserAttachment``. Popups get their opener's.
        public var attachments: [any CefBrowserAttachment] = []
        /// (Offscreen only) When Chromium builds the page's accessibility tree,
        /// which VoiceOver and other assistive apps read. Building it costs
        /// time and memory, so by default it starts on first demand.
        public var offscreenAccessibility: CefBrowser.AccessibilityPolicy = .automatic
        /// Who answers when the page stops responding: Chromium's dialog for
        /// Chrome-style browsers and the delegate for others, or the delegate
        /// for every browser.
        public var unresponsivePages: CefBrowser.UnresponsivePagePolicy = .automatic
        /// Who picks the certificate a site asks the user to identify with:
        /// Chromium's picker, or the delegate.
        public var clientCertificates: CefBrowser.ClientCertificatePolicy = .automatic

        public init() {}
    }
}
