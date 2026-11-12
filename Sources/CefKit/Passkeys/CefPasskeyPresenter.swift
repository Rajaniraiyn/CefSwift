import AppKit
import LocalAuthentication

/// The native passkey sheet behind the default
/// ``CefBrowserDelegate/browser(_:decidePasskeyRequest:)``.
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
    public static func present(
        _ request: CefPasskeyRequest, in window: NSWindow?, verifier: CefUserVerifier = .deviceOwner
    ) async -> CefPasskeyDecision {
        guard request.hasUserGesture else { return .ignore }
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "person.badge.key.fill", accessibilityDescription: nil)
        var picker: NSPopUpButton?

        switch request.kind {
        case .registration:
            alert.messageText = "Save a passkey for “\(request.host)”?"
            alert.informativeText = "A passkey lets you sign in to this website without a password. "
                + "It is saved on this Mac."
            alert.addButton(withTitle: "Continue")
        case .assertion where request.passkeys.isEmpty:
            alert.messageText = "No passkeys for “\(request.host)”"
            alert.informativeText = "You have no saved passkeys for this website."
            alert.addButton(withTitle: "OK")
            _ = await run(alert, in: window)
            return .deny
        case .assertion:
            alert.messageText = "Sign in to “\(request.host)” with your passkey?"
            if request.passkeys.count == 1 {
                alert.informativeText = request.passkeys[0].userName
            } else {
                alert.informativeText = "Choose an account."
                let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
                popUp.addItems(withTitles: request.passkeys.map(\.userName))
                alert.accessoryView = popUp
                picker = popUp
            }
            alert.addButton(withTitle: "Continue")
        }
        alert.addButton(withTitle: "Cancel")

        guard await run(alert, in: window) == .alertFirstButtonReturn else { return .deny }
        let verification = await verifier.verify(reason(for: request))
        return decision(for: request, choosing: picker?.indexOfSelectedItem ?? 0, after: verification)
    }

    /// Verifies the user with Touch ID, a paired Apple Watch, or the
    /// account password, as ``CefUserVerifier/deviceOwner`` does.
    public static func verifyUser(reason: String) async -> CefUserVerification {
        await verifyUser(reason: reason, with: LAContext())
    }

    static func verifyUser(reason: String, with context: sending some CefLocalAuthenticationContext) async -> CefUserVerification {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "User verification is not available.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .verified : .failed
        } catch {
            return .failed
        }
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
        request.kind == .registration ? "save a passkey for \(request.host)" : "sign in to \(request.host)"
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
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
protocol CefLocalAuthenticationContext {
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool
}

extension LAContext: CefLocalAuthenticationContext {}
