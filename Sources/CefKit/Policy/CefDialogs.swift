import AppKit
import CCef
import Foundation

/// A JavaScript dialog request delivered to
/// ``CefBrowserDelegate/browser(_:runJavaScriptDialog:)``.
public struct CefJavaScriptDialog: Sendable, Equatable {
    /// The kind of JavaScript dialog the page is asking to display.
    public enum Kind: Sendable, Equatable {
        /// `window.alert` — message only, single OK button.
        case alert
        /// `window.confirm` — message with OK/Cancel.
        case confirm
        /// `window.prompt` — message with a text field and OK/Cancel.
        case prompt

        init(cefValue: cef_jsdialog_type_t) {
            switch cefValue {
            case JSDIALOGTYPE_CONFIRM: self = .confirm
            case JSDIALOGTYPE_PROMPT: self = .prompt
            default: self = .alert
            }
        }
    }

    /// Whether this is an alert, confirm, or prompt dialog.
    public var kind: Kind
    /// The message text supplied by the page.
    public var message: String
    /// The default text for a prompt's input field (empty for alert/confirm).
    public var defaultPromptText: String
    /// The origin URL that requested the dialog, for display.
    public var origin: String

    public init(kind: Kind, message: String, defaultPromptText: String = "", origin: String = "") {
        self.kind = kind
        self.message = message
        self.defaultPromptText = defaultPromptText
        self.origin = origin
    }
}

/// Native presentation for the dialogs pages can raise — the defaults behind
/// the corresponding ``CefBrowserDelegate`` methods. Call these from your own
/// delegate to keep the stock UI for some cases while customizing others. Sheets attach to
/// the browser's window when it has one, so the app stays responsive.
@MainActor
public enum CefDialogPresenter {
    /// Presents `dialog` and returns the user's answer.
    public static func present(_ dialog: CefJavaScriptDialog, in window: NSWindow?) async -> CefJavaScriptDialogResponse {
        let alert = NSAlert()
        alert.messageText = dialog.origin
        alert.informativeText = dialog.message
        alert.addButton(withTitle: "OK")

        var promptField: NSTextField?
        if dialog.kind != .alert {
            alert.addButton(withTitle: "Cancel")
        }
        if dialog.kind == .prompt {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = dialog.defaultPromptText
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            promptField = field
        }

        guard await run(alert, in: window) == .alertFirstButtonReturn else { return .dismiss }
        return .accept(text: promptField?.stringValue ?? "")
    }

    /// Presents the "leave / stay" confirmation for `beforeunload`.
    public static func confirmLeaving(isReload: Bool, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = isReload ? "Reload this page?" : "Leave this page?"
        alert.informativeText = "Changes you made may not be saved."
        alert.addButton(withTitle: isReload ? "Reload" : "Leave")
        alert.addButton(withTitle: "Stay")
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    /// Presents a name-and-password prompt for HTTP or proxy authentication.
    /// Returns `nil` if the user cancels.
    public static func requestCredential(for challenge: CefAuthenticationChallenge, in window: NSWindow?) async -> CefCredential? {
        let alert = NSAlert()
        alert.messageText = "Sign in"
        alert.informativeText = challenge.isProxy
            ? "The proxy \(challenge.host):\(challenge.port) requires a username and password."
            : "\(challenge.host) requires a username and password."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let username = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        username.nextKeyView = password
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(username)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = username

        guard await run(alert, in: window) == .alertFirstButtonReturn else { return nil }
        return CefCredential(username: username.stringValue, password: password.stringValue)
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
