import AppKit
import CefKit
import CCef
import Foundation

// Keyboard shortcuts and the Edit menu.
//
// Command and Control shortcuts are sent to the page as key events, so its
// `keydown` handlers run and can cancel them, and Chromium applies them to
// the focused field or selection as a browser would. Shortcuts that belong
// to the app or the system are left to AppKit. Edit menu items reach the
// page through the standard responder actions.
extension CefOffscreenBrowserView: NSMenuItemValidation, NSUserInterfaceValidations {

    // MARK: Key equivalents

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let browser, window?.firstResponder === self,
              Self.shouldForwardKeyEquivalent(
                  flags: event.modifierFlags, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        else {
            return super.performKeyEquivalent(with: event)
        }
        var e = makeKeyEvent(event)
        e.type = KEYEVENT_KEYDOWN
        browser.sendKeyEvent(e)
        // Chromium runs editing commands from the key-down; the char event
        // makes the page's `keypress` handlers fire too.
        e.type = KEYEVENT_CHAR
        browser.sendKeyEvent(e)
        return true
    }

    /// Whether a key equivalent goes to the page: any Command or Control
    /// combination except the app and system shortcuts in
    /// ``appGlobalCommandKeys``. Keys without either modifier arrive through
    /// `keyDown(with:)` instead.
    static func shouldForwardKeyEquivalent(
        flags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = f.contains(.command)
        let hasControl = f.contains(.control)
        let chars = charactersIgnoringModifiers?.lowercased() ?? ""
        if hasCommand, appGlobalCommandKeys.contains(chars) {
            return false
        }
        return hasCommand || hasControl
    }

    /// Command shortcuts that belong to the app or the system.
    static let appGlobalCommandKeys: Set<String> = [
        "q",  // Quit
        "w",  // Close
        "m",  // Minimize
        "h",  // Hide
        "`",  // Cycle windows
        ",",  // Settings
        " ",  // Spotlight
        "\t", // App switcher
    ]

    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { browser?.copySelection() }
    @objc public func cut(_ sender: Any?) { browser?.cutSelection() }
    @objc public func paste(_ sender: Any?) { browser?.paste() }
    @objc public func pasteAsPlainText(_ sender: Any?) { browser?.pasteAndMatchStyle() }
    @objc public func delete(_ sender: Any?) { browser?.deleteSelection() }
    @objc public override func selectAll(_ sender: Any?) { browser?.selectAll() }
    @objc public func undo(_ sender: Any?) { browser?.undo() }
    @objc public func redo(_ sender: Any?) { browser?.redo() }

    // Whether the page has a selection or undo history is not known
    // synchronously, so editing items are enabled whenever the page has
    // focus; Chromium ignores commands that do not apply.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateUserInterfaceItem(menuItem)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, Self.editingActions.contains(action) else { return true }
        return browser != nil && window?.firstResponder === self
    }

    private static let editingActions: Set<Selector> = [
        #selector(copy(_:)),
        #selector(cut(_:)),
        #selector(paste(_:)),
        #selector(pasteAsPlainText(_:)),
        #selector(delete(_:)),
        #selector(selectAll(_:)),
        #selector(undo(_:)),
        #selector(redo(_:)),
    ]
}
