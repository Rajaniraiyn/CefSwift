import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// A complete tabbed web browser in a few hundred lines.
///
/// Every tab is a Chrome-style ``CefBrowserWindow`` — so `chrome://settings`,
/// `chrome://extensions`, history, downloads, passwords and PDF viewing all
/// work — with a SwiftUI toolbar on top. Windows share a tabbing identifier,
/// so macOS presents them as native tabs.
@main
struct BrowserApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.browser
        configuration.productName = "CefSwift Browser"
        // Chrome's own UI is replaced by the SwiftUI toolbar; keep its
        // internal pages free of buttons that would open Chrome windows.
        configuration.chromeToolbar.hiddenAppMenuCommands = [.newWindow, .newIncognitoWindow]
        configuration.customSchemes = [CefCustomScheme(name: BrowserPages.scheme)]
        // Quit immediately on ⌘Q instead of Chromium's "Hold ⌘Q to Quit".
        configuration.preferences["browser.confirm_to_quit"] = false
        if let path = UserDefaults.standard.string(forKey: "cacheDirectory") {
            configuration.rootCacheDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        return configuration
    }

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Browser windows are created by BrowserController, not by a scene.
        Settings { SettingsView() }
            .commands { BrowserCommands(controller: appDelegate.controller) }
            // SwiftUI would open Settings at launch, it being the only scene.
            .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BrowserController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CefRuntime.shared.registerSchemeHandler(scheme: BrowserPages.scheme, handler: BrowserPages())
        Appearance.current.apply()
        MemorySaver.current.apply()
        controller.adoptTabsOpenedByChromium()
        // Launching the app again while it runs opens a tab, or the
        // addresses it was given (`Browser https://swift.org`).
        CefRuntime.shared.onRelaunch = { [controller] arguments, directory in
            let urls = arguments.compactMap { LaunchOptions.url(fromArgument: $0, relativeTo: directory) }
            if urls.isEmpty { controller.openTab() } else { urls.forEach { controller.openTab(url: $0) } }
        }
        controller.library.start()
        if UserDefaults.standard.bool(forKey: "showTaskManager") { TaskManagerWindow.show() }

        LaunchOptions().openTabs(in: controller)
    }

    /// Lets the native tab bar show its "+" button.
    @objc func newWindowForTab(_ sender: Any?) {
        controller.openTab()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { controller.openTab() }
        return true
    }
}

/// The appearance setting, applied to the app's windows and to the pages'
/// `prefers-color-scheme`.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    @MainActor func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
            CefProfile.default.setColorScheme(.system)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
            CefProfile.default.setColorScheme(.light)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            CefProfile.default.setColorScheme(.dark)
        }
    }
}

/// The Memory Saver setting: when tabs in the background are put to sleep.
enum MemorySaver: String, CaseIterable {
    case off, underPressure, after15Minutes, after1Hour

    static var current: MemorySaver {
        MemorySaver(rawValue: UserDefaults.standard.string(forKey: "memorySaver") ?? "") ?? .after1Hour
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .underPressure: "When Memory Is Low"
        case .after15Minutes: "After 15 Minutes in the Background"
        case .after1Hour: "After an Hour in the Background"
        }
    }

    @MainActor func apply() {
        TabDiscarding.shared.policy = switch self {
        case .off: .disabled
        case .underPressure: .init(discardsUnderMemoryPressure: true)
        case .after15Minutes: .init(hiddenDuration: .seconds(15 * 60), discardsUnderMemoryPressure: true)
        case .after1Hour: .init(hiddenDuration: .seconds(60 * 60), discardsUnderMemoryPressure: true)
        }
    }
}

struct BrowserCommands: Commands {
    let controller: BrowserController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About CefSwift Browser") { controller.openTab(url: BrowserPages.about) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { controller.openTab() }.keyboardShortcut("t")
            Button("New Private Tab") { controller.openTab(isPrivate: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Location…") { controller.focusAddressBar() }.keyboardShortcut("l")
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { controller.current?.execute(.find) }.keyboardShortcut("f")
        }
        // Into the system's View menu, beside its tab bar and full screen items.
        CommandGroup(before: .toolbar) {
            Button("Reload") {
                if let tab = controller.currentSystemTab { tab.browser.reload() } else { controller.current?.reload() }
            }
            .keyboardShortcut("r")
            Button("Reload Ignoring Cache") { controller.current?.reload(ignoringCache: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { controller.current?.zoomLevel += 0.5 }.keyboardShortcut("+")
            Button("Zoom Out") { controller.current?.zoomLevel -= 0.5 }.keyboardShortcut("-")
            Button("Actual Size") { controller.current?.zoomLevel = 0 }.keyboardShortcut("0")
            Divider()
            Button("Developer Tools") { controller.current?.execute(.showDevTools) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Open in WebKit") { controller.openCurrentTabInSystemEngine() }
                .help("Show this page with the system's WebKit, which plays FairPlay-protected video")
            Divider()
        }
        // Menu contents are views, so they follow the library as it changes.
        CommandMenu("History") { HistoryMenu(controller: controller) }
        CommandMenu("Bookmarks") { BookmarksMenu(controller: controller) }
        CommandGroup(before: .windowList) {
            Button("Task Manager") { TaskManagerWindow.show() }
            Divider()
        }
        CommandMenu("Browser") {
            Button("Extensions") { controller.openTab(url: URL(string: "chrome://extensions")!) }
            Button("Passwords") { controller.openTab(url: URL(string: "chrome://password-manager")!) }
            Button("Chromium Settings") { controller.openTab(url: URL(string: "chrome://settings")!) }
            Button("Flags") { controller.openTab(url: URL(string: "chrome://flags")!) }
            Divider()
            Button("Cast…") { controller.current?.execute(.castMedia) }
            Button("Version Details") { controller.openTab(url: URL(string: "chrome://version")!) }
            Divider()
            Button("Playground") { controller.openTab(url: BrowserPages.playground) }
        }
    }

    static func menuTitle(_ title: String, _ url: URL?) -> String {
        let text = title.isEmpty ? (url?.absoluteString ?? "Untitled") : title
        return text.count > 60 ? text.prefix(59) + "…" : text
    }
}

/// Back, Forward and the latest pages, re-read whenever the menu bar opens
/// (`BrowserLibrary`).
private struct HistoryMenu: View {
    let controller: BrowserController

    var body: some View {
        Button("Back") {
            if let tab = controller.currentSystemTab { tab.browser.goBack() } else { controller.current?.goBack() }
        }
        .keyboardShortcut("[")
        Button("Forward") {
            if let tab = controller.currentSystemTab { tab.browser.goForward() } else { controller.current?.goForward() }
        }
        .keyboardShortcut("]")
        Divider()
        ForEach(controller.library.recentHistory) { entry in
            Button(BrowserCommands.menuTitle(entry.title, entry.url)) { controller.openInFrontmostTab(entry.url) }
        }
        if !controller.library.recentHistory.isEmpty { Divider() }
        Button("Show All History") { controller.openTab(url: URL(string: "chrome://history")!) }.keyboardShortcut("y")
        Button("Downloads") { controller.openTab(url: URL(string: "chrome://downloads")!) }
    }
}

/// Add or remove the frontmost page's bookmark, then the bookmarks: the
/// bookmarks bar's contents first, the other folders as submenus.
private struct BookmarksMenu: View {
    let controller: BrowserController

    private var library: BrowserLibrary { controller.library }

    var body: some View {
        Button(library.isBookmarked(controller.current?.url) ? "Remove Bookmark" : "Add Bookmark") {
            if let browser = controller.current { library.toggleBookmark(for: browser) }
        }
        .keyboardShortcut("d")
        .disabled(!BrowserLibrary.canBookmark(controller.current?.url))
        Button("Show All Bookmarks") { controller.openTab(url: URL(string: "chrome://bookmarks")!) }
            .keyboardShortcut("b", modifiers: [.command, .option])
        let bar = library.bookmarkTree.first { $0.permanentFolder == .bookmarksBar }?.children ?? []
        if !bar.isEmpty { Divider() }
        ForEach(bar) { BookmarkMenuItem(bookmark: $0, open: controller.openInFrontmostTab) }
        let folders = library.bookmarkTree.filter { $0.permanentFolder != .bookmarksBar && !($0.children ?? []).isEmpty }
        if !folders.isEmpty { Divider() }
        ForEach(folders) { BookmarkMenuItem(bookmark: $0, open: controller.openInFrontmostTab) }
    }
}

/// A bookmark as a menu item, or a folder as a submenu.
private struct BookmarkMenuItem: View {
    let bookmark: CefBookmark
    let open: (URL) -> Void

    var body: some View {
        if let url = bookmark.url {
            Button(BrowserCommands.menuTitle(bookmark.title, url)) { open(url) }
        } else {
            Menu(bookmark.title.isEmpty ? "Untitled Folder" : bookmark.title) {
                ForEach(bookmark.children ?? []) { BookmarkMenuItem(bookmark: $0, open: open) }
                if (bookmark.children ?? []).isEmpty { Text("Empty") }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("newTabPage") private var newTabPage = BrowserController.defaultNewTabPage
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage(ChromiumPanels.customPanelsKey) private var customPanels = false
    @AppStorage("memorySaver") private var discardPolicy = MemorySaver.current.rawValue
    @AppStorage(SystemEngineTab.automaticKey) private var streamingInSystemEngine = true

    var body: some View {
        Form {
            TextField("New tabs open", text: $newTabPage, prompt: Text(BrowserController.defaultNewTabPage))
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(Appearance.system.rawValue)
                Text("Light").tag(Appearance.light.rawValue)
                Text("Dark").tag(Appearance.dark.rawValue)
            }
            .onChange(of: appearance) { Appearance.current.apply() }
            Toggle("Use the browser's QR code and Cast panels", isOn: $customPanels)
                .help("Applies to tabs opened from now on. Off: Chromium's own bubbles.")
            Picker(selection: $discardPolicy) {
                ForEach(MemorySaver.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            } label: {
                Text("Put tabs to sleep")
                Text("Sleeping tabs free their memory and reload when you return to them.")
            }
            .onChange(of: discardPolicy) { MemorySaver.current.apply() }
            Toggle(isOn: $streamingInSystemEngine) {
                Text("Play streaming services with WebKit")
                Text("Netflix, Disney+ and other services that need FairPlay open in a tab shown by the system's WebKit.")
            }
            PasskeySettings()
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
