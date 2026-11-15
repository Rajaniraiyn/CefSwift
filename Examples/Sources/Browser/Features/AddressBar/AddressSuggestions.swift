import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// What the address field suggests while you type: Chromium's ranked
/// omnibox matches for the tab's profile, shown in a list under the field.
///
/// Each keystroke starts a query, which stops the one before it
/// (`CefAutocomplete` lets the latest query win), and the list follows
/// Chromium's providers as they answer. When the top match completes
/// what you typed, the rest of its address is added after the caret and
/// selected, as Safari and Chrome do: typing on replaces it, keeping what
/// still matches; Delete removes it and leaves the next suggestions
/// uncompleted; Return opens the completed match; Escape goes back to what
/// you typed. Up and Down move through the list, putting the selected
/// suggestion's text in the field, Return opens it and Escape closes the
/// list. Keys are read with a local event monitor, since the field (a
/// SwiftUI `TextField` inside a toolbar item) keeps keyboard focus
/// throughout; the list is a panel that never becomes key. Text being
/// composed with an input method is never completed.
@MainActor
@Observable
final class AddressSuggestions {
    /// The suggestions for ``typedText``, best first.
    private(set) var items: [CefAutocomplete.Suggestion] = []
    /// The highlighted suggestion; `nil` means the typed text itself.
    private(set) var selection: Int?
    /// What the user typed, as opposed to a suggestion's text put into the
    /// field by moving the selection or completing inline.
    private(set) var typedText = ""
    /// The text shown selected after ``typedText``, completing it to the
    /// top suggestion; `nil` when the field shows only what was typed.
    private(set) var inlineCompletion: String?

    /// The text field, set by `AddressBar`. Called with replacement text
    /// when the selection moves.
    @ObservationIgnored var setFieldText: (String) -> Void = { _ in }
    /// Opens a suggestion.
    @ObservationIgnored var choose: (CefAutocomplete.Suggestion) -> Void = { _ in }
    /// The icon of an open tab showing a URL, for "Switch to Tab" rows.
    @ObservationIgnored var favicon: (URL) -> NSImage? = { _ in nil }

    /// The view the list hangs under.
    @ObservationIgnored weak var anchor: NSView?

    @ObservationIgnored private var query: Task<Void, Never>?
    @ObservationIgnored private var appliedText: String?
    @ObservationIgnored private var keyMonitor: Any?
    /// Whether the last key deleted text, which turns off inline completion
    /// for the edit it makes.
    @ObservationIgnored private var lastKeyDeleted = false
    @ObservationIgnored private lazy var panel = SuggestionsPanel(suggestions: self)

    var selectedSuggestion: CefAutocomplete.Suggestion? {
        selection.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    // MARK: Editing

    /// Starts following the keyboard; call when the field begins editing.
    func beginEditing(profile: CefProfile) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, with the event in hand.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
        }
    }

    /// Closes the list and stops following the keyboard.
    func endEditing() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        dismiss()
    }

    /// Asks for suggestions for the field's new text, unless the change
    /// came from moving the selection.
    func fieldTextChanged(to text: String, profile: CefProfile, currentURL: URL?) {
        if text == appliedText { return }
        appliedText = nil
        let allowsInline = !lastKeyDeleted
        lastKeyDeleted = false
        let previous = (typed: typedText, completion: inlineCompletion)
        typedText = text
        inlineCompletion = nil
        selection = nil
        query?.cancel()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            dismiss()
            return
        }
        // Typing the next character of the completion keeps the rest of it
        // in place until the new suggestions arrive.
        if allowsInline, let completion = previous.completion, completion.count > 1,
           text.lowercased() == (previous.typed + completion.prefix(1)).lowercased() {
            completeInline(with: String(completion.dropFirst()))
        }
        // A newer query stops this one, in Chromium too, so there is no
        // need to wait for a pause in the typing.
        let results = profile.autocomplete.results(for: text, currentURL: currentURL, allowsInlineCompletion: allowsInline)
        query = Task {
            do {
                for try await result in results {
                    guard !Task.isCancelled, typedText == text else { return }
                    show(Array(result.suggestions.prefix(Self.limit)))
                    if allowsInline, let top = result.suggestions.first, top.canBeDefault, !top.inlineCompletion.isEmpty {
                        completeInline(with: top.inlineCompletion)
                    } else if result.isComplete {
                        removeInlineCompletion()
                    }
                }
            } catch {}
        }
    }

    // MARK: Inline completion

    /// The field's editor while it edits.
    private var fieldEditor: NSTextView? {
        guard let window = anchor?.window, let editor = window.firstResponder as? NSTextView,
              editor.delegate is NSTextField
        else { return nil }
        return editor
    }

    /// Shows `completion` selected after the typed text, if the field
    /// still holds just that text (or it with the current completion) with
    /// the caret at its end, and no input method is composing.
    private func completeInline(with completion: String) {
        guard let editor = fieldEditor, !editor.hasMarkedText() else { return }
        let typedLength = (typedText as NSString).length
        let current = editor.string as NSString
        let shown = inlineCompletion ?? ""
        let shownRange = NSRange(location: typedLength, length: (shown as NSString).length)
        let isUntouched = editor.string == typedText + shown
            && editor.selectedRange() == (shown.isEmpty ? NSRange(location: typedLength, length: 0) : shownRange)
        guard isUntouched else { return }
        guard completion != shown else {
            selection = items.isEmpty ? nil : 0
            return
        }
        appliedText = typedText + completion
        // Typed into the field editor, so the field and its binding follow.
        editor.insertText(completion, replacementRange: NSRange(location: typedLength, length: current.length - typedLength))
        editor.setSelectedRange(NSRange(location: typedLength, length: (completion as NSString).length))
        inlineCompletion = completion
        // The completed match is the one Return opens.
        selection = items.isEmpty ? nil : 0
    }

    /// Takes the completion out of the field, leaving what was typed.
    private func removeInlineCompletion() {
        guard inlineCompletion != nil else { return }
        inlineCompletion = nil
        if selection == 0 { selection = nil }
        setField(typedText)
    }

    /// Closes the list without changing the field.
    func dismiss() {
        query?.cancel()
        items = []
        selection = nil
        inlineCompletion = nil
        panel.hide()
    }

    private static let limit = 8

    private func show(_ results: [CefAutocomplete.Suggestion]) {
        items = results
        selection = nil
        if let anchor, !results.isEmpty { panel.show(below: anchor) } else { panel.hide() }
    }

    // MARK: Keys

    /// Handles a key pressed while the field edits. Returns whether the
    /// key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = anchor?.window, event.window === window, window.firstResponder is NSTextView else {
            return false
        }
        // Delete and Forward Delete, with or without modifiers.
        lastKeyDeleted = event.keyCode == 51 || event.keyCode == 117
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 125:  // Down
            guard !items.isEmpty else { return false }
            select(selection.map { min($0 + 1, items.count - 1) } ?? 0)
            return true
        case 126:  // Up
            guard !items.isEmpty else { return false }
            select(selection.flatMap { $0 > 0 ? $0 - 1 : nil })
            return true
        case 36, 76:  // Return, Enter
            guard let suggestion = selectedSuggestion else { return false }
            choose(suggestion)
            return true
        case 53:  // Escape: back to what was typed, then leave the field.
            guard !items.isEmpty || inlineCompletion != nil else { return false }
            setField(typedText)
            dismiss()
            return true
        default:
            return false
        }
    }

    /// Highlights a suggestion (or the typed text, for `nil`) and shows its
    /// text in the field, as Safari does.
    func select(_ index: Int?) {
        selection = index
        inlineCompletion = nil
        setField(selectedSuggestion.map(Self.fieldText(for:)) ?? typedText)
    }

    /// Highlights a suggestion under the pointer, leaving the field as is.
    func highlight(_ index: Int) {
        selection = index
    }

    private func setField(_ text: String) {
        appliedText = text
        setFieldText(text)
    }

    /// The text a suggestion puts in the field.
    static func fieldText(for suggestion: CefAutocomplete.Suggestion) -> String {
        if suggestion.isSearch { return suggestion.text }
        return suggestion.url?.absoluteString ?? suggestion.replacementText
    }
}

// MARK: - The list

/// A borderless panel under the address field. It never becomes key, so
/// the field keeps editing while the list is shown or clicked.
@MainActor
private final class SuggestionsPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<SuggestionsList>

    init(suggestions: AddressSuggestions) {
        hosting = NSHostingView(rootView: SuggestionsList(suggestions: suggestions))
        panel = NonKeyPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting
    }

    func show(below anchor: NSView) {
        guard let window = anchor.window else { return }
        let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        hosting.rootView.width = field.width
        let height = hosting.fittingSize.height
        panel.setFrame(
            CGRect(x: field.minX, y: field.minY - 6 - height, width: field.width, height: height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private final class NonKeyPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

private struct SuggestionsList: View {
    let suggestions: AddressSuggestions
    var width: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(
                    suggestion: suggestion, isSelected: suggestions.selection == index,
                    icon: suggestion.kind == .openTab ? suggestion.url.flatMap(suggestions.favicon) : nil)
                    .contentShape(.rect)
                    .onHover { if $0 { suggestions.highlight(index) } }
                    .onTapGesture { suggestions.choose(suggestion) }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(.thickMaterial, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: CefAutocomplete.Suggestion
    let isSelected: Bool
    /// The page's own icon, when there is one to show.
    var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
            if suggestion.isBookmarked {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.yellow))
                    .help("Bookmarked")
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: subtitle == nil ? 30 : 38)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
    }

    private var symbol: String {
        switch suggestion.kind {
        case .typedURL, .navigationSuggestion: "globe"
        case .history: "clock"
        case .bookmark: "book"
        case .openTab: "square.on.square"
        case .search, .searchSuggestion: "magnifyingglass"
        case .other: suggestion.isSearch ? "magnifyingglass" : "globe"
        }
    }

    /// Pages lead with their title; searches with the query.
    private var title: String {
        if suggestion.isSearch || suggestion.detail.isEmpty { return suggestion.text }
        return suggestion.detail
    }

    private var subtitle: String? {
        if suggestion.kind == .openTab { return "Switch to Tab · \(suggestion.text)" }
        if suggestion.isSearch || suggestion.detail.isEmpty { return nil }
        return suggestion.text
    }
}
