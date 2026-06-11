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
        argumentURL(after: "--open-url")
    }

    /// `--open-chrome-url <url>`: open a chrome-style window (CefChromeBrowser,
    /// toolbar hidden) at launch — scripted verification of chrome:// WebUI.
    private static var launchChromeURL: URL? {
        argumentURL(after: "--open-chrome-url")
    }

    /// `--open-embedded-chrome-url <url>`: open an *embedded* chrome-style tab
    /// (CefChromeWebView child-window overlay) at launch.
    private static var launchEmbeddedChromeURL: URL? {
        argumentURL(after: "--open-embedded-chrome-url")
    }

    private static func argumentURL(after flag: String) -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return URL(string: arguments[index + 1])
    }

    /// Opens `url` in a standalone chrome-style window: full Chrome runtime
    /// (history/extensions/settings WebUI render), Chrome's own toolbar hidden.
    private func openChromeWindow(_ url: URL) {
        var options = CefChromeBrowserOptions()
        options.showsChromeToolbar = false
        CefChromeBrowser.create(url: url, options: options)
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
                    if let url = Self.launchChromeURL {
                        openChromeWindow(url)
                    }
                    if let url = Self.launchEmbeddedChromeURL {
                        store.newTab(url: url, kind: .chromeEmbedded)
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
                // Re-opens the current page in a CEF Views window running the
                // real Chrome runtime style (toolbar hidden) — the hosting
                // mode where chrome://history & co. actually render.
                Button("Open in Chrome Window") {
                    openChromeWindow(store.selectedTab?.model.url ?? TabStore.homeURL)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Embedded Chrome Tab (Experimental)") {
                    store.newTab(url: URL(string: "chrome://history")!, kind: .chromeEmbedded)
                }
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
                Menu("Chrome-Style Window") {
                    // These WebUI pages need a Chrome-style *window* to render
                    // (they load but stay blank in NSView-embedded tabs), so
                    // they open as CefChromeBrowser windows where they work.
                    Button("History") { openChromeWindow(URL(string: "chrome://history")!) }
                    Button("Extensions") { openChromeWindow(URL(string: "chrome://extensions")!) }
                    Button("Settings") { openChromeWindow(URL(string: "chrome://settings")!) }
                    Button("Downloads") { openChromeWindow(URL(string: "chrome://downloads")!) }
                    Button("Flags") { openChromeWindow(URL(string: "chrome://flags")!) }
                }
                Divider()
                Button("Toggle DevTools") { store.selectedTab?.model.browser?.showDevTools() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
