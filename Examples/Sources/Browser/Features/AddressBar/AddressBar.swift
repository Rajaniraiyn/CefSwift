import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The address field in the middle of the toolbar. It shows where you are —
/// the site, load progress, and the accessories other features add — and
/// becomes an editable location field when clicked, with Chromium's
/// suggestions (`CefAutocomplete`) as you type. File › Open Location (⌘L)
/// starts editing it.
struct AddressBar: BrowserFeature {
    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Location…") { controller.focusAddressBar() }.keyboardShortcut("l")
        }
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for page: CefPage) -> some View {
        if placement == .principal { AddressField(page: page) }
    }
}

private struct AddressField: View {
    let page: CefPage
    @Environment(BrowserController.self) private var controller

    @State private var text = ""
    @State private var suggestions = AddressSuggestions()
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            controller.toolbarItems(.addressFieldLeading, for: page)
            ZStack {
                TextField("Search or enter website name", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(navigate)
                    .onExitCommand { isFocused = false }
                    .opacity(isFocused ? 1 : 0)
                if !isFocused {
                    // Where you are, centered; clicking starts editing the
                    // full address. (Changing the field's own alignment
                    // would end editing, so this is a separate view.)
                    Text(summary.isEmpty ? "Search or enter website name" : summary)
                        .foregroundStyle(summary.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
            }
            controller.toolbarItems(.addressFieldTrailing, for: page)
            if !isFocused, page.url != nil {
                Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
                    if page.isLoading { page.stopLoading() } else { page.reload() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .environment(\.isEditingAddress, isFocused)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.quaternary.opacity(isFocused ? 0.5 : 0.8), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.7 : 0), lineWidth: 2.5)
                .padding(-2)
        }
        .overlay(alignment: .bottomLeading) { progress }
        .background(ViewAnchor { suggestions.anchor = $0 })
        // Chromium's bubbles (Cast, translate, passwords, …) open under the
        // field's trailing end, where Chrome's would hang from its omnibox.
        .chromiumSurfaceAnchor(alignment: .trailing)
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .onAppear {
            suggestions.setFieldText = { [$text] in $text.wrappedValue = $0 }
            suggestions.favicon = { [controller] url in controller.tab(showing: url)?.favicon }
            suggestions.choose = { [page, controller, $isFocused] suggestion in
                $isFocused.wrappedValue = false
                Self.open(suggestion, in: page, controller: controller)
            }
        }
        .onChange(of: page.url, initial: true) {
            if !isFocused { text = editableText }
        }
        .onChange(of: text) {
            guard isFocused else { return }
            suggestions.fieldTextChanged(
                to: text, profile: page.configuration.profile ?? .default, currentURL: page.url)
        }
        .onChange(of: isFocused) { _, focused in
            guard focused else {
                suggestions.endEditing()
                text = editableText
                return
            }
            suggestions.beginEditing(profile: page.configuration.profile ?? .default)
            // Select the whole address so typing replaces it, as Safari does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    /// What the field shows when not editing.
    private var summary: String {
        controller.isStartPage(page.url) ? "" : AddressBar.summary(
            of: page.url, title: page.title,
            securityDisplay: page.url.flatMap(CefRuntime.shared.securityDisplayString(for:)))
    }

    /// What the field shows while editing: the full address.
    private var editableText: String {
        controller.isStartPage(page.url) ? "" : AddressBar.editableText(for: page.url)
    }

    /// Load progress, a hairline along the field's lower edge.
    private var progress: some View {
        GeometryReader { field in
            Rectangle()
                .fill(.tint)
                .frame(width: field.size.width * page.estimatedProgress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(.rect(cornerRadius: 9))
        .opacity(page.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: page.estimatedProgress)
        .animation(.easeOut(duration: 0.4), value: page.isLoading)
        .allowsHitTesting(false)
    }

    private func navigate() {
        guard let destination = TypedAddress.destination(for: text) else { return }
        isFocused = false
        page.load(destination)
    }

    /// Goes where a suggestion leads: an open tab is brought forward, a
    /// search runs on the browser's search engine, a page opens.
    private static func open(_ suggestion: CefAutocomplete.Suggestion, in page: CefPage, controller: BrowserController) {
        if suggestion.kind == .openTab, let url = suggestion.url, controller.switchToTab(showing: url) { return }
        let destination = suggestion.isSearch ? TypedAddress.searchURL(for: suggestion.text) : suggestion.url
        if let destination = destination ?? TypedAddress.destination(for: suggestion.replacementText) {
            page.load(destination)
        }
    }
}

extension AddressBar {
    /// What the field shows when not editing a page other than the start
    /// page: the site's host without `www.`, the title of an internal page,
    /// or, for other schemes, the address as Chromium shows it to decide
    /// on trust (`securityDisplay`, from
    /// `CefRuntime.securityDisplayString(for:)`): never a `data:` page's
    /// whole content.
    nonisolated static func summary(of url: URL?, title: String, securityDisplay: String? = nil) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        if BrowserPages.isInternal(url) { return title.isEmpty ? url.absoluteString : title }
        guard let host = url.host(), url.scheme == "https" || url.scheme == "http" else {
            guard url.scheme == "data" else { return securityDisplay ?? url.absoluteString }
            // However Chromium spells it, a page's content is not its address.
            return securityDisplay.flatMap { $0.count <= 32 ? $0 : nil } ?? "data:"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the field shows while editing a page other than the start page:
    /// the full address, or nothing for a blank tab.
    nonisolated static func editableText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }
}

/// Hands over the AppKit view behind a SwiftUI view, for positioning
/// windows against it.
private struct ViewAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
