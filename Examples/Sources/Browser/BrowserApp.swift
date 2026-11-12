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
        controller.adoptTabsOpenedByChromium()

        let launch = LaunchOptions()
        let urls = launch.urls.isEmpty ? [nil] : launch.urls.map(Optional.some)
        let browsers = urls.map { controller.openTab(url: $0) }
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
                }
            }
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
/// - `-appearance dark` (or `light`, `system`) overrides the setting.
@MainActor
struct LaunchOptions {
    var urls: [URL] = []
    var script: String?
    var focusesAddressBar = false

    init(defaults: UserDefaults = .standard) {
        urls = (defaults.string(forKey: "urls") ?? "")
            .split(separator: " ")
            .compactMap { AddressBar.destination(for: String($0)) }
        script = defaults.string(forKey: "evaluate")
        focusesAddressBar = defaults.bool(forKey: "focusAddressBar")
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
        CommandMenu("View") {
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
        }
        CommandMenu("History") {
            Button("Back") { controller.current?.goBack() }.keyboardShortcut("[")
            Button("Forward") { controller.current?.goForward() }.keyboardShortcut("]")
            Divider()
            Button("Show History") { controller.openTab(url: URL(string: "chrome://history")!) }.keyboardShortcut("y")
            Button("Downloads") { controller.openTab(url: URL(string: "chrome://downloads")!) }
        }
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
}

struct SettingsView: View {
    @AppStorage("homePage") private var homePage = BrowserController.defaultHomePage
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        Form {
            TextField("Home page", text: $homePage)
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(Appearance.system.rawValue)
                Text("Light").tag(Appearance.light.rawValue)
                Text("Dark").tag(Appearance.dark.rawValue)
            }
            .onChange(of: appearance) { Appearance.current.apply() }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
