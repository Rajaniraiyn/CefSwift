import SwiftUI
import CefKit
import CefSwiftUI

/// Arc-class mini browser built on CefSwift.
///
/// Demonstrates: `CefSwiftApp` bootstrap, chrome runtime style (real Chrome UI features:
/// chrome://history, chrome://extensions, chrome://settings), a vertical Arc-style tab
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
        return config
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
            // Chrome internals — these pages exist because we run chrome runtime style.
            CommandMenu("Chrome") {
                Button("History") { store.newTab(url: URL(string: "chrome://history")!) }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Extensions") { store.newTab(url: URL(string: "chrome://extensions")!) }
                Button("Settings") { store.newTab(url: URL(string: "chrome://settings")!) }
                Button("Version") { store.newTab(url: URL(string: "chrome://version")!) }
                Divider()
                Button("Toggle DevTools") { store.selectedTab?.model.browser?.showDevTools() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
