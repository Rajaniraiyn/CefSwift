import CefKit
import CefSwiftUI
import SwiftUI

/// The native SwiftUI chrome hosted *on top of* the Chrome-runtime browser in
/// the same window (inverted-ownership mode). It paints an opaque toolbar +
/// horizontal tab strip across the top `BrowserShell.chromeHeight` points; the
/// rest is transparent so the web content (inset below) shows through and stays
/// interactive.
struct ChromeOverlay: View {
    @Bindable var shell: BrowserShell

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow(shell: shell)
            TabStrip(shell: shell)
            ProgressStrip(shell: shell)
            Spacer(minLength: 0)   // transparent region over the web content.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Toolbar

private struct ToolbarRow: View {
    @Bindable var shell: BrowserShell
    @State private var omniboxText = ""
    @FocusState private var omniboxFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Leave room for the traffic lights.
            Spacer().frame(width: 70)

            navButtons
            omnibox

            Button { shell.showDevTools() } label: {
                Image(systemName: "hammer")
            }
            .buttonStyle(.borderless)
            .help("Open DevTools")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 52)
        .background(.bar)
        .onChange(of: shell.currentURL) { _, newURL in
            if !omniboxFocused { omniboxText = newURL?.absoluteString ?? "" }
        }
        .onChange(of: shell.selectedTabID) {
            omniboxText = shell.selectedTab?.url.absoluteString ?? ""
        }
        .onChange(of: shell.omniboxFocusToken) { omniboxFocused = true }
        .onAppear { omniboxText = shell.selectedTab?.url.absoluteString ?? "" }
    }

    private var navButtons: some View {
        HStack(spacing: 2) {
            Button { shell.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!shell.canGoBack)
            Button { shell.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!shell.canGoForward)
            Button {
                shell.isLoading ? shell.stopLoading() : shell.reload()
            } label: {
                Image(systemName: shell.isLoading ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.borderless)
    }

    private var omnibox: some View {
        HStack(spacing: 6) {
            Image(systemName: omniboxText.hasPrefix("https://") ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search or enter address", text: $omniboxText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($omniboxFocused)
                .onSubmit {
                    guard let url = Omnibox.destination(for: omniboxText) else { return }
                    shell.navigate(to: url)
                    omniboxFocused = false
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(omniboxFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.15), value: omniboxFocused)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tab strip

private struct TabStrip: View {
    @Bindable var shell: BrowserShell

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(shell.tabs) { tab in
                    TabChip(tab: tab, isSelected: tab.id == shell.selectedTabID, shell: shell)
                }
                Button { shell.newTab() } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Tab (⌘T)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .animation(.snappy(duration: 0.2), value: shell.tabs.map(\.id))
        }
        .frame(height: 42)
        .background(.regularMaterial)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isSelected: Bool
    @Bindable var shell: BrowserShell
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            FaviconView(tab: tab).frame(width: 15, height: 15)
            Text(tab.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 170, alignment: .leading)
            if isHovered || isSelected {
                Button { shell.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? AnyShapeStyle(.background.opacity(0.9))
                       : isHovered ? AnyShapeStyle(.quaternary.opacity(0.5))
                                   : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8)
        )
        .shadow(color: .black.opacity(isSelected ? 0.10 : 0), radius: 3, y: 1)
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture { shell.select(tab) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

private struct FaviconView: View {
    let tab: BrowserTab

    var body: some View {
        if let faviconURL = tab.faviconURL {
            AsyncImage(url: faviconURL) { image in
                image.resizable().interpolation(.high)
            } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "globe")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Progress

private struct ProgressStrip: View {
    @Bindable var shell: BrowserShell

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.tint)
                .frame(width: proxy.size.width * shell.estimatedProgress)
                .opacity(shell.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: shell.estimatedProgress)
                .animation(.easeOut(duration: 0.35), value: shell.isLoading)
        }
        .frame(height: 2)
    }
}

// MARK: - Omnibox heuristic

enum Omnibox {
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") {
            return URL(string: trimmed)
        }
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost") {
            return URL(string: "https://\(trimmed)")
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}
