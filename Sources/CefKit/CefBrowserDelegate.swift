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
    /// A download is about to begin; decide what happens to it. The default
    /// saves to `~/Downloads/<suggestedName>`.
    func browser(_ b: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String) -> CefDownloadDecision
    /// A download's progress/state changed (fires repeatedly, including the
    /// final update where `isComplete` or `isCanceled` is set).
    func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload)

    // MARK: JavaScript dialogs

    /// The page wants to show a JavaScript dialog (`alert`/`confirm`/`prompt`).
    /// Resolve it via `callback`. Return `true` if you will present it
    /// yourself; return `false` to use CefSwift's native `NSAlert`.
    func browser(_ b: CefBrowser, runJSDialog dialog: CefJSDialog, callback: CefJSDialogCallback) -> Bool

    /// The page is navigating away and has a `beforeunload` handler. Resolve
    /// `callback` (`success: true` = leave). Return `true` to present your own
    /// dialog; `false` for the native one.
    func browser(_ b: CefBrowser, runBeforeUnloadDialog message: String, isReload: Bool, callback: CefJSDialogCallback) -> Bool

    // MARK: Context menu

    /// A context menu is about to appear. Mutate `menu` (clear, add custom
    /// items with command IDs in
    /// ``CefMenuModel/userCommandIDFirst``...``CefMenuModel/userCommandIDLast``,
    /// remove items) before it is shown. `params` describes the click target.
    func browser(_ b: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams)

    /// A context-menu command was selected. Return `true` if you handled a
    /// custom command, `false` to let CEF run its built-in command.
    func browser(_ b: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams) -> Bool

    /// The context menu was dismissed (canceled or a command was chosen).
    func browserContextMenuDidClose(_ b: CefBrowser)

    // MARK: Permissions

    /// The page requested one or more permissions. Return how to resolve it.
    /// The default is ``CefPermissionDecision/deny`` (apps that want the
    /// system prompt should override and return `.allow`).
    func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest) -> CefPermissionDecision

    // MARK: Navigation / requests

    /// Decide whether to allow a navigation. Return ``CefNavigationDecision/cancel``
    /// to block it (e.g. to route external schemes yourself). Defaults to
    /// ``CefNavigationDecision/allow``.
    func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision

    /// The page tried to open `url` in a new tab/window (middle-click,
    /// ctrl-click, etc.). Returns whether you handled it; returning `true`
    /// cancels CEF's default new-window behavior.
    func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool

    /// A certificate error occurred for `url`. Return `true` to override and
    /// continue loading; `false` (default) to cancel.
    func browser(_ b: CefBrowser, didEncounterCertificateError url: URL?, errorCode: Int) -> Bool

    /// The render process for this browser terminated unexpectedly — a crash
    /// recovery signal. Consider reloading.
    func browser(_ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int)

    /// The server requested HTTP authentication. Resolve `callback` with
    /// credentials or cancel it. Return `true` to handle it; `false` (default)
    /// cancels the request immediately.
    func browser(_ b: CefBrowser, didReceiveAuthChallenge challenge: CefAuthChallenge, callback: CefAuthCallback) -> Bool

    // MARK: Keyboard / focus

    /// A key event before it reaches the page — your chance to intercept
    /// app-level shortcuts. Return `true` if you handled it (the page won't
    /// see it). Defaults to `false`.
    func browser(_ b: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool

    /// The browser is about to lose focus to the next/previous component.
    func browser(_ b: CefBrowser, willTakeFocusNext next: Bool)

    /// The browser is requesting focus. Return `true` to cancel (deny) it;
    /// `false` (default) to allow.
    func browserShouldCancelSetFocus(_ b: CefBrowser) -> Bool

    /// The browser received focus.
    func browserDidGainFocus(_ b: CefBrowser)

    // MARK: Display extras

    /// The status text changed (e.g. the link under the cursor).
    func browser(_ b: CefBrowser, didChangeStatusMessage message: String)

    /// The browser wants to show a tooltip. Return `true` to suppress CEF's
    /// own tooltip and present your own; `false` (default) for native behavior.
    func browser(_ b: CefBrowser, showTooltip text: String) -> Bool

    /// The mouse cursor changed. Informational for windowed browsers (CEF
    /// applies it); OSR hosts can drive `NSCursor` from this.
    func browser(_ b: CefBrowser, didChangeCursor cursor: CefCursorType)
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
    public func browser(_ b: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String) -> CefDownloadDecision {
        .allow(destination: nil)
    }
    public func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload) {}

    public func browser(_ b: CefBrowser, runJSDialog dialog: CefJSDialog, callback: CefJSDialogCallback) -> Bool { false }
    public func browser(_ b: CefBrowser, runBeforeUnloadDialog message: String, isReload: Bool, callback: CefJSDialogCallback) -> Bool { false }

    public func browser(_ b: CefBrowser, configureContextMenu menu: CefMenuModel, params: CefContextMenuParams) {}
    public func browser(_ b: CefBrowser, contextMenuCommand commandID: Int, params: CefContextMenuParams) -> Bool { false }
    public func browserContextMenuDidClose(_ b: CefBrowser) {}

    public func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest) -> CefPermissionDecision { .deny }

    public func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision { .allow }
    public func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool { false }
    public func browser(_ b: CefBrowser, didEncounterCertificateError url: URL?, errorCode: Int) -> Bool { false }
    public func browser(_ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int) {}
    public func browser(_ b: CefBrowser, didReceiveAuthChallenge challenge: CefAuthChallenge, callback: CefAuthCallback) -> Bool { false }

    public func browser(_ b: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool { false }
    public func browser(_ b: CefBrowser, willTakeFocusNext next: Bool) {}
    public func browserShouldCancelSetFocus(_ b: CefBrowser) -> Bool { false }
    public func browserDidGainFocus(_ b: CefBrowser) {}

    public func browser(_ b: CefBrowser, didChangeStatusMessage message: String) {}
    public func browser(_ b: CefBrowser, showTooltip text: String) -> Bool { false }
    public func browser(_ b: CefBrowser, didChangeCursor cursor: CefCursorType) {}
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

    /// The browsing profile (request context) this browser belongs to. When
    /// `nil` the global/default context is used. Use ``CefProfile/incognito()``
    /// or ``CefProfile/persistent(name:)`` for isolated cookies/storage.
    public var profile: CefProfile?

    public init() {}
}
