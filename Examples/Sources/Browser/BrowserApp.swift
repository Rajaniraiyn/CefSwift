import AppKit
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
    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration.browser
        configuration.productName = "CefSwift Browser"
        // Chrome's own UI is replaced by the SwiftUI toolbar; keep its
        // internal pages free of buttons that would open Chrome windows.
        configuration.chromeUI.hiddenAppMenuCommands = [.newWindow, .newIncognitoWindow]
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

        let launch = LaunchOptions()
        let urls = launch.urls.isEmpty ? [nil] : launch.urls.map(Optional.some)
        if launch.benchmarks { reportFirstLoadAndQuitWhenInputCloses() }
        let browsers = urls.map { controller.openTab(url: $0, isPrivate: launch.opensPrivateTabs) }
        if let browser = browsers.last, launch.script != nil || launch.focusesAddressBar {
            Task {
                await controller.waitUntilLoaded(browser)
                if let script = launch.script { _ = try? await browser.evaluateJavaScript(script) }
                if launch.focusesAddressBar {
                    // Focus goes to the key window, so wait for the app to be active.
                    // Chromium focuses the page as the window becomes key.
                    while !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .milliseconds(500))
                    controller.focusAddressBar()
                    if let text = launch.addressBarText {
                        try? await Task.sleep(for: .milliseconds(200))
                        // Typed into the field editor, as the keyboard would.
                        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                        editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange())
                    }
                }
            }
        }
    }

    /// `-benchmark YES`: prints `cefswift-benchmark loaded <seconds since
    /// 1970>` when a page first finishes loading, and quits when standard
    /// input closes. `Scripts/measure-footprint.py` drives it.
    private func reportFirstLoadAndQuitWhenInputCloses() {
        controller.onPageLoad = { [controller] _ in
            print("cefswift-benchmark loaded \(Date().timeIntervalSince1970)")
            fflush(stdout)
            controller.onPageLoad = nil
        }
        Thread.detachNewThread {
            while readLine() != nil {}
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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

/// Launch arguments, for opening the browser in a given state — handy for
/// trying things out and for automated screenshots:
///
/// - `-urls "https://a.example browser://playground/"` opens each as a tab.
/// - `-evaluate "openPopup()"` runs JavaScript in the last tab once loaded
///   (a script starting with `(` would be read as a list; prefix `void `).
/// - `-focusAddressBar YES` starts with the address field editing.
/// - `-addressBarText swift` starts editing with that text typed, which
///   shows its suggestions.
/// - `-private YES` opens the tabs as private tabs.
/// - `-appearance dark` (or `light`, `system`) overrides the setting.
/// - `-cacheDirectory <path>` keeps Chromium's data there.
/// - `-benchmark YES` reports the first finished load and quits when
///   standard input closes, for `Scripts/measure-footprint.py`.
@MainActor
struct LaunchOptions {
    var urls: [URL] = []
    var script: String?
    var focusesAddressBar = false
    var addressBarText: String?
    var opensPrivateTabs = false
    var benchmarks = false

    init(defaults: UserDefaults = .standard) {
        urls = (defaults.string(forKey: "urls") ?? "")
            .split(separator: " ")
            .compactMap { AddressBar.destination(for: String($0)) }
        script = defaults.string(forKey: "evaluate")
        addressBarText = defaults.string(forKey: "addressBarText")
        opensPrivateTabs = defaults.bool(forKey: "private")
        benchmarks = defaults.bool(forKey: "benchmark")
        focusesAddressBar = defaults.bool(forKey: "focusAddressBar") || addressBarText != nil
    }

    /// A URL from a command-line argument: an address with a scheme, or a
    /// file path. Switches and anything else give `nil`.
    static func url(fromArgument argument: String, relativeTo directory: URL?) -> URL? {
        guard !argument.hasPrefix("-") else { return nil }
        if argument.contains(":"), let url = URL(string: argument), url.scheme != nil { return url }
        let file = URL(fileURLWithPath: argument, relativeTo: directory).absoluteURL
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
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
        CefRuntime.shared.memorySaver = switch self {
        case .off: .off
        case .underPressure: .underMemoryPressure
        case .after15Minutes: .after(.seconds(15 * 60))
        case .after1Hour: .after(.seconds(60 * 60))
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
            Button("Reload") { controller.current?.reload() }.keyboardShortcut("r")
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
        }
        // Menu contents are views, so they follow the library as it changes.
        CommandMenu("History") { HistoryMenu(controller: controller) }
        CommandMenu("Bookmarks") { BookmarksMenu(controller: controller) }
        CommandMenu("Browser") {
            Button("Extensions") { controller.openTab(url: URL(string: "chrome://extensions")!) }
            Button("Passwords") { controller.openTab(url: URL(string: "chrome://password-manager")!) }
            Button("Chromium Settings") { controller.openTab(url: URL(string: "chrome://settings")!) }
            Button("Flags") { controller.openTab(url: URL(string: "chrome://flags")!) }
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
        Button("Back") { controller.current?.goBack() }.keyboardShortcut("[")
        Button("Forward") { controller.current?.goForward() }.keyboardShortcut("]")
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
    @AppStorage("memorySaver") private var memorySaver = MemorySaver.current.rawValue

    var body: some View {
        Form {
            TextField("New tabs open", text: $newTabPage, prompt: Text(BrowserController.defaultNewTabPage))
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(Appearance.system.rawValue)
                Text("Light").tag(Appearance.light.rawValue)
                Text("Dark").tag(Appearance.dark.rawValue)
            }
            .onChange(of: appearance) { Appearance.current.apply() }
            Picker(selection: $memorySaver) {
                ForEach(MemorySaver.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            } label: {
                Text("Put tabs to sleep")
                Text("Sleeping tabs free their memory and reload when you return to them.")
            }
            .onChange(of: memorySaver) { MemorySaver.current.apply() }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
