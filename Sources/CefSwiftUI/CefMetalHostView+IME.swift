import AppKit
import CefKit
import Foundation

/// `NSTextInputClient` bridge so dead-keys and CJK/IME composition route into
/// the offscreen browser via `imeSetComposition`/`imeCommitText`. AppKit calls
/// these as a result of `interpretKeyEvents(_:)` in `keyDown`.
extension CefMetalHostView: @preconcurrency NSTextInputClient {

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        if handlingKeyDown {
            // Accumulate; keyDown's after-handler decides KEYDOWN+CHAR vs commit.
            textToBeInserted += text
        } else {
            // Direct insert (e.g. IME candidate pick outside a keystroke).
            let range = replacementRange.location == NSNotFound ? nil : replacementRange
            osrBrowser?.imeCommitText(text, replacementRange: range)
        }
        // Inserting text always clears any marked composition.
        hasMarkedTextFlag = false
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedSelectionRange = selectedRange
        markedTextValue = text
        hasMarkedTextFlag = !text.isEmpty
        currentMarkedRange = hasMarkedTextFlag
            ? NSRange(location: 0, length: text.utf16.count)
            : NSRange(location: NSNotFound, length: 0)
        let rep = replacementRange.location == NSNotFound ? nil : replacementRange
        if handlingKeyDown {
            // Defer to the after-handler so it sequences with the key event.
            setMarkedReplacement = rep
        } else {
            if text.isEmpty {
                osrBrowser?.imeCancelComposition()
            } else {
                osrBrowser?.imeSetComposition(text: text, selectionRange: selectedRange, replacementRange: rep)
            }
        }
    }

    public func unmarkText() {
        hasMarkedTextFlag = false
        markedTextValue = ""
        if handlingKeyDown {
            unmarkTextCalled = true
        } else {
            osrBrowser?.imeFinishComposing(keepSelection: true)
        }
    }

    public func selectedRange() -> NSRange {
        currentSelectedTextRange
    }

    public func markedRange() -> NSRange {
        currentMarkedRange
    }

    public func hasMarkedText() -> Bool {
        currentMarkedRange.location != NSNotFound && currentMarkedRange.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Returns the screen rect (bottom-left origin) used to position the IME
    /// candidate window, the emoji & symbols palette (Cmd+Ctrl+Space), and the
    /// press-and-hold accent popup, anchored at the caret.
    ///
    /// Source of the caret rect, in order of fidelity:
    /// 1. **Live composition bounds** — during an active IME composition CEF
    ///    delivers exact per-character bounds via
    ///    `on_ime_composition_range_changed`; we use the first glyph's box.
    /// 2. **Last-known caret rect** — we cache (1) so that immediately after a
    ///    composition ends, and for the accent popup that fires on the next
    ///    key, the anchor stays at the real caret instead of snapping away.
    /// 3. **Focused-view fallback** — with no composition data at all (a plain
    ///    caret in an `<input>`), CEF's OSR API exposes no caret rect for a
    ///    non-composition selection, so we anchor near the top-left of the view
    ///    rather than at the screen origin. This is an honest limitation, not
    ///    pixel-perfect; see the OSR input docs.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return NSRect(origin: .zero, size: .zero) }
        if let bounds = currentImeCharacterBounds.first {
            lastKnownCaretRectDIP = bounds
        }
        let caret = lastKnownCaretRectDIP ?? CGRect(x: 4, y: 4, width: 1, height: 16)
        // Caret bounds are in view DIP (top-left). Build a view-coordinate rect
        // whose origin is the caret's bottom (palette appears just below the
        // glyph), then convert to window then screen (bottom-left).
        let viewRect = NSRect(x: caret.minX, y: caret.maxY,
                              width: max(caret.width, 1), height: max(caret.height, 1))
        let inWindow = convert(viewRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
