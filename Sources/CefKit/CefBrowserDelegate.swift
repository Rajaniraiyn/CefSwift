import AppKit
import Foundation

/// What to do with a window/tab a page tries to open.
public enum CefPopupDecision: Sendable {
    /// Let CEF open the popup in its own window.
    case allow
    /// Suppress the popup entirely.
    case block
    /// Suppress the popup and navigate the requesting browser to its URL.
    case openInSameBrowser
}

/// All-optional, pluggable observer for ``CefBrowser`` events. Every method
/// has a no-op default implementation — adopt only what you need.
@MainActor
public protocol CefBrowserDelegate: AnyObject {
    /// The page title changed.
    func browser(_ b: CefBrowser, didChangeTitle title: String)
    /// The main-frame URL changed.
    func browser(_ b: CefBrowser, didChangeURL url: URL?)
    /// Loading started/stopped, or history availability changed.
    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    /// Estimated load progress changed (0.0 ... 1.0).
    func browser(_ b: CefBrowser, didChangeProgress progress: Double)
    /// The main frame failed to load.
    func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String)
    /// The page's favicon URL(s) changed.
    func browser(_ b: CefBrowser, didChangeFavicon urls: [URL])
    /// The page entered or exited HTML fullscreen.
    func browser(_ b: CefBrowser, didChangeFullscreen isFullscreen: Bool)
    /// The page wants to open a popup window. Defaults to ``CefPopupDecision/allow``.
    func browser(_ b: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision
    /// The browser finished closing; release any references to it.
    func browserDidClose(_ b: CefBrowser)
    /// A console message was logged by the page.
    func browser(_ b: CefBrowser, didReceiveConsoleMessage message: String, level: CefLogSeverity, source: String, line: Int)
}

// Default no-op implementations.
extension CefBrowserDelegate {
    public func browser(_ b: CefBrowser, didChangeTitle title: String) {}
    public func browser(_ b: CefBrowser, didChangeURL url: URL?) {}
    public func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    public func browser(_ b: CefBrowser, didChangeProgress progress: Double) {}
    public func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {}
    public func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {}
    public func browser(_ b: CefBrowser, didChangeFullscreen isFullscreen: Bool) {}
    public func browser(_ b: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision { .allow }
    public func browserDidClose(_ b: CefBrowser) {}
    public func browser(_ b: CefBrowser, didReceiveConsoleMessage message: String, level: CefLogSeverity, source: String, line: Int) {}
}

/// Per-browser creation options. Kept deliberately small in v1.
@MainActor
public struct CefBrowserOptions {
    /// Runtime style for this browser. Note: CEF forces Alloy style for
    /// browsers embedded via a parent NSView.
    public var runtimeStyle: CefRuntimeStyle = .default
    /// Background color shown before the page paints. Defaults to CEF's
    /// global default (opaque white).
    public var backgroundColor: NSColor?

    public init() {}
}
