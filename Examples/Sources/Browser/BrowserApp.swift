import SwiftUI
import CefKit
import CefSwiftUI

/// Arc-class mini browser built on CefSwift.
///
/// Demonstrates: `CefSwiftApp` bootstrap, the Chrome bootstrap's diagnostic
/// chrome:// pages (version, gpu, net-internals, …), a vertical Arc-style tab
/// sidebar, an omnibox with search fallback, popup-to-new-tab handling, and DevTools.
@main
struct BrowserApp: CefSwiftApp {

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        // Note: browsers embedded into a parent NSView always use Alloy *style*
        // (a CEF constraint); the Chrome *bootstrap* underneath is still active,
        // so leave `defaultRuntimeStyle` at `.default` and let CEF pick.
        // Keep this browser's profile separate from other CefSwift apps.
        config.cachePath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rajaniraiyn.cefswift.browser/BrowserCache", isDirectory: true)
        config.persistSessionCookies = true
        // safeStorage defaults to .automatic: dev (ad-hoc-signed) builds skip
        // the keychain "Chromium Safe Storage" prompt; signed builds use the
        // real keychain like Chrome (one-time "Always Allow").
        // Uncomment to attach Chrome DevTools from another browser at http://localhost:9222
        // config.remoteDebuggingPort = 9222
        // Dev hook: CEFSWIFT_ENABLE_SANDBOX=1 flips on the Chromium macOS
        // sandbox (helpers seal themselves via libcef_sandbox.dylib before
        // loading CEF). Kept as an env var because sandboxed operation needs
        // a properly signed bundle — see docs/sandbox.md.
        if ProcessInfo.processInfo.environment["CEFSWIFT_ENABLE_SANDBOX"] == "1" {
            config.noSandbox = false
        }
        return config
    }

    /// `--open-url <url>`: navigate the initial tab at launch (handy for
    /// scripted testing, e.g. verifying chrome:// pages).
    private static var launchURL: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open-url"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return URL(string: arguments[index + 1])
    }

    @State private var store = TabStore()

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    // --cef-smoke-test: CI hook, see SmokeTest.swift.
                    SmokeTest.runIfRequested(store: store)
                    if let url = Self.launchURL {
                        store.newTab(url: url)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { store.closeSelectedTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Open Location…") { store.requestOmniboxFocus() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Reload Page") { store.selectedTab?.model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Chrome internals — these pages exist because we run the Chrome
            // bootstrap. Only pages verified to render in *embedded* browser
            // views are listed (NSView-embedded browsers are always Alloy
            // *style*, so WebUI that needs a tabbed Chrome window — history,
            // extensions, settings, downloads, flags — loads but renders a
            // blank page; see docs/chrome-style.md).
            CommandMenu("Chrome") {
                Button("Version") { store.newTab(url: URL(string: "chrome://version")!) }
                Button("GPU Internals") { store.newTab(url: URL(string: "chrome://gpu")!) }
                Button("Process Internals") { store.newTab(url: URL(string: "chrome://process-internals")!) }
                Button("Network Internals") { store.newTab(url: URL(string: "chrome://net-internals")!) }
                Button("Network Log Export") { store.newTab(url: URL(string: "chrome://net-export")!) }
                Button("All Chrome URLs") { store.newTab(url: URL(string: "chrome://about")!) }
                Divider()
                Menu("Needs Chrome-Style Window") {
                    // Kept for documentation: enabled so you can see the blank
                    // render yourself, but expect no content in embedded views.
                    Button("History (blank when embedded)") { store.newTab(url: URL(string: "chrome://history")!) }
                    Button("Extensions (blank when embedded)") { store.newTab(url: URL(string: "chrome://extensions")!) }
                    Button("Settings (blank when embedded)") { store.newTab(url: URL(string: "chrome://settings")!) }
                    Button("Downloads (blank when embedded)") { store.newTab(url: URL(string: "chrome://downloads")!) }
                }
                Divider()
                Button("Toggle DevTools") { store.selectedTab?.model.browser?.showDevTools() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
