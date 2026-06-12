import AppKit
import CefKit
import CefSwiftUI
import SwiftUI

/// Arc-class mini browser built on CefSwift's **full-browser hosting mode**
/// (``CefChromeWindow`` — inverted ownership).
///
/// The real browser window is a CEF-owned Chrome-runtime window whose native
/// SwiftUI chrome (tab strip + omnibox) is hosted as an overlay on top, with
/// web content inset below. Because it's the full Chrome runtime, the WebUI
/// pages that render blank in NSView-embedded (Alloy) views — `chrome://history`,
/// `chrome://extensions`, `chrome://settings`, `chrome://downloads`,
/// `chrome://flags` — all render here, opened as tabs from the Chrome menu.
///
/// App model: CEF owns the browser window, so it lives *outside* SwiftUI's
/// `Scene` graph. A tiny hidden placeholder `WindowGroup` keeps the app alive
/// and bootstraps the chrome window on launch via ``BrowserShell``.
@main
struct BrowserApp: CefSwiftApp {

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.cachePath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rajaniraiyn.cefswift.browser/BrowserCache", isDirectory: true)
        config.persistSessionCookies = true
        if ProcessInfo.processInfo.environment["CEFSWIFT_ENABLE_SANDBOX"] == "1" {
            config.noSandbox = false
        }
        return config
    }

    /// `--open-url <url>`: load this address in the first tab at launch.
    private static var launchURL: URL? { argumentURL(after: "--open-url") }

    private static func argumentURL(after flag: String) -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return URL(string: args[i + 1])
    }

    @State private var shell = BrowserShell()

    var body: some Scene {
        WindowGroup {
            // The CEF-owned chrome window is the real browser UI; this scene is
            // a near-invisible placeholder that owns the app lifecycle and
            // bootstraps the window once the runtime is up.
            PlaceholderScene(shell: shell)
                .task {
                    if SmokeTest.isRequested {
                        SmokeTest.run(shell: shell)
                        return
                    }
                    shell.openWindow(initialURL: Self.launchURL ?? BrowserShell.homeURL)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { shell.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { shell.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Open Location…") { shell.requestOmniboxFocus() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") { shell.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Chrome internals. Because the browser runs the full Chrome
            // runtime (inverted-ownership window), *all* of these render here —
            // including history/extensions/settings/downloads/flags, which are
            // blank in NSView-embedded (Alloy) tabs. They open as tabs of the
            // chrome window.
            CommandMenu("Chrome") {
                Button("History") { shell.openChromePage("chrome://history") }
                Button("Extensions") { shell.openChromePage("chrome://extensions") }
                Button("Settings") { shell.openChromePage("chrome://settings") }
                Button("Downloads") { shell.openChromePage("chrome://downloads") }
                Button("Flags") { shell.openChromePage("chrome://flags") }
                Divider()
                Button("Version") { shell.openChromePage("chrome://version") }
                Button("GPU Internals") { shell.openChromePage("chrome://gpu") }
                Button("All Chrome URLs") { shell.openChromePage("chrome://about") }
                Divider()
                Button("Toggle DevTools") { shell.showDevTools() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

/// Near-invisible SwiftUI scene. The actual browser is the CEF-owned chrome
/// window opened by ``BrowserShell``; this just anchors the app lifecycle.
private struct PlaceholderScene: View {
    let shell: BrowserShell

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                // Hide the placeholder window chrome; the CEF window is the UI.
                if let win = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) {
                    win.orderOut(nil)
                }
            }
    }
}
