import AppKit
import Foundation

// Keyboard shortcuts and the Edit menu.
//
// Command and Control shortcuts are sent to the page as key events, so its
// `keydown` handlers run and can cancel them, and Chromium applies them to
// the focused field or selection as a page would. Shortcuts that belong
// to the app or the system are left to AppKit. Edit menu items reach the
// page through the standard responder actions.
extension CefOffscreenPageView: NSMenuItemValidation, NSUserInterfaceValidations {

    // MARK: Key equivalents

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let page, window?.firstResponder === self,
              Self.shouldForwardKeyEquivalent(
                  flags: event.modifierFlags, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        else {
            return super.performKeyEquivalent(with: event)
        }
        var e = makeKeyEvent(event, phase: .keyDown)
        page.sendKeyEvent(e)
        // Chromium runs editing commands from the key-down; the char event
        // makes the page's `keypress` handlers fire too.
        e.phase = .character
        page.sendKeyEvent(e)
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

    // Responder-chain actions: only the Objective-C runtime needs to see
    // them. `selectAll(_:)` overrides NSResponder's, so it stays public.
    @objc func copy(_ sender: Any?) { page?.copySelection() }
    @objc func cut(_ sender: Any?) { page?.cutSelection() }
    @objc func paste(_ sender: Any?) { page?.paste() }
    @objc func pasteAsPlainText(_ sender: Any?) { page?.pasteAndMatchStyle() }
    @objc func delete(_ sender: Any?) { page?.deleteSelection() }
    @objc public override func selectAll(_ sender: Any?) { page?.selectAll() }
    @objc func undo(_ sender: Any?) { page?.undo() }
    @objc func redo(_ sender: Any?) { page?.redo() }

    // Whether the page has a selection or undo history is not known
    // synchronously, so editing items are enabled whenever the page has
    // focus; Chromium ignores commands that do not apply.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateUserInterfaceItem(menuItem)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, Self.editingActions.contains(action) else { return true }
        return page != nil && window?.firstResponder === self
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
