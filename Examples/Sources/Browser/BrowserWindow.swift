import SwiftUI
import CefKit
import CefSwiftUI

/// Main browser chrome: Arc-style vertical tab sidebar + toolbar + web content.
struct BrowserWindow: View {
    @Environment(TabStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            TabSidebar()
                .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                BrowserToolbar()
                Divider()
                ZStack {
                    // All tabs stay alive; only the selected one is visible.
                    ForEach(store.tabs) { tab in
                        CefWebView(model: tab.model)
                            .opacity(tab.id == store.selectedTabID ? 1 : 0)
                            .allowsHitTesting(tab.id == store.selectedTabID)
                    }
                }
            }
        }
        .background(.regularMaterial)
    }
}

// MARK: - Sidebar

private struct TabSidebar: View {
    @Environment(TabStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            // Room for the traffic lights under the hidden title bar.
            Spacer().frame(height: 38)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        TabRow(tab: tab, isSelected: tab.id == store.selectedTabID)
                    }
                }
                .padding(.horizontal, 10)
                .animation(.snappy(duration: 0.22), value: store.tabs.map(\.id))
            }

            Divider().padding(.horizontal, 10)

            Button {
                store.newTab()
            } label: {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(8)
            .help("New Tab (⌘T)")
        }
        .background(.ultraThinMaterial)
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isSelected: Bool
    @Environment(TabStore.self) private var store
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(tab: tab)
                .frame(width: 16, height: 16)

            Text(tab.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Spacer(minLength: 0)

            if isHovered {
                Button {
                    store.close(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? AnyShapeStyle(.background.opacity(0.85))
                       : isHovered ? AnyShapeStyle(.quaternary.opacity(0.6))
                                   : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 9)
        )
        .shadow(color: .black.opacity(isSelected ? 0.10 : 0), radius: 4, y: 1)
        .contentShape(.rect(cornerRadius: 9))
        .onTapGesture { store.selectedTabID = tab.id }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

private struct FaviconView: View {
    let tab: BrowserTab

    var body: some View {
        if let faviconURL = tab.model.faviconURL {
            AsyncImage(url: faviconURL) { image in
                image.resizable().interpolation(.high)
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Group {
            if tab.model.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Toolbar

private struct BrowserToolbar: View {
    @Environment(TabStore.self) private var store
    @State private var omniboxText = ""
    @FocusState private var omniboxFocused: Bool

    private var model: CefWebViewModel? { store.selectedTab?.model }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                navigationButtons
                omnibox
                Button {
                    store.selectedTab?.model.browser?.showDevTools()
                } label: {
                    Image(systemName: "hammer")
                }
                .buttonStyle(.borderless)
                .help("Open DevTools")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            // Thin load-progress bar, Safari-style.
            GeometryReader { proxy in
                let progress = model?.estimatedProgress ?? 0
                Rectangle()
                    .fill(.tint)
                    .frame(width: proxy.size.width * progress)
                    .opacity(model?.isLoading == true ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: progress)
                    .animation(.easeOut(duration: 0.35), value: model?.isLoading == true)
            }
            .frame(height: 2)
        }
        // Keep the omnibox in sync with navigation, unless the user is editing.
        .onChange(of: model?.url) { _, newURL in
            if !omniboxFocused { omniboxText = newURL?.absoluteString ?? "" }
        }
        .onChange(of: store.selectedTabID) {
            omniboxText = model?.url?.absoluteString ?? ""
        }
        .onChange(of: store.omniboxFocusToken) {
            omniboxFocused = true
        }
        .onAppear {
            omniboxText = model?.url?.absoluteString ?? ""
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button {
                model?.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model?.canGoBack != true)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")

            Button {
                model?.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model?.canGoForward != true)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward")

            Button {
                if model?.isLoading == true { model?.stopLoading() } else { model?.reload() }
            } label: {
                Image(systemName: model?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(model?.isLoading == true ? "Stop" : "Reload")
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
                    model?.load(url)
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
        .frame(maxWidth: 640)
    }
}
