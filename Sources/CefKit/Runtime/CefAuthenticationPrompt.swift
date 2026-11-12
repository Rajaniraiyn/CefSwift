import Foundation

/// Who asks for the user name and password that a site or proxy wants
/// (HTTP authentication: Basic, Digest, NTLM and the like).
///
/// Set it with ``CefConfiguration/authenticationPrompt``. It applies to
/// every browser of the app, Chrome and Alloy style alike, for the life of
/// the process.
public enum CefAuthenticationPrompt: Sendable, Equatable {
    /// The browser's delegate:
    /// ``CefBrowserDelegate/browser(_:credentialFor:)``, whose default
    /// shows a native sheet. A browser without a delegate gets the sheet
    /// too. The default.
    ///
    /// Requests that belong to no browser, such as a service worker's,
    /// are refused.
    case delegate

    /// Chromium's own sign-in dialog, which its password manager can fill.
    /// The delegate is not asked. In an Alloy-style browser the dialog is
    /// a window of its own, and the load first fails with
    /// `ERR_INVALID_AUTH_CREDENTIALS`.
    case chromium

    /// CEF's switch that sends every sign-in to
    /// `cef_request_handler_t.get_auth_credentials` instead of Chromium's
    /// dialog.
    static let delegateSwitch = "disable-chrome-login-prompt"
}
