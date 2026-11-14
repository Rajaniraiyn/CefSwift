import AppKit
import CefKit
import LocalAuthentication

/// The native passkey sheet behind the default
/// ``CefPasskeyDelegate/browser(_:decidePasskeyFor:)``.
///
/// It names the site, asks the user to confirm, and verifies the user with
/// a ``CefUserVerifier`` before answering: by default Touch ID or the
/// account password (`LAContext`, policy `deviceOwnerAuthentication`).
/// Call it from your own delegate to keep the stock UI for some requests.
@MainActor
public enum CefPasskeyPresenter {
    /// Asks the user about `request` and returns the answer.
    ///
    /// A request made without a user gesture, as conditional mediation is,
    /// is left unanswered (``CefPasskeyDecision/ignore``) without showing
    /// anything, so a sign-in page that offers passkeys as it loads does
    /// not raise a sheet.
    ///
    /// The request is answered only when `verifier` reports
    /// ``CefUserVerification/verified``. A Mac that cannot verify its user
    /// (``CefUserVerification/unavailable(_:)``) gets a refusal; pass a
    /// verifier of your own to decide otherwise.
    ///
    /// Cancelling the calling task dismisses the sheet, or ends the user
    /// verification, and returns ``CefPasskeyDecision/deny``. The
    /// controller cancels the delegate's call when the page navigates or
    /// the browser closes.
    public static func present(
        _ request: CefPasskeyRequest, in window: NSWindow?, verifier: CefUserVerifier = .deviceOwner
    ) async -> CefPasskeyDecision {
        guard request.hasUserGesture else { return .ignore }
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil)
        var picker: NSPopUpButton?

        let host = request.host
        let proceed = String(localized: "Continue", bundle: .cefPasskeys, comment: "Passkey sheets: the button that goes on to verify the user.")
        switch request.kind {
        case .registration:
            alert.messageText = String(localized: "Save a passkey for “\(host)”?", bundle: .cefPasskeys,
                                       comment: "Title of the sheet that asks before creating a passkey: %@ is the website's host, such as example.com.")
            alert.informativeText = String(localized: "A passkey lets you sign in to this website without a password. It is saved on this Mac.",
                                           bundle: .cefPasskeys, comment: "Message of the sheet that asks before creating a passkey.")
            alert.addButton(withTitle: proceed)
        case .assertion where request.passkeys.isEmpty:
            alert.messageText = String(localized: "No passkeys for “\(host)”", bundle: .cefPasskeys,
                                       comment: "Title of the sheet shown when a website asks for a passkey and none is saved for it: %@ is the website's host.")
            alert.informativeText = String(localized: "You have no saved passkeys for this website.", bundle: .cefPasskeys,
                                           comment: "Message of the sheet shown when no passkey is saved for the website.")
            // NSAlert's own OK button, which AppKit localizes.
            _ = await run(alert, in: window)
            return .deny
        case .assertion:
            alert.messageText = String(localized: "Sign in to “\(host)” with your passkey?", bundle: .cefPasskeys,
                                       comment: "Title of the sheet that asks before signing in with a passkey: %@ is the website's host.")
            if request.passkeys.count == 1 {
                alert.informativeText = request.passkeys[0].userName
            } else {
                alert.informativeText = String(localized: "Choose an account.", bundle: .cefPasskeys,
                                               comment: "Passkey sign-in sheet, when several accounts have a passkey: asks to pick one from the menu below.")
                let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
                popUp.addItems(withTitles: request.passkeys.map(\.userName))
                alert.accessoryView = popUp
                picker = popUp
            }
            alert.addButton(withTitle: proceed)
        }
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .cefPasskeys, comment: "Passkey sheets: the button that refuses the website's request."))

        guard await run(alert, in: window) == .alertFirstButtonReturn, !Task.isCancelled else { return .deny }
        let verification = await verifier.verify(reason(for: request))
        guard !Task.isCancelled else { return .deny }
        return decision(for: request, choosing: picker?.indexOfSelectedItem ?? 0, after: verification)
    }

    /// Verifies the user with Touch ID, a paired Apple Watch, or the
    /// account password, as ``CefUserVerifier/deviceOwner`` does.
    public static func verifyUser(reason: String) async -> CefUserVerification {
        await verifyUser(reason: reason, with: LAContext())
    }

    static func verifyUser(reason: String, with context: sending any CefLocalAuthenticationContext) async -> CefUserVerification {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription
                ?? String(localized: "User verification is not available.", bundle: .cefPasskeys,
                          comment: "Why a passkey cannot be used, when macOS gives no reason of its own."))
        }
        // Cancelling the task invalidates the context, which ends the
        // system prompt with an error.
        let evaluating = AuthenticationContextBox(context: context)
        do {
            return try await withTaskCancellationHandler {
                try await evaluate(evaluating, reason: reason) ? .verified : .failed
            } onCancel: {
                evaluating.context.invalidate()
            }
        } catch {
            return .failed
        }
    }

    /// Off the main actor, where the context's evaluation runs.
    private nonisolated static func evaluate(_ box: AuthenticationContextBox, reason: String) async throws -> Bool {
        try await box.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    /// The answer once the user confirmed and verification finished.
    static func decision(
        for request: CefPasskeyRequest, choosing index: Int, after verification: CefUserVerification
    ) -> CefPasskeyDecision {
        guard verification == .verified else { return .deny }
        switch request.kind {
        case .registration:
            return .createPasskey
        case .assertion:
            guard request.passkeys.indices.contains(index) else { return .deny }
            return .signIn(with: request.passkeys[index])
        }
    }

    static func reason(for request: CefPasskeyRequest) -> String {
        let host = request.host
        return request.kind == .registration
            ? String(localized: "save a passkey for \(host)", bundle: .cefPasskeys,
                     comment: "Reason in the Touch ID or password prompt before creating a passkey. It completes the sentence “<App> wants to …”: %@ is the website's host.")
            : String(localized: "sign in to \(host)", bundle: .cefPasskeys,
                     comment: "Reason in the Touch ID or password prompt before signing in with a passkey. It completes the sentence “<App> wants to …”: %@ is the website's host.")
    }

    /// Shows `alert` until the user answers or the task is cancelled, which
    /// dismisses it.
    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        await CefDialogPresenter.run(alert, in: window)
    }
}

/// The outcome of verifying the user before a passkey is created or used.
public enum CefUserVerification: Sendable, Equatable {
    /// The user proved who they are.
    case verified
    /// The user cancelled, or verification failed.
    case failed
    /// The Mac cannot verify its user, for example because it has no
    /// password, Touch ID or paired Apple Watch, or because a policy
    /// restricts it. The text says why.
    case unavailable(String)
}

/// Verifies the user for ``CefPasskeyPresenter``.
///
/// ``deviceOwner`` asks for Touch ID, a paired Apple Watch, or the account
/// password. Supply your own to verify another way, to treat a Mac without
/// verification differently, or to answer without UI in tests:
///
/// ```swift
/// let verifier = CefUserVerifier { reason in
///     let result = await CefUserVerifier.deviceOwner.verify(reason)
///     if case .unavailable = result { return await askForAppPIN(reason) }
///     return result
/// }
/// ```
public struct CefUserVerifier: Sendable {
    /// Verifies the user. `reason` completes the sentence “… wants to” in
    /// the system prompt, as `LAContext` uses it.
    public var verify: @MainActor @Sendable (_ reason: String) async -> CefUserVerification

    public init(_ verify: @escaping @MainActor @Sendable (_ reason: String) async -> CefUserVerification) {
        self.verify = verify
    }

    /// Touch ID, a paired Apple Watch, or the account password, through
    /// `LAContext` with the `deviceOwnerAuthentication` policy.
    public static let deviceOwner = CefUserVerifier { reason in
        await CefPasskeyPresenter.verifyUser(reason: reason)
    }
}

/// The part of `LAContext` user verification needs, so it can be tested
/// without a system prompt.
/// Carries a context to its evaluation and to the cancellation handler.
/// `LAContext` may be used from any thread, and a context is evaluated
/// once and at most invalidated meanwhile, which is what `@unchecked`
/// vouches for.
private struct AuthenticationContextBox: @unchecked Sendable {
    let context: any CefLocalAuthenticationContext
}

protocol CefLocalAuthenticationContext {
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool
    /// Ends an evaluation in progress; called from any thread.
    func invalidate()
}

extension LAContext: CefLocalAuthenticationContext {}
