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
        return configuration
    }

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Browser windows are created by BrowserController, not by a scene.
        Settings { SettingsView() }
            .commands { BrowserCommands(controller: appDelegate.controller) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BrowserController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.adoptWindowsOpenedByChromium()
        controller.openTab()
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

struct BrowserCommands: Commands {
    let controller: BrowserController

    var body: some Commands {
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
            Button("Developer Tools") { controller.current?.execute(.devTools) }
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
            Button("About") { controller.openTab(url: URL(string: "chrome://version")!) }
        }
    }
}

struct SettingsView: View {
    @AppStorage("homePage") private var homePage = BrowserController.defaultHomePage
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Form {
            TextField("Home page", text: $homePage)
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .onChange(of: appearance) { _, value in
                CefProfile.default.setColorScheme(value == "dark" ? .dark : value == "light" ? .light : .system)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
