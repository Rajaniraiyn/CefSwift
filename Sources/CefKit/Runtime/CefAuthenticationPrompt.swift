import Foundation

extension CefRuntime {
    /// Who asks for the user name and password that a site or proxy wants
    /// (HTTP authentication: Basic, Digest, NTLM and the like).
    ///
    /// Set it with ``CefRuntime/Configuration/authenticationPrompt``. It applies to
    /// every page of the app, Chrome and Alloy style alike, for the life of
    /// the process.
    public enum AuthenticationPromptPolicy: Sendable, Equatable {
        /// The page's delegate:
        /// ``CefPageDelegate/page(_:credentialFor:)``, whose default
        /// shows a native sheet. A page without a delegate gets the sheet
        /// too. The default.
        ///
        /// Requests that belong to no page, such as a service worker's,
        /// are refused.
        case delegate

        /// Chromium's own sign-in dialog, which its password manager can fill.
        /// The delegate is not asked. In an Alloy-style page the dialog is
        /// a window of its own, and the load first fails with
        /// `ERR_INVALID_AUTH_CREDENTIALS`.
        case chromium

        /// CEF's switch that sends every sign-in to
        /// `cef_request_handler_t.get_auth_credentials` instead of Chromium's
        /// dialog.
        static let delegateSwitch = "disable-chrome-login-prompt"
    }
}
