import AppKit
import Foundation

/// Decisions and events for a ``CefBrowser``.
///
/// Browser *state* (URL, title, loading, progress, …) is observable directly
/// on ``CefBrowser``; the delegate covers what observation cannot: policy
/// decisions and one-shot events. Every method has a default, so adopt only
/// what you need.
///
/// Decisions Chromium can wait for are `async` — present your own UI, await
/// the user, and return. Decisions Chromium needs immediately (navigation,
/// window opening, key handling) are synchronous.
@MainActor
public protocol CefBrowserDelegate: AnyObject {

    // MARK: Lifecycle

    /// The underlying Chromium browser exists; commands now take effect.
    func browserDidCreate(_ browser: CefBrowser)
    /// The browser finished closing. Drop your references to it.
    func browserDidClose(_ browser: CefBrowser)
    /// A browser was created on this browser's behalf (a native popup, or
    /// DevTools). It inherits this delegate; assign another to change that.
    func browser(_ browser: CefBrowser, didOpen popup: CefBrowser)

    // MARK: Discarding

    /// The browser is about to be discarded (``CefBrowser/discard()`` or
    /// ``CefRuntime/memorySaver``): its page is still there, and this is the
    /// last moment to read from it.
    func browserWillDiscard(_ browser: CefBrowser)
    /// The browser's page was unloaded to free its memory. The browser
    /// keeps its URL, title and icon, and comes back when shown or used.
    func browserDidDiscard(_ browser: CefBrowser)
    /// A discarded browser started loading its page again.
    func browserDidRestore(_ browser: CefBrowser)

    // MARK: Loading

    /// The main frame finished loading with the given HTTP status.
    func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int)
    /// The main frame failed to load.
    func browser(_ browser: CefBrowser, didFailLoad error: CefLoadError)
    /// The page logged to the console.
    func browser(_ browser: CefBrowser, didLog message: CefConsoleMessage)
    /// The render process went away. Reloading recovers.
    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason)
    /// The page has not responded to input for 15 seconds: wait for it, or
    /// end its renderer. Not asked for Chrome-style browsers, which show
    /// Chromium's dialog, unless ``CefBrowserOptions/unresponsivePages`` is
    /// ``CefUnresponsivePagePolicy/delegate``. The question is withdrawn,
    /// and the task cancelled, when the page responds again. The default
    /// asks with ``CefUnresponsivePagePresenter``.
    func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision

    // MARK: Synchronous policy

    /// Allow or cancel a main-frame navigation.
    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision
    /// Route a `target=_blank` / `window.open` / ⌘-click request. The default
    /// is ``CefWindowOpenAction/default(for:)``.
    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction
    /// A key event, before (`isBeforePage`) or after the page saw it. Return
    /// `true` to consume it.
    func browser(_ browser: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool
    /// Customize the context menu before it is shown.
    func browser(_ browser: CefBrowser, configureContextMenu menu: CefMenuModel, for target: CefContextMenuTarget)
    /// A context-menu command was chosen. Return `true` if you handled it.
    func browser(_ browser: CefBrowser, handleContextMenuCommand commandID: Int, for target: CefContextMenuTarget) -> Bool
    /// Chrome is about to run one of its commands (see ``CefChromeCommand``)
    /// — new tab, find, print, zoom, … Return `true` to handle it yourself.
    /// Chrome-style browsers only.
    func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool

    // MARK: Asynchronous policy

    /// Present `alert` / `confirm` / `prompt`. The default shows a native sheet.
    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse
    /// Confirm leaving a page with a `beforeunload` handler. Return `true` to
    /// leave. The default shows a native sheet.
    func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool
    /// Resolve a permission request. The default denies.
    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision
    /// Supply credentials for HTTP/proxy authentication, or `nil` to cancel.
    /// Asked again, with the same challenge, when the server refuses the
    /// credentials. Not asked when ``CefConfiguration/authenticationPrompt``
    /// is ``CefAuthenticationPrompt/chromium``.
    /// The default shows a native sign-in sheet.
    func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential?
    /// Return `true` to proceed despite a certificate error. The default
    /// cancels the load.
    func browser(_ browser: CefBrowser, shouldProceedDespite error: CefCertificateError) async -> Bool
    /// Pick the certificate to identify the user with when a site asks for
    /// one, or `nil` to continue without. Asked only when
    /// ``CefBrowserOptions/clientCertificates`` is
    /// ``CefClientCertificatePolicy/delegate``; otherwise Chromium shows
    /// its own picker. The default asks with
    /// ``CefClientCertificatePresenter``.
    func browser(_ browser: CefBrowser, selectClientCertificateFor request: CefClientCertificateRequest) async -> CefCertificate?
    /// Decide where a download goes. The default saves to `~/Downloads`.
    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision
    /// Answer a page's request to register or use a passkey, for browsers
    /// whose ``CefBrowserOptions/passkeys`` is ``CefPasskeyMode/app(_:)``.
    /// The default asks the user with ``CefPasskeyPresenter``.
    ///
    /// The page stays stopped at its `navigator.credentials` call until you
    /// answer, as it does for `alert()`; JavaScript you evaluate in it
    /// meanwhile waits too. When the page navigates away or the browser
    /// closes first, the call's task is cancelled and its answer ignored.
    func browser(_ browser: CefBrowser, decidePasskeyRequest request: CefPasskeyRequest) async -> CefPasskeyDecision
    /// The passkey store failed while a WebAuthn request was answered. A
    /// failed availability check or read refuses the page's call; a failed
    /// save happens after the page has its answer and carries the passkey
    /// that was not saved. The default logs the error.
    func browser(_ browser: CefBrowser, passkeyStoreDidFail error: CefPasskeyStoreError)

    // MARK: Downloads

    /// A download's progress or state changed. ``CefBrowser/downloads``
    /// carries the same information observably.
    func browser(_ browser: CefBrowser, downloadDidUpdate download: CefDownload)
}

extension CefBrowserDelegate {
    public func browserDidCreate(_ browser: CefBrowser) {}
    public func browserDidClose(_ browser: CefBrowser) {}
    public func browser(_ browser: CefBrowser, didOpen popup: CefBrowser) {}

    public func browserWillDiscard(_ browser: CefBrowser) {}
    public func browserDidDiscard(_ browser: CefBrowser) {}
    public func browserDidRestore(_ browser: CefBrowser) {}

    public func browser(_ browser: CefBrowser, didFinishLoadWithStatus httpStatus: Int) {}
    public func browser(_ browser: CefBrowser, didFailLoad error: CefLoadError) {}
    public func browser(_ browser: CefBrowser, didLog message: CefConsoleMessage) {}
    public func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {}
    public func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision {
        await CefUnresponsivePagePresenter.present(for: browser, in: browser.hostWindow)
    }

    public func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        .allow
    }
    public func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        .default(for: request)
    }
    public func browser(_ browser: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool { false }
    public func browser(_ browser: CefBrowser, configureContextMenu menu: CefMenuModel, for target: CefContextMenuTarget) {}
    public func browser(_ browser: CefBrowser, handleContextMenuCommand commandID: Int, for target: CefContextMenuTarget) -> Bool {
        false
    }
    public func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        false
    }

    public func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        await CefDialogPresenter.present(dialog, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool {
        await CefDialogPresenter.confirmLeaving(isReload: isReload, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        .deny
    }
    public func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential? {
        await CefDialogPresenter.requestCredential(for: challenge, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, shouldProceedDespite error: CefCertificateError) async -> Bool { false }
    public func browser(_ browser: CefBrowser, selectClientCertificateFor request: CefClientCertificateRequest) async -> CefCertificate? {
        await CefClientCertificatePresenter.present(request, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision {
        .allow(destination: nil)
    }

    public func browser(_ browser: CefBrowser, decidePasskeyRequest request: CefPasskeyRequest) async -> CefPasskeyDecision {
        await CefPasskeyPresenter.present(request, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, passkeyStoreDidFail error: CefPasskeyStoreError) {
        CefLog.error("passkeys: \(error)")
    }

    public func browser(_ browser: CefBrowser, downloadDidUpdate download: CefDownload) {}
}

/// Stands in when a browser has no delegate, so every decision still gets
/// the protocol's default behavior.
@MainActor
final class CefDefaultBrowserDelegate: CefBrowserDelegate {
    static let shared = CefDefaultBrowserDelegate()
}

// MARK: - Event payloads

/// A failed main-frame load.
public struct CefLoadError: Error, Sendable, Equatable {
    /// Chromium's `net::Error` code (negative), e.g. `-105` for
    /// `ERR_NAME_NOT_RESOLVED`.
    public var code: Int
    /// Chromium's description of the error.
    public var message: String
    /// The URL that failed.
    public var url: URL?

    /// Whether the load was aborted (`ERR_ABORTED`) — a navigation replaced
    /// or cancelled it. Usually not worth showing to the user.
    public var isCancellation: Bool { code == -3 }
}

/// One console message from a page.
public struct CefConsoleMessage: Sendable, Equatable {
    public var level: CefLogSeverity
    public var text: String
    public var source: String
    public var line: Int
}

/// A main-frame navigation awaiting a policy decision.
public struct CefNavigationAction: Sendable, Equatable {
    public var url: URL?
    public var isRedirect: Bool
    /// Whether a user gesture (click, key) triggered the navigation.
    public var hasUserGesture: Bool
}

/// A certificate error for a main-frame load.
public struct CefCertificateError: Sendable, Equatable {
    /// Chromium's `net::Error` code, e.g. `-202` for
    /// `ERR_CERT_AUTHORITY_INVALID`.
    public var code: Int
    public var url: URL?
    /// What Chromium found wrong with the certificate.
    public var status: CefCertificateStatus = []
    /// The certificate the server presented.
    public var certificate: CefCertificate?
}

/// Credentials answering a ``CefAuthenticationChallenge``.
public struct CefCredential: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// The user's answer to a JavaScript dialog.
public enum CefJavaScriptDialogResponse: Sendable, Equatable {
    /// OK was chosen; `text` is the prompt field's contents.
    case accept(text: String = "")
    /// Cancel was chosen (or the dialog was dismissed).
    case dismiss
}
