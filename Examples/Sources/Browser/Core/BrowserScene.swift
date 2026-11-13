import AppKit
import CefSwiftUI
import SwiftUI

extension CefRuntime.Configuration {
    /// The browser's Chromium: Chrome's runtime, under the browser's name.
    static var browser: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.chrome
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
}

/// The browser's scenes: its Settings window, and its commands in the menu
/// bar. Browser windows are opened by ``BrowserController``, not by a scene.
struct BrowserScene<Features: BrowserFeature>: Scene {
    let features: Features
    let controller: BrowserController

    var body: some Scene {
        Settings {
            Form {
                NewTabPageSetting()
                features.settings
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .fixedSize()
            .environment(controller)
        }
        .commands {
            // File › New Tab first: the features' File items follow it.
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { controller.openTab() }.keyboardShortcut("t")
            }
            features.commands(for: controller)
            // Groups placed before the same item stack up in reverse, so
            // declared last, these lead the View menu.
            PageCommands(controller: controller)
        }
        // SwiftUI would open Settings at launch, it being the only scene.
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The View menu's commands for the frontmost page: reloading, zoom and
/// DevTools.
struct PageCommands: Commands {
    let controller: BrowserController

    var body: some Commands {
        // Into the system's View menu, beside its tab bar and full screen items.
        CommandGroup(before: .toolbar) {
            Button("Reload") { controller.frontmostPage?.reload(ignoringCache: false) }
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
        }
    }
}

/// Settings: where new tabs open.
private struct NewTabPageSetting: View {
    @AppStorage(BrowserController.newTabPageKey) private var newTabPage = ""
    @Environment(BrowserController.self) private var controller

    var body: some View {
        TextField(
            "New tabs open", text: $newTabPage,
            prompt: Text(controller.startPage?.absoluteString ?? "about:blank"))
    }
}

extension String {
    /// A page's title as a menu item shows it: its address when it has no
    /// title, and shortened past 60 characters.
    init(menuTitle title: String, url: URL?) {
        let text = title.isEmpty ? (url?.absoluteString ?? "Untitled") : title
        self = text.count > 60 ? text.prefix(59) + "…" : text
    }
}
