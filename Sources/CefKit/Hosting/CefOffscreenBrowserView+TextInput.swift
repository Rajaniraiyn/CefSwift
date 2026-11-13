import AppKit
import Foundation

// Dead keys, accents and input methods reach the page through
// `NSTextInputClient`. During `keyDown(with:)` these methods only record what
// AppKit asked for; see `keyInput`.
extension CefOffscreenBrowserView: @preconcurrency NSTextInputClient {

    private static func plainText(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    private static func optionalRange(_ range: NSRange) -> NSRange? {
        range.location == NSNotFound ? nil : range
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainText(string)
        guard !text.isEmpty else { return }
        if keyInput.handlingKeyDown {
            keyInput.textToBeInserted += text
        } else {
            browser?.insertText(text, replacementRange: Self.optionalRange(replacementRange))
        }
        keyInput.hasMarkedTextFlag = false
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainText(string)
        keyInput.markedSelectionRange = selectedRange
        keyInput.markedTextValue = text
        keyInput.hasMarkedTextFlag = !text.isEmpty
        currentMarkedRange = keyInput.hasMarkedTextFlag
            ? NSRange(location: 0, length: text.utf16.count)
            : NSRange(location: NSNotFound, length: 0)
        let replacement = Self.optionalRange(replacementRange)
        if keyInput.handlingKeyDown {
            keyInput.setMarkedReplacement = replacement
        } else if text.isEmpty {
            browser?.cancelComposition()
        } else {
            browser?.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacement)
        }
    }

    public func unmarkText() {
        keyInput.hasMarkedTextFlag = false
        keyInput.markedTextValue = ""
        if keyInput.handlingKeyDown {
            keyInput.unmarkTextCalled = true
        } else {
            browser?.unmarkText(keepingSelection: true)
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

    /// The screen rect below which the candidate window, the emoji palette
    /// and the accent popup appear.
    ///
    /// Chromium reports the caret only during a composition, so this uses the
    /// last composition's caret, or the view's top-left corner if there has
    /// been none.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let caret = lastKnownCaretRect ?? CGRect(x: 4, y: 4, width: 1, height: 16)
        let rect = NSRect(x: caret.minX, y: caret.maxY, width: max(caret.width, 1), height: max(caret.height, 1))
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
