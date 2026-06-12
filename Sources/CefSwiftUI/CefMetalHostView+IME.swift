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

    /// Returns the screen rect (bottom-left origin) for the IME candidate
    /// window, derived from the last reported composition character bounds.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let firstBounds = currentImeCharacterBounds.first, let window else {
            // Fallback: bottom-left of the view.
            let p = convert(CGPoint(x: 0, y: bounds.height), to: nil)
            return NSRect(origin: window?.convertPoint(toScreen: p) ?? p, size: .zero)
        }
        // Character bounds are in view DIP (top-left). Convert to view coords
        // then to window/screen (bottom-left).
        let viewRect = NSRect(x: firstBounds.minX, y: firstBounds.maxY,
                              width: firstBounds.width, height: firstBounds.height)
        let inWindow = convert(viewRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
