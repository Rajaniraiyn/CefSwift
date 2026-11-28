# Recipes: Arc-style vertical tabs, spaces, a command bar

Address-bar suggestions live in the command bar here: the address field
opens it with `replacingCurrentTab: true`. For suggestions in a list hanging
under the field, read the Browser example's
[`AddressSuggestions.swift`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Browser/Features/AddressBar/AddressSuggestions.swift).

Each recipe builds on the starter ([starter.md](starter.md)): a `Browser`
controller and windows dressed in `CefTabs.onWindowOpened`. Every snippet
compiles against CefSwift 0.2; each one is a file of its own in
`Sources/<App>/`.

## Vertical tabs (a sidebar)

Chrome has vertical tabs; turn them on for the profile and cover them with
your sidebar. Chromium decides the sidebar's width (`sidebarWidth`) from
the layout, and the top bar keeps only the toolbar.

```swift
// Sources/MyBrowser/Sidebar.swift
import CefChromium
import CefSwiftUI
import SwiftUI

/// Call `SidebarLayout.dress(window, spaces:)` from `onWindowOpened`
/// instead of the starter's top bar.
@MainActor
enum SidebarLayout {
    static func dress(_ window: CefChromeWindow, spaces: Spaces) {
        window.profile.tabs.layout = .vertical(width: 240)
        window.showsChromeUI = false
        window.setSidebar { Sidebar(window: window, spaces: spaces) }
        window.setTopBar { SidebarTopBar(window: window) }
    }
}

/// Over Chrome's toolbar. Show the starter's `Toolbar(page:)` here (back,
/// forward, reload, the address field); the title stands in for it.
struct SidebarTopBar: View {
    let window: CefChromeWindow

    var body: some View {
        HStack {
            Spacer()
            if let page = window.activeTab?.page {
                Text(page.title).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}

/// Pinned tabs as a grid of icons on top, the current space's tabs as a
/// list, the spaces as buttons at the bottom.
struct Sidebar: View {
    let window: CefChromeWindow
    let spaces: Spaces

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 24)  // the window buttons
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))]) {
                ForEach(window.tabs.filter(\.isPinned)) { tab in
                    Button { Task { try? await tab.select() } } label: { TabIcon(tab: tab).frame(width: 44, height: 32) }
                        .buttonStyle(.borderless)
                        .background(tab.isActive ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(spaces.tabs(in: window).filter { !$0.isPinned }) { tab in
                        HStack {
                            TabIcon(tab: tab)
                            Text(tab.title.isEmpty ? "New Tab" : tab.title).lineLimit(1)
                            Spacer()
                            Button("Close", systemImage: "xmark") { tab.close() }.labelStyle(.iconOnly)
                        }
                        .padding(6)
                        .background(tab.isActive ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                        .onTapGesture { Task { try? await tab.select() } }
                        .contextMenu {
                            Button(tab.isPinned ? "Unpin" : "Pin") { Task { try? await tab.pin(!tab.isPinned) } }
                        }
                    }
                }
            }
            HStack {
                Button("Home") { spaces.current = nil }
                ForEach(window.groups) { group in
                    Button(group.title.isEmpty ? "Space" : group.title) { Task { try? await spaces.show(group) } }
                        .fontWeight(spaces.current == group.id ? .bold : .regular)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }
}

struct TabIcon: View {
    let tab: CefTab

    var body: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe")
        }
    }
}
```

## Spaces

Two kinds, pick by what the user wants kept apart:

- **Tabs kept apart** (Arc's spaces in one profile): a space is one of
  Chromium's tab groups. The sidebar shows the current group's tabs; the
  others stay in Chromium's strip, under your sidebar. Extensions see the
  groups as Chrome's.
- **Logins kept apart** (work and personal): a space is a persistent
  profile with its own windows: `CefChromeWindow.open(url:profile:)` with
  `CefProfile.persistent(id: "work", displayName: "Work")`. Tabs cannot
  move between profiles; reopen the address in the other profile instead.

```swift
// Sources/MyBrowser/Spaces.swift
import CefChromium
import Foundation
import Observation

/// Spaces as tab groups. `current == nil` is the space of ungrouped tabs.
@MainActor
@Observable
final class Spaces {
    var current: CefTabGroup.ID?

    func tabs(in window: CefChromeWindow) -> [CefTab] {
        window.tabs.filter { $0.group?.id == current }
    }

    /// A new space, starting with one tab.
    func create(named title: String, in window: CefChromeWindow, url: URL) async throws {
        let tab = try await window.openTab(url)
        guard let group = try await window.profile.tabs.group([tab]) else { return }
        try await group.setTitle(title)
        current = group.id
    }

    func show(_ group: CefTabGroup) async throws {
        current = group.id
        if let tab = group.tabs.last { try await tab.select() }
    }

    /// New tabs open in the current space.
    func openTab(_ url: URL, in window: CefChromeWindow) async throws {
        let tab = try await window.openTab(url)
        if let group = window.groups.first(where: { $0.id == current }) {
            try await group.add([tab])
        }
    }
}
```

Group titles and colours change through Chrome's own editor, kept off
screen; collapsing throws `.unsupported` (Chromium allows it only to
extensions). Neither matters here: the sidebar filters by group.

## Command bar (⌘K, ⌘T, ⌘L)

A panel over the window: type to find an open tab, or one of Chromium's
ranked suggestions (history, bookmarks, open tabs, search). Return opens the
first; Escape closes. The same panel serves as the address bar's suggestion
list: open it with `replacingCurrentTab: true` from ⌘L or a click on the
address field.

A page overlay never takes events, and the top bar is only as tall as
Chrome's toolbar, so the bar is a child window of its own.

```swift
// Sources/MyBrowser/CommandBar.swift
import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

@MainActor
final class CommandBar {
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    func show(over window: CefChromeWindow, replacingCurrentTab: Bool = false) {
        dismiss()
        guard let parent = window.window else { return }
        let size = NSSize(width: 640, height: 400)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CommandBarView(
            window: window, replacingCurrentTab: replacingCurrentTab, close: { [weak self] in self?.dismiss() }))
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.maxY - 140 - size.height))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        // Clicking anywhere else closes it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        self.panel = panel
    }

    func dismiss() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.close() }
        panel = nil
    }
}

struct CommandBarView: View {
    let window: CefChromeWindow
    let replacingCurrentTab: Bool
    let close: () -> Void
    @State private var text = ""
    @State private var suggestions: [CefAutocomplete.Suggestion] = []
    @FocusState private var isFocused: Bool

    private var matchingTabs: [CefTab] {
        guard !text.isEmpty else { return [] }
        return window.tabs.filter {
            $0.title.localizedCaseInsensitiveContains(text)
                || ($0.url?.absoluteString.localizedCaseInsensitiveContains(text) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search tabs, history and bookmarks, or enter an address", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($isFocused)
                .onSubmit(openFirst)
                .onExitCommand(perform: close)
            Divider()
            List {
                ForEach(matchingTabs) { tab in
                    Button { select(tab) } label: {
                        Label(tab.title.isEmpty ? "New Tab" : tab.title, systemImage: "square.on.square")
                    }
                }
                ForEach(suggestions) { suggestion in
                    Button { open(suggestion.url) } label: {
                        Label {
                            Text(suggestion.text) + Text("  " + suggestion.detail).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: symbol(for: suggestion.kind))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .buttonStyle(.plain)
        }
        .onAppear { isFocused = true }
        // Each keystroke starts a query; the latest query wins, so no debouncing.
        .task(id: text) {
            guard !text.isEmpty else { return suggestions = [] }
            do {
                for try await result in window.profile.autocomplete.results(for: text) {
                    suggestions = result.suggestions
                }
            } catch {
                suggestions = []
            }
        }
    }

    private func openFirst() {
        if let tab = matchingTabs.first { return select(tab) }
        // Chromium's first suggestion is what was typed: an address or a search.
        if let first = suggestions.first { open(first.url) }
    }

    private func select(_ tab: CefTab) {
        Task { try? await tab.select() }
        close()
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        if replacingCurrentTab, let page = window.activeTab?.page {
            page.load(url)
        } else {
            Task { try? await window.openTab(url) }
        }
        close()
    }

    private func symbol(for kind: CefAutocomplete.Suggestion.Kind) -> String {
        switch kind {
        case .bookmark: "star"
        case .history, .typedURL: "clock"
        case .openTab: "square.on.square"
        case .search, .searchSuggestion: "magnifyingglass"
        default: "globe"
        }
    }
}
```

Wire it to the menu with the app's other commands
(`.commands { CommandBarCommands(commandBar: browser.commandBar, windows: { browser.windows }) }`,
with `let commandBar = CommandBar()` in the `Browser` controller):

```swift
// Sources/MyBrowser/CommandBarCommands.swift
import CefChromium
import SwiftUI

struct CommandBarCommands: Commands {
    let commandBar: CommandBar

    /// Every window, private ones included: the starter's `browser.windows`.
    let windows: () -> [CefChromeWindow]

    private var frontWindow: CefChromeWindow? {
        windows().first { $0.window?.isKeyWindow == true } ?? windows().last
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Command Bar") {
                if let window = frontWindow { commandBar.show(over: window) }
            }
            .keyboardShortcut("k")
            Button("Open Location") {
                if let window = frontWindow { commandBar.show(over: window, replacingCurrentTab: true) }
            }
            .keyboardShortcut("l")
        }
    }
}
```

To make ⌘T open the bar instead of a blank tab, as Arc does, give New Tab
the command bar's action. Up and Down selection is left out for length;
the Browser example's `Features/AddressBar/AddressSuggestions.swift` has
it, with inline completion.
