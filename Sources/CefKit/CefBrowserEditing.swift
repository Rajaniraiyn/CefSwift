import CCef
import Foundation

/// Clipboard and text-editing commands routed to the browser's focused frame.
///
/// These map onto `cef_frame_t`'s editing entry points (`copy`, `cut`, `paste`,
/// `paste_and_match_style`, `del`, `select_all`, `undo`, `redo`). They are the
/// canonical way to drive the standard Edit-menu actions on an offscreen
/// (`CefMetalWebView`) browser, where there is no native field to receive them.
///
/// The command resolves the *focused* frame first (so it acts on whatever
/// `<input>`/`<textarea>`/`contentEditable`/iframe currently holds the caret),
/// falling back to the main frame when nothing is focused (e.g. a page-level
/// text selection that lives in the main document).
///
/// - Note: For OSR views the preferred path for a real keyboard shortcut is to
///   *forward the key event* to the renderer (so the page's JS key handlers run
///   and native input semantics apply). These frame commands back the macOS
///   **Edit menu** and any programmatic invocation; see the OSR input docs.
extension CefBrowser {

    /// Runs `body` with the focused frame if one exists, otherwise the main
    /// frame. The frame is a +1 reference released after `body` returns.
    private func withEditingFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let frame = focusedOrMainFrame() else { return }
        defer { cefRelease(UnsafeMutableRawPointer(frame)) }
        body(frame)
    }

    /// Resolves the focused frame, falling back to the main frame. Caller owns
    /// the returned +1 reference.
    private func focusedOrMainFrame() -> UnsafeMutablePointer<cef_frame_t>? {
        guard let raw = rawBrowserPointer else { return nil }
        if let focused = raw.pointee.get_focused_frame?(raw) {
            return focused
        }
        return raw.pointee.get_main_frame?(raw)
    }

    /// Copies the current selection to the clipboard.
    public func copySelection() { withEditingFrame { $0.pointee.copy?($0) } }

    /// Cuts the current selection to the clipboard.
    public func cutSelection() { withEditingFrame { $0.pointee.cut?($0) } }

    /// Pastes the clipboard contents at the caret, preserving source styling.
    public func paste() { withEditingFrame { $0.pointee.paste?($0) } }

    /// Pastes the clipboard contents as plain text (matching the destination
    /// style).
    public func pasteAndMatchStyle() { withEditingFrame { $0.pointee.paste_and_match_style?($0) } }

    /// Deletes the current selection (forward delete).
    public func deleteSelection() { withEditingFrame { $0.pointee.del?($0) } }

    /// Selects all content in the focused frame.
    public func selectAll() { withEditingFrame { $0.pointee.select_all?($0) } }

    /// Undoes the last edit in the focused frame.
    public func undo() { withEditingFrame { $0.pointee.undo?($0) } }

    /// Redoes the last undone edit in the focused frame.
    public func redo() { withEditingFrame { $0.pointee.redo?($0) } }
}
