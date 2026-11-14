import CefKit

/// Answers the WebAuthn requests (passkeys and security keys) of the
/// browsers it is attached to, instead of Chromium.
///
/// Without a controller, Chromium answers with its own dialog and
/// authenticators: security keys, phones, and iCloud Keychain when the app
/// has the entitlement for it (see ``CefAppCapabilities/webAuthnAuthenticators``).
/// Attach a controller to answer from the app's own store, or to refuse
/// every request:
///
/// ```swift
/// let passkeys = CefPasskeyController(policy: .app(CefKeychainPasskeyStore()))
/// var configuration = CefBrowser.Configuration()
/// configuration.attachments.append(passkeys)
/// let browser = CefBrowser(url: URL(string: "https://example.com")!, configuration: configuration)
/// ```
///
/// One controller can serve many browsers. Its ``delegate`` decides each
/// request; without one, ``CefPasskeyPresenter`` asks the user.
///
/// ## How it works, and what a page can see
///
/// The controller drives the DevTools Protocol of each browser
/// (``CefBrowser/devTools``): `WebAuthn.enable` puts the pages in a virtual
/// authenticator environment, so Chromium's dialog, security keys and
/// iCloud Keychain are out of the picture, and the `Debugger` domain stops
/// each document at its `navigator.credentials.create()` and `.get()`
/// calls while the delegate decides. Nothing in the page is changed, but
/// a page can observe that a debugger is attached: with the `Runtime` and
/// `Debugger` domains enabled, every `console` call serializes its
/// arguments, each document is paused briefly as it starts, and the
/// page's own `debugger` statements pause it until the controller resumes
/// it, all of which a page can time. Sites that look for automation may
/// treat such a browser differently; leave passkeys to Chromium (no
/// controller) where that matters.
///
/// The controller takes each document's calls over before its first
/// script runs (``preparesBeforeFirstDocument``). So a page's popups, new
/// tabs and windows that the browser delegate lets Chromium open
/// (``CefWindowOpenDecision/allowNativePopup``) open instead in a browser
/// CefKit creates with the opener's configuration, which the page cannot
/// script: `window.open` returns `null`, the popup has no `window.opener`,
/// and a popup without a URL is refused. Browsers Chromium opens without a
/// page asking, such as a tab from Chrome's own UI, have the default
/// configuration and so no controller.
@MainActor
public final class CefPasskeyController: CefBrowserAttachment {
    /// Who answers the requests.
    public enum Policy {
        /// The app, from this store, through the ``CefPasskeyController/delegate``.
        case app(any CefPasskeyStore)
        /// Every request is refused.
        case disabled
    }

    /// Who answers the requests of the browsers the controller serves.
    public let policy: Policy

    /// Decides each request, for ``Policy/app(_:)``; held weakly. When
    /// `nil`, ``CefPasskeyPresenter`` asks the user, and store failures are
    /// logged.
    public weak var delegate: (any CefPasskeyDelegate)?

    /// - Parameters:
    ///   - policy: Who answers the requests.
    ///   - delegate: The ``delegate``, held weakly. Keep your own strong
    ///     reference to it.
    public init(policy: Policy, delegate: (any CefPasskeyDelegate)? = nil) {
        self.policy = policy
        self.delegate = delegate
    }

    /// Each browser's DevTools session state.
    private var sessions: [ObjectIdentifier: CefPasskeySession] = [:]

    // MARK: CefBrowserAttachment

    /// `true`: no page may call `navigator.credentials` before the
    /// controller is in place.
    public var preparesBeforeFirstDocument: Bool { true }

    public func browserDidCreate(_ browser: CefBrowser) async {
        await start(browser)
    }

    /// A browser discarded by closing it starts again here, since its
    /// DevTools state went with the old Chromium browser.
    public func browserDidRestore(_ browser: CefBrowser) async {
        await start(browser)
    }

    public func browserDidClose(_ browser: CefBrowser) {
        sessions.removeValue(forKey: ObjectIdentifier(browser))?.stop()
    }

    private func start(_ browser: CefBrowser) async {
        guard browser.state == .live else { return }
        let key = ObjectIdentifier(browser)
        sessions[key]?.stop()
        let session = CefPasskeySession(browser: browser, controller: self)
        sessions[key] = session
        do {
            try await session.start()
        } catch {
            CefLog.error("passkeys: setup failed for browser \(browser.identifier): \(error)")
        }
    }
}

/// Decides the WebAuthn requests a ``CefPasskeyController`` answers.
///
/// The page stays stopped at its `navigator.credentials` call until you
/// answer, as it does for `alert()`; JavaScript you evaluate in it
/// meanwhile waits too. When the page navigates away or the browser closes
/// first, the call's task is cancelled and its answer ignored.
@MainActor
public protocol CefPasskeyDelegate: AnyObject {
    /// Answer a page's request to register or use a passkey. The default
    /// asks the user with ``CefPasskeyPresenter``.
    func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision
    /// The passkey store failed while a request was answered. A failed
    /// availability check or read refuses the page's call; a failed save
    /// happens after the page has its answer and carries the passkey that
    /// was not saved. The default logs the error.
    func browser(_ browser: CefBrowser, passkeyStoreDidFail error: CefPasskeyStoreError)
}

extension CefPasskeyDelegate {
    public func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
        await CefPasskeyPresenter.present(request, in: browser.hostWindow)
    }

    public func browser(_ browser: CefBrowser, passkeyStoreDidFail error: CefPasskeyStoreError) {
        CefLog.error("passkeys: \(error)")
    }
}

/// Stands in when a controller has no delegate.
@MainActor
final class CefDefaultPasskeyDelegate: CefPasskeyDelegate {
    static let shared = CefDefaultPasskeyDelegate()
}
