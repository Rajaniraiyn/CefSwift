import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Chrome extensions: the toolbar's pinned extension actions and a
/// puzzle-piece menu of the rest, each action's popup under its button,
/// per-extension Options, Remove and Manage, and a Manage Extensions window
/// that lists, turns on and off, removes and loads extensions and opens
/// the Chrome Web Store, whose Add to Chrome works in any tab.
///
/// The list is the profile's `CefExtensions` (CefChromium). What a tab
/// shows of an extension is its manifest's action: Chromium keeps the
/// badge, title and icon an extension sets per tab to itself, and opens
/// action popups only in its own windows, so this feature shows the popup
/// page in a small Chrome-style window of its own (``ExtensionPopup``).
struct Extensions: BrowserFeature {
    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .windowList) {
            Button("Extensions") { ManageExtensionsWindow.show(controller: controller) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .trailing { ExtensionsToolbar(browser: browser) }
    }
}

/// Which extensions the toolbar shows a button for, by identifier: the
/// app's own pinning, kept in the user defaults.
@MainActor
@Observable
final class PinnedExtensions {
    static let shared = PinnedExtensions()
    private static let key = "pinnedExtensions"

    private(set) var identifiers: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    func isPinned(_ item: CefExtension) -> Bool { identifiers.contains(item.id.rawValue) }

    func toggle(_ item: CefExtension) {
        if isPinned(item) {
            identifiers.removeAll { $0 == item.id.rawValue }
        } else {
            identifiers.append(item.id.rawValue)
        }
        UserDefaults.standard.set(identifiers, forKey: Self.key)
    }
}

// MARK: - Toolbar

private struct ExtensionsToolbar: View {
    let browser: CefBrowser
    @Environment(BrowserController.self) private var controller
    private let pinned = PinnedExtensions.shared

    private var extensions: CefExtensions { (browser.configuration.profile ?? .default).extensions }

    private var actions: [CefExtension] {
        extensions.installed.filter { $0.isEnabled && $0.action != nil }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions.filter(pinned.isPinned)) { item in
                ExtensionActionButton(item: item, browser: browser)
            }
            ExtensionsMenu(browser: browser, extensions: extensions)
        }
        .task {
            // The first read; CefExtensions keeps the list current after it.
            _ = try? await extensions.refresh()
        }
    }
}

/// One extension's action: its icon, and its popup under it.
private struct ExtensionActionButton: View {
    let item: CefExtension
    let browser: CefBrowser

    var body: some View {
        AnchoredButton(title: item.action?.title ?? item.name) {
            ExtensionIcon(image: item.action?.icon ?? item.icon, size: 16)
        } action: { anchor in
            ExtensionPopup.toggle(for: item, from: anchor, in: browser)
        }
        .help(item.action?.title ?? item.name)
    }
}

/// The puzzle piece: every extension, with its menu.
private struct ExtensionsMenu: View {
    let browser: CefBrowser
    let extensions: CefExtensions
    @Environment(BrowserController.self) private var controller
    private let pinned = PinnedExtensions.shared

    var body: some View {
        Menu {
            if extensions.installed.isEmpty {
                Text("No Extensions")
            }
            ForEach(extensions.installed) { item in
                Menu {
                    ExtensionActions(item: item, extensions: extensions, browser: browser)
                } label: {
                    Label {
                        Text(item.name)
                    } icon: {
                        Image(nsImage: item.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!)
                    }
                }
            }
            Divider()
            Button("Manage Extensions…") { ManageExtensionsWindow.show(controller: controller) }
            Button("Chrome Web Store") { controller.openTab(url: ExtensionLinks.webStore, sharingProfileOf: browser) }
        } label: {
            Label("Extensions", systemImage: "puzzlepiece.extension")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 28)
    }
}

/// What can be done with one extension, for its menus.
private struct ExtensionActions: View {
    let item: CefExtension
    let extensions: CefExtensions
    let browser: CefBrowser
    @Environment(BrowserController.self) private var controller
    private let pinned = PinnedExtensions.shared

    var body: some View {
        if item.action != nil {
            Button(pinned.isPinned(item) ? "Unpin from Toolbar" : "Pin to Toolbar") { pinned.toggle(item) }
        }
        if let options = item.optionsURL {
            Button("Options") { controller.openTab(url: options, sharingProfileOf: browser) }
        }
        if let store = item.webStoreURL {
            Button("View in Chrome Web Store") { controller.openTab(url: store, sharingProfileOf: browser) }
        }
        Divider()
        if item.isUserModifiable {
            Button("Remove “\(item.name)”…") { Task { await ExtensionRemoval.confirm(item, in: extensions) } }
        }
        Button("Manage Extension") { ManageExtensionsWindow.show(controller: controller, selecting: item.id) }
    }
}

enum ExtensionLinks {
    static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!

    static func details(_ id: CefExtension.ID) -> URL {
        URL(string: "chrome://extensions/?id=\(id.rawValue)")!
    }
}

@MainActor
enum ExtensionRemoval {
    /// Asks, as Chrome does, then removes.
    static func confirm(_ item: CefExtension, in extensions: CefExtensions) async {
        let alert = NSAlert()
        alert.messageText = "Remove “\(item.name)”?"
        alert.informativeText = "The extension and its data are removed from this profile."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await extensions.uninstall(item.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// An extension's icon at a fixed size, or the puzzle piece.
struct ExtensionIcon: View {
    let image: NSImage?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

/// A toolbar button that tells its action where it is, so a window can
/// hang from it.
private struct AnchoredButton<Label: View>: View {
    let title: String
    @ViewBuilder let label: () -> Label
    let action: (NSView) -> Void
    @State private var anchor = AnchorView()

    var body: some View {
        Button {
            action(anchor.view)
        } label: {
            label().accessibilityLabel(title)
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .background(AnchorRepresentable(anchor: anchor))
    }
}

@MainActor
private final class AnchorView {
    let view = NSView()
}

private struct AnchorRepresentable: NSViewRepresentable {
    let anchor: AnchorView
    func makeNSView(context: Context) -> NSView { anchor.view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
