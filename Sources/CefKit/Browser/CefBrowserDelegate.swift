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

    /// The browser is about to be discarded (``CefBrowser/discard()``): its
    /// page is still there, and this is the last moment to read from it.
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
    /// Chromium's dialog, unless ``CefBrowser/Configuration/unresponsivePages`` is
    /// ``CefBrowser/UnresponsivePagePolicy/delegate``. The question is withdrawn,
    /// and the task cancelled, when the page responds again. The default
    /// asks with ``CefUnresponsivePagePresenter``.
    func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision

    // MARK: Synchronous policy

    /// Allow or cancel a navigation of the main frame or of a subframe
    /// (``CefNavigationAction/frame``), redirects included. Cancelling a
    /// subframe's leaves the rest of the page as it is.
    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision
    /// Route a `target=_blank` / `window.open` / ⌘-click request. The default
    /// is ``CefWindowOpenDecision/default(for:)``.
    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision
    /// A key event, before (`isBeforePage`) or after the page saw it. Return
    /// `true` to consume it.
    func browser(_ browser: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool
    /// Chrome is about to run one of its commands (see ``CefChromeCommand``)
    /// — new tab, find, print, zoom, … Return `true` to handle it yourself.
    /// Chrome-style browsers only.
    func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool

    // MARK: Asynchronous policy

    /// Show a context menu, already shaped by
    /// ``CefBrowser/Configuration/contextMenu``, and return the item the
    /// user chose, or `nil` for none. CefKit then runs it: your item's
    /// action, or Chromium's command. The default shows a native menu at
    /// the click (``CefContextMenuPresenter``).
    func browser(_ browser: CefBrowser, runContextMenu menu: CefContextMenu, for target: CefContextMenuTarget) async -> CefContextMenu.Item?
    /// Present `alert` / `confirm` / `prompt`. The default shows a native sheet.
    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse
    /// Confirm leaving a page with a `beforeunload` handler. Return `true` to
    /// leave. The default shows a native sheet.
    func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool
    /// Choose files for a page's file chooser. Return the chosen files, or
    /// `nil` to cancel. The default shows an `NSOpenPanel` or `NSSavePanel`
    /// (``CefFileDialogPresenter``) as a sheet.
    func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]?
    /// Decide whether another app opens a URL of a scheme Chromium does
    /// not load itself (`mailto:`, `zoommtg:`), which a page navigated to
    /// or a link opened. The default asks with
    /// ``CefExternalProtocolPresenter``, or denies when no app handles the
    /// scheme. Chromium never opens another app itself; on
    /// ``CefExternalProtocolDecision/allow`` CefKit opens the URL with
    /// `NSWorkspace`. Cancelled when the page navigates away.
    func browser(_ browser: CefBrowser, decideExternalProtocolFor request: CefExternalProtocolRequest) async
        -> CefExternalProtocolDecision
    /// Resolve a permission request the profile's site settings do not
    /// answer. The default hands it to the profile:
    /// ``CefProfileDelegate/profile(_:decidePermissionFor:in:)``, which
    /// denies unless the app set a profile delegate. Implement it to decide
    /// for this page instead of its profile.
    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision
    /// Supply credentials for HTTP/proxy authentication, or `nil` to cancel.
    /// Asked again, with the same challenge, when the server refuses the
    /// credentials. Not asked when ``CefRuntime/Configuration/authenticationPrompt``
    /// is ``CefRuntime/AuthenticationPromptPolicy/chromium``.
    /// The default shows a native sign-in sheet.
    func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential?
    /// Return `true` to proceed despite a certificate error. The default
    /// cancels the load.
    func browser(_ browser: CefBrowser, shouldProceedDespite error: CefCertificateError) async -> Bool
    /// Pick the certificate to identify the user with when a site asks for
    /// one, or `nil` to continue without. Asked only when
    /// ``CefBrowser/Configuration/clientCertificates`` is
    /// ``CefBrowser/ClientCertificatePolicy/delegate``; otherwise Chromium shows
    /// its own picker. The default asks with
    /// ``CefClientCertificatePresenter``.
    func browser(_ browser: CefBrowser, selectClientCertificateFor request: CefClientCertificateRequest) async -> CefCertificate?
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
    public func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
        .default(for: request)
    }
    public func browser(_ browser: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool { false }
    public func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        false
    }

    public func browser(_ browser: CefBrowser, runContextMenu menu: CefContextMenu, for target: CefContextMenuTarget) async -> CefContextMenu.Item? {
        await CefContextMenuPresenter.present(menu, for: target, in: browser)
    }
    public func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        await CefDialogPresenter.present(dialog, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool {
        await CefDialogPresenter.confirmLeaving(isReload: isReload, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]? {
        await CefFileDialogPresenter.present(dialog, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, decideExternalProtocolFor request: CefExternalProtocolRequest) async
        -> CefExternalProtocolDecision
    {
        await CefExternalProtocolPresenter.present(request, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        let profile = browser.profile
        return await profile.effectiveDelegate.profile(profile, decidePermissionFor: request, in: browser)
    }
    public func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential? {
        await CefDialogPresenter.requestCredential(for: challenge, in: browser.hostWindow)
    }
    public func browser(_ browser: CefBrowser, shouldProceedDespite error: CefCertificateError) async -> Bool { false }
    public func browser(_ browser: CefBrowser, selectClientCertificateFor request: CefClientCertificateRequest) async -> CefCertificate? {
        await CefClientCertificatePresenter.present(request, in: browser.hostWindow)
    }

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

    /// Creates a value of your own, for previews and tests.
    public init(code: Int, message: String, url: URL? = nil) {
        self.code = code
        self.message = message
        self.url = url
    }

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

    /// Creates a value of your own, for previews and tests.
    public init(level: CefLogSeverity, text: String, source: String = "", line: Int = 0) {
        self.level = level
        self.text = text
        self.source = source
        self.line = line
    }
}

/// A navigation awaiting a policy decision: of the page's main frame or
/// of one of its subframes.
public struct CefNavigationAction: Sendable, Equatable {
    /// Where the frame navigates to.
    public var url: URL?
    /// The frame that navigates, as it is before the navigation: its
    /// ``CefFrame/url`` is still the document it leaves.
    public var frame: CefFrame
    /// Whether this is a redirect of a navigation already allowed.
    public var isRedirect: Bool
    /// Whether a user gesture (click, key) triggered the navigation.
    public var hasUserGesture: Bool
    /// How the navigation started: a link, a form submission
    /// (``CefNavigationTransition/Source/formSubmit``), a reload, going back
    /// or forward, an address given to ``CefBrowser/load(_:)``, a subframe
    /// loading by itself.
    public var transition: CefNavigationTransition

    /// Whether the main frame navigates.
    public var isMainFrame: Bool { frame.isMain }

    /// Creates a value of your own, for previews and tests.
    public init(
        url: URL?, frame: CefFrame = CefFrame(id: "", url: nil, isMain: true), isRedirect: Bool = false,
        hasUserGesture: Bool = false, transition: CefNavigationTransition = CefNavigationTransition(source: .link)
    ) {
        self.url = url
        self.frame = frame
        self.isRedirect = isRedirect
        self.hasUserGesture = hasUserGesture
        self.transition = transition
    }
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

    /// Creates a value of your own, for previews and tests.
    public init(code: Int, url: URL?, status: CefCertificateStatus = [], certificate: CefCertificate? = nil) {
        self.code = code
        self.url = url
        self.status = status
        self.certificate = certificate
    }
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
