import AppKit
import CCef
import Foundation

/// The kind of JavaScript dialog the page is asking to display.
public enum CefJSDialogKind: Sendable, Equatable {
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

/// A JavaScript dialog request delivered to
/// ``CefBrowserDelegate/browser(_:runJSDialog:callback:)``.
public struct CefJSDialog: Sendable, Equatable {
    /// Whether this is an alert, confirm, or prompt dialog.
    public var kind: CefJSDialogKind
    /// The message text supplied by the page.
    public var message: String
    /// The default text for a prompt's input field (empty for alert/confirm).
    public var defaultPromptText: String
    /// The origin URL that requested the dialog, for display.
    public var origin: String

    public init(kind: CefJSDialogKind, message: String, defaultPromptText: String = "", origin: String = "") {
        self.kind = kind
        self.message = message
        self.defaultPromptText = defaultPromptText
        self.origin = origin
    }
}

/// Resolves a JavaScript dialog request. Call exactly one of ``continue(success:userInput:)``
/// or ``cancel()`` to dismiss the dialog; the call may be made synchronously
/// from the delegate or later from your own UI.
public final class CefJSDialogCallback: @unchecked Sendable {
    private let raw: UnsafeMutablePointer<cef_jsdialog_callback_t>
    private var consumed = false

    /// Takes ownership of a +1 `cef_jsdialog_callback_t` reference.
    init(raw: UnsafeMutablePointer<cef_jsdialog_callback_t>) {
        self.raw = raw
    }

    deinit {
        if !consumed {
            cefRelease(UnsafeMutableRawPointer(raw))
        }
    }

    /// Completes the dialog. `success` is whether OK (vs. Cancel) was pressed;
    /// `userInput` is the prompt field's contents (ignored for alert/confirm).
    public func `continue`(success: Bool, userInput: String? = nil) {
        guard !consumed else { return }
        consumed = true
        CefStringUtil.withCefString(userInput ?? "") { input in
            raw.pointee.cont?(raw, success ? 1 : 0, input)
        }
        cefRelease(UnsafeMutableRawPointer(raw))
    }

    /// Cancels the dialog (equivalent to `continue(success: false)`).
    public func cancel() {
        `continue`(success: false, userInput: nil)
    }
}

/// Default native (`NSAlert`) presentation for JavaScript dialogs, used when
/// the delegate does not override ``CefBrowserDelegate/browser(_:runJSDialog:callback:)``.
@MainActor
enum CefJSDialogPresenter {
    static func present(_ dialog: CefJSDialog, callback: CefJSDialogCallback) {
        let alert = NSAlert()
        alert.messageText = dialog.origin.isEmpty ? "" : dialog.origin
        alert.informativeText = dialog.message

        var promptField: NSTextField?
        switch dialog.kind {
        case .alert:
            alert.addButton(withTitle: "OK")
        case .confirm:
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
        case .prompt:
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = dialog.defaultPromptText
            alert.accessoryView = field
            promptField = field
        }

        let response = alert.runModal()
        let ok = response == .alertFirstButtonReturn
        callback.continue(success: ok, userInput: ok ? promptField?.stringValue : nil)
    }

    /// Native "leave/stay" dialog for `beforeunload`.
    static func presentBeforeUnload(message: String, isReload: Bool, callback: CefJSDialogCallback) {
        let alert = NSAlert()
        alert.messageText = isReload ? "Reload this page?" : "Leave this page?"
        alert.informativeText = message.isEmpty
            ? "Changes you made may not be saved." : message
        alert.addButton(withTitle: isReload ? "Reload" : "Leave")
        alert.addButton(withTitle: "Stay")
        let leave = alert.runModal() == .alertFirstButtonReturn
        callback.continue(success: leave)
    }
}
