import AppKit
import CefKit
import CefSwiftUI
import SwiftUI

/// CefSwift Launcher — a single SwiftUI app you open once, then launch each
/// hosting mode / configuration demo one at a time to try them out.
///
/// It coexists with the `Browser` and `Gallery` example products and uses the
/// same one-line CEF bootstrap (``CefSwiftApp``). Each catalog entry opens its
/// own window (repeatable, closable); the Chrome-runtime entry opens a full
/// CEF-owned chrome window via ``LauncherChromeController``.
@main
struct LauncherApp: CefSwiftApp {

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.cachePath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rajaniraiyn.cefswift.launcher/Cache", isDirectory: true)
        config.persistSessionCookies = true
        // The OSR / Metal, Incognito, Persistent, and Popups demos use
        // CefMetalWebView (offscreen rendering), which requires this.
        config.windowlessRenderingEnabled = true
        config.customSchemes = [CefCustomScheme(name: "launcher")]
        return config
    }

    @State private var chrome = LauncherChromeController()

    var body: some Scene {
        // The launcher catalog window.
        WindowGroup("CefSwift Launcher", id: "launcher") {
            LauncherView()
                .environment(chrome)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    LauncherDemoPage.registerSchemeHandler()
                    // Test hook: auto-open a demo by id (e.g. for screenshots).
                    if let id = ProcessInfo.processInfo.environment["CEFSWIFT_AUTOLAUNCH"],
                       let demo = LauncherDemo.catalog.first(where: { $0.id == id }),
                       case .chromeRuntime(let url) = demo.kind {
                        chrome.open(url: url)
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 560)

        // A reusable embedded-demo window opened per catalog entry. SwiftUI
        // can open multiple instances (one per distinct demo id), each closable.
        WindowGroup("CefSwift Demo", id: "demo", for: LauncherDemo.ID.self) { $demoID in
            if let demoID, let demo = LauncherDemo.catalog.first(where: { $0.id == demoID }) {
                DemoWindow(demo: demo)
                    .navigationTitle(demo.title)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 720)
    }
}
