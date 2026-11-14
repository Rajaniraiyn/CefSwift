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
        // An alert keeps NSAlert's own OK button, which AppKit localizes.
        if dialog.kind != .alert {
            alert.addButton(withTitle: String(localized: "OK", bundle: .cefKit, comment: "JavaScript confirm() and prompt(): the button that accepts."))
            alert.addButton(withTitle: String(localized: "Cancel", bundle: .cefKit, comment: "A button that dismisses a sheet without answering it."))
        }

        var promptField: NSTextField?
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
        alert.messageText = isReload
            ? String(localized: "Reload this page?", bundle: .cefKit, comment: "Title of the sheet a page's beforeunload handler raises when the user reloads.")
            : String(localized: "Leave this page?", bundle: .cefKit, comment: "Title of the sheet a page's beforeunload handler raises when the user navigates away.")
        alert.informativeText = String(localized: "Changes you made may not be saved.", bundle: .cefKit, comment: "Message of the beforeunload sheet.")
        alert.addButton(withTitle: isReload
            ? String(localized: "Reload", bundle: .cefKit, comment: "beforeunload sheet: the button that reloads the page.")
            : String(localized: "Leave", bundle: .cefKit, comment: "beforeunload sheet: the button that leaves the page."))
        alert.addButton(withTitle: String(localized: "Stay", bundle: .cefKit, comment: "beforeunload sheet: the button that stays on the page."))
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    /// Presents a name-and-password prompt for HTTP or proxy authentication.
    /// Returns `nil` if the user cancels.
    public static func requestCredential(for challenge: CefAuthenticationChallenge, in window: NSWindow?) async -> CefCredential? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign In to Website", bundle: .cefKit, comment: "Title of the HTTP authentication sheet.")
        let host = challenge.host
        let proxy = "\(challenge.host):\(challenge.port)"
        alert.informativeText = challenge.isProxy
            ? String(localized: "The proxy \(proxy) requires a username and password.", bundle: .cefKit,
                     comment: "HTTP authentication sheet for a proxy: %@ is the proxy's host and port, such as proxy.example.com:8080.")
            : String(localized: "\(host) requires a username and password.", bundle: .cefKit,
                     comment: "HTTP authentication sheet: %@ is the website's host, such as example.com.")
        alert.addButton(withTitle: String(localized: "Sign In", bundle: .cefKit, comment: "HTTP authentication sheet: the button that sends the user name and password."))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .cefKit, comment: "A button that dismisses a sheet without answering it."))

        let username = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        username.placeholderString = String(localized: "Username", bundle: .cefKit, comment: "HTTP authentication sheet: placeholder of the user name field.")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = String(localized: "Password", bundle: .cefKit, comment: "HTTP authentication sheet: placeholder of the password field.")
        username.nextKeyView = password
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(username)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = username

        guard await run(alert, in: window) == .alertFirstButtonReturn else { return nil }
        return CefCredential(username: username.stringValue, password: password.stringValue)
    }

    /// Shows `alert` until the user answers or the calling task is
    /// cancelled, which dismisses it as Cancel (`.abort`): CefKit cancels
    /// a dialog whose page navigated or closed. A sheet on `window` when it
    /// is visible, a modal alert otherwise; a task cancelled already shows
    /// nothing. Every default presenter that shows an alert uses this, so
    /// each dismisses itself both ways.
    package static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else { return .abort }
        let dismiss = { @MainActor @Sendable in
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            } else if NSApp.modalWindow === alert.window {
                // Ends the modal session from outside its event handling,
                // as a run-loop callout does; stopModal would wait for an
                // event first.
                NSApp.abortModal()
            }
        }
        return await withTaskCancellationHandler {
            if let window, window.isVisible {
                return await alert.beginSheetModal(for: window)
            }
            return alert.runModal()
        } onCancel: {
            dismissOnMain(dismiss)
        }
    }

    /// Runs `dismiss` on the main thread, in the modal run-loop mode too.
    ///
    /// While `runModal()` runs, the main actor's queued jobs do not: a
    /// `Task { @MainActor in … }` would wait for the modal session it is
    /// meant to end. CefKit cancels decisions on the main thread, from CEF
    /// callbacks that the message pump delivers inside the modal loop, so
    /// `dismiss` usually runs at once; from another thread it goes to the
    /// main run loop, which serves the modal mode.
    nonisolated static func dismissOnMain(_ dismiss: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { dismiss() }
        } else {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { MainActor.assumeIsolated { dismiss() } }
        }
    }
}
