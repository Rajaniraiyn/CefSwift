import AppKit
import CefKit
import CCef
import Foundation

/// Standard editing/clipboard responder actions and the `performKeyEquivalent`
/// policy that make an offscreen `CefMetalWebView` behave like a real web page
/// for keyboard shortcuts and the macOS **Edit** menu.
///
/// ## Two complementary paths
///
/// 1. **Edit menu / Services / programmatic** → the `@objc` responder actions
///    below (`copy(_:)`, `paste(_:)`, …). AppKit walks the responder chain when
///    the user picks Edit ▸ Copy or presses an unhandled standard equivalent;
///    these route to the focused-frame clipboard commands on ``CefBrowser``.
///
/// 2. **Live keyboard shortcuts** → ``performKeyEquivalent(with:)``. When the
///    view is first responder we *forward the key event itself* to the renderer
///    (as `KEYEVENT_KEYDOWN` + `KEYEVENT_CHAR`) for the set of web-editing
///    combos, then return `true` to consume it. Forwarding (rather than calling
///    `browser.copySelection()` directly) is deliberate: it fires the page's JS
///    `keydown`/`keypress` handlers, respects `preventDefault()`, and lets
///    Chromium apply the correct semantics inside `<input>`, `<textarea>`,
///    `contentEditable`, and the page's own selection — exactly as in a real
///    browser. App-global shortcuts (Cmd+Q/W/M/H/`/,/Tab/Space and the
///    function/media keys) are *not* consumed; they fall through to the app/OS.
extension CefMetalHostView: NSMenuItemValidation, NSUserInterfaceValidations {

    // MARK: performKeyEquivalent policy

    /// AppKit gives the key view a first crack at command-key combinations
    /// before the menu. We forward web-editing combos to the renderer and
    /// consume them; everything else (true app/OS shortcuts) passes through by
    /// returning `false`.
    ///
    /// Forwarded (consumed) when browser-focused:
    /// - Cmd+A/C/V/X/Z and Shift+Cmd+Z (select-all, copy, paste, cut, undo, redo)
    /// - Cmd+Left/Right/Up/Down and Cmd+Backspace (line/document caret nav + delete)
    /// - Option+Left/Right/Delete (word nav/delete)
    /// - Cmd+Shift+V (paste & match style — handled by the renderer)
    ///
    /// Passed through (NOT consumed), so the app/OS handles them:
    /// - Cmd+Q (quit), Cmd+W (close), Cmd+M (minimize), Cmd+H (hide),
    ///   Cmd+` (cycle windows), Cmd+, (preferences), Cmd+Tab, Cmd+Space
    ///   (Spotlight) — and any combo while no browser is focused.
    /// - Plain function keys / media keys (no Cmd) — AppKit/system own these.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let browser = osrBrowser, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        guard Self.shouldForwardKeyEquivalent(
            flags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return super.performKeyEquivalent(with: event)
        }
        // Forward the key event so the renderer performs the web-native action
        // (and the page's JS handlers fire). Cmd-combos do not produce an
        // insertable character on macOS, so we send KEYDOWN then CHAR using the
        // unmodified character as the CHAR payload (matching how Chromium feeds
        // edit commands on mac).
        forwardEditingKeyEvent(event, to: browser)
        return true
    }

    /// Pure policy: decide whether a command/control key equivalent should be
    /// *forwarded to the renderer and consumed* (return `true`) or *passed
    /// through to the app/OS* (return `false`). Extracted for testability.
    ///
    /// Rule:
    /// - Pass through any Command combo in ``appGlobalCommandKeys`` (Cmd+Q/W/M/
    ///   H/`/,/Space/Tab) — these belong to the app/OS.
    /// - Forward any other combo that carries Command or Control (the web
    ///   editing/navigation shortcuts: A/C/V/X/Z, arrows, etc.).
    /// - Pass through everything else (plain keys arrive via `keyDown`;
    ///   intercepting here would double-send).
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

    /// Command-key letters/punctuation that belong to the app or the system and
    /// must never be swallowed by the page.
    static let appGlobalCommandKeys: Set<String> = [
        "q",  // Quit
        "w",  // Close window/tab
        "m",  // Minimize
        "h",  // Hide
        "`",  // Cycle windows
        ",",  // Preferences
        " ",  // Spotlight (Cmd+Space)
        "\t", // Cmd+Tab app switch
    ]

    /// Sends a forwarded key event for a consumed equivalent: KEYDOWN then,
    /// where a character payload exists, a CHAR. Mirrors the deferred-model
    /// send used in `keyDown` but without IME accumulation (Cmd-combos never
    /// compose).
    private func forwardEditingKeyEvent(_ event: NSEvent, to browser: CefBrowser) {
        var e = makeKeyEvent(event)
        e.type = KEYEVENT_KEYDOWN
        browser.sendKeyEvent(e)
        // For Control-combos (e.g. Ctrl+A caret-to-line-start in inputs) a CHAR
        // is appropriate; for pure Cmd-combos Chromium treats the KEYDOWN as
        // the edit command and a CHAR is harmless/ignored, but we still send it
        // so JS keypress fires consistently.
        e.type = KEYEVENT_CHAR
        browser.sendKeyEvent(e)
    }

    // MARK: Standard responder actions (Edit menu + Services)

    @objc public func copy(_ sender: Any?) { osrBrowser?.copySelection() }
    @objc public func cut(_ sender: Any?) { osrBrowser?.cutSelection() }
    @objc public func paste(_ sender: Any?) { osrBrowser?.paste() }
    @objc public func pasteAsPlainText(_ sender: Any?) { osrBrowser?.pasteAndMatchStyle() }
    @objc public func delete(_ sender: Any?) { osrBrowser?.deleteSelection() }
    @objc public override func selectAll(_ sender: Any?) { osrBrowser?.selectAll() }
    @objc public func undo(_ sender: Any?) { osrBrowser?.undo() }
    @objc public func redo(_ sender: Any?) { osrBrowser?.redo() }

    // MARK: Menu / toolbar item validation

    /// Enable the standard editing items whenever a browser is focused. We
    /// can't cheaply query the renderer for "is there a selection / can undo"
    /// from the menu-validation call (that state is async), so we enable
    /// optimistically — the renderer no-ops a command that doesn't apply,
    /// which matches how WKWebView behaves for these items.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if isEditingAction(menuItem.action) {
            return osrBrowser != nil && window?.firstResponder === self
        }
        // Not one of our editing actions: enable by default (items we don't
        // own are validated by their own targets elsewhere in the chain).
        return true
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if isEditingAction(item.action) {
            return osrBrowser != nil && window?.firstResponder === self
        }
        return true
    }

    private func isEditingAction(_ action: Selector?) -> Bool {
        guard let action else { return false }
        return Self.editingActions.contains(action)
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
