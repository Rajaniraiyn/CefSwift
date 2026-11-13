import AppKit
import CCef
import Foundation
import Observation
import CefBase

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
    /// Whether horizontal swipes navigate back and forward, as the system's
    /// "Swipe between pages" setting allows: two-finger scrolls that start
    /// sideways, and the dedicated navigation swipe. Chrome-style browsers
    /// (``CefBrowserWindow``) use Chrome's own swipe handling; views use
    /// CefSwift's. While a swipe is in progress,
    /// ``CefBrowser/navigationGestureProgress`` follows it.
    public var allowsBackForwardNavigationGestures = false
    /// How a swipe in progress is shown when
    /// ``allowsBackForwardNavigationGestures`` is on.
    public var navigationGestureIndicator = CefNavigationGestureIndicator.automatic
    /// (Offscreen only) Forward raw trackpad touches to Chromium instead of
    /// translating gestures natively.
    public var forwardsRawTouchEvents = false
    /// Who answers the pages' WebAuthn requests (passkeys and security
    /// keys): Chromium (the default), the app from a ``CefPasskeyStore``,
    /// or nobody. Popups use their opener's mode.
    public var passkeys: CefPasskeyMode = .chromium
    /// (Offscreen only) When Chromium builds the page's accessibility tree,
    /// which VoiceOver and other assistive apps read. Building it costs
    /// time and memory, so by default it starts on first demand.
    public var offscreenAccessibility: CefOffscreenAccessibility = .automatic
    /// Who answers when the page stops responding: Chromium's dialog for
    /// Chrome-style browsers and the delegate for others, or the delegate
    /// for every browser.
    public var unresponsivePages: CefUnresponsivePagePolicy = .automatic
    /// Who picks the certificate a site asks the user to identify with:
    /// Chromium's picker, or the delegate.
    public var clientCertificates: CefClientCertificatePolicy = .automatic

    public init() {}
}
