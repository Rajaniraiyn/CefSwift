import AppKit
import LocalAuthentication

/// The native passkey sheet behind the default
/// ``CefBrowserDelegate/browser(_:decidePasskeyRequest:)``.
///
/// It names the site, asks the user to confirm, and verifies the user with
/// Touch ID or the account password (`LAContext`, policy
/// `deviceOwnerAuthentication`) before answering. Call it from your own
/// delegate to keep the stock UI for some requests.
@MainActor
public enum CefPasskeyPresenter {
    /// Asks the user about `request` and returns the answer.
    ///
    /// A request made without a user gesture, as conditional mediation is,
    /// is left unanswered (``CefPasskeyDecision/ignore``) without showing
    /// anything, so a sign-in page that offers passkeys as it loads does
    /// not raise a sheet.
    public static func present(_ request: CefPasskeyRequest, in window: NSWindow?) async -> CefPasskeyDecision {
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
        let reason = request.kind == .registration
            ? "save a passkey for \(request.host)"
            : "sign in to \(request.host)"
        guard await verifyUser(reason: reason) else { return .deny }
        switch request.kind {
        case .registration:
            return .createPasskey
        case .assertion:
            return .signIn(with: request.passkeys[max(0, picker?.indexOfSelectedItem ?? 0)])
        }
    }

    /// Verifies the user with Touch ID, a paired Apple Watch, or the
    /// account password. Returns `false` if the user cancels or fails, and
    /// `true` on a Mac where no verification is set up.
    public static func verifyUser(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
