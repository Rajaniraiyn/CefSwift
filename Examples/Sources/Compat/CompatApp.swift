import AppKit
@_spi(Testing) import CefKit

/// Shows one page in one kind of host with one set of CefSwift features
/// turned on, for the web-compatibility matrix (`Scripts/compat-matrix.py`).
///
/// Launch arguments (read as user defaults):
///
/// - `-url <address>`: the page.
/// - `-host window|windowed|offscreen`: a Chrome-style `CefBrowserWindow`,
///   or a `CefWebView`-style view (Alloy), windowed or offscreen.
/// - `-preset default|browser|embedded`: the `CefRuntime.Configuration` preset.
/// - `-features <name>,<name>`: `devtools` (a DevTools session with no
///   domain enabled), `runtime` (`Runtime.enable`), `page` (`Page.enable`),
///   `bridge`, `userscript`, `evaluate` (one `evaluateJavaScript` as the
///   page loads), `passkeys` (app-answered passkeys), `accessibility`
///   (offscreen accessibility tree from the start).
/// - `-wait <seconds>`: how long to show the page (default 12).
/// - `-capture <path.png>`: where to save a screenshot of the window, taken
///   with `screencapture` from outside the page, when the time is up.
/// - `-cacheDirectory <path>`: Chromium's data directory.
///
/// It prints `compat window <number>` once the window is up and
/// `compat done` before quitting.
@main
@MainActor
enum CompatApp {
    static let defaults = UserDefaults.standard
    static var window: NSWindow?
    static var browserWindow: CefBrowserWindow?
    static var browser: CefBrowser!
    static let bridge = CefBridge(name: "compatBridge")

    static var features: Set<String> {
        Set((defaults.string(forKey: "features") ?? "").split(separator: ",").map(String.init))
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        CefApplication.install()
        var configuration: CefRuntime.Configuration
        switch defaults.string(forKey: "preset") {
        case "browser": configuration = .browser
        case "embedded": configuration = .embedded
        default: configuration = CefRuntime.Configuration()
        }
        configuration.isOffscreenRenderingEnabled = defaults.string(forKey: "host") == "offscreen"
        if let path = defaults.string(forKey: "cacheDirectory") {
            configuration.rootCacheDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        configuration.preferences["browser.confirm_to_quit"] = false
        do {
            try CefRuntime.shared.initialize(configuration: configuration)
        } catch {
            print("compat failed: \(error)")
            exit(1)
        }

        let url = URL(string: defaults.string(forKey: "url") ?? "about:blank")!
        var browserConfiguration = CefBrowser.Configuration()
        if features.contains("bridge") {
            bridge.handle("ping") { (_: CefJSON) in "pong" }
            browserConfiguration.bridges = [bridge]
        }
        if features.contains("userscript") {
            browserConfiguration.userScripts = [CefUserScript(source: "addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.compat = '1'; });")]
        }
        if features.contains("passkeys") {
            browserConfiguration.passkeys = .app(CefInMemoryPasskeyStore())
        }
        if features.contains("accessibility") {
            browserConfiguration.offscreenAccessibility = .enabled
        }

        let frame = NSRect(x: 60, y: 60, width: 1280, height: 900)
        switch defaults.string(forKey: "host") ?? "window" {
        case "windowed", "offscreen":
            let offscreen = defaults.string(forKey: "host") == "offscreen"
            if offscreen { browserConfiguration.rendering = .offscreen }
            browser = CefBrowser(url: url, configuration: browserConfiguration, delegate: CompatDelegate.shared)
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Compat"
            let view: NSView
            if offscreen {
                let offscreenView = CefOffscreenBrowserView(browser: browser)
                view = offscreenView
            } else {
                let windowedView = CefWindowedBrowserView(browser: browser)
                view = windowedView
            }
            view.frame = window.contentView!.bounds
            view.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(view)
            if offscreen { window.makeFirstResponder(view) }
            window.makeKeyAndOrderFront(nil)
            self.window = window
        default:
            browser = CefBrowser(url: url, configuration: browserConfiguration, delegate: CompatDelegate.shared)
            var windowConfiguration = CefBrowserWindow.Configuration()
            windowConfiguration.frame = frame
            let browserWindow = CefBrowserWindow(browser: browser, configuration: windowConfiguration)
            browserWindow.show()
            self.browserWindow = browserWindow
        }
        NSApp.activate()

        Task { await run() }
        NSApp.run()
    }

    static func run() async {
        let features = features
        try? await browser.ready()
        if features.contains("devtools") {
            _ = try? await browser.devTools.send("Browser.getVersion")
        }
        if features.contains("runtime") {
            _ = try? await browser.devTools.send("Runtime.enable")
        }
        if features.contains("page") {
            _ = try? await browser.devTools.send("Page.enable")
        }
        if features.contains("evaluate") {
            // A page that keeps its renderer busy must not hold up the reading.
            _ = try? await browser.evaluateJavaScript("1 + 1", timeout: .seconds(10))
        }
        // The window number, for a screenshot from outside the app.
        for _ in 0..<100 {
            if let number = (window ?? browserWindow?.window)?.windowNumber, number > 0 {
                print("compat window \(number)")
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let wait = defaults.double(forKey: "wait")
        try? await Task.sleep(for: .seconds(wait > 0 ? wait : 12))
        if let path = defaults.string(forKey: "capture"),
           let number = (window ?? browserWindow?.window)?.windowNumber {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(number), path]
            try? capture.run()
            capture.waitUntilExit()
        }
        print("compat done")
        browser.close(force: true)
        browserWindow?.close()
        window?.close()
        NSApp.terminate(nil)
        // Chromium may wait on pages; never linger.
        try? await Task.sleep(for: .seconds(15))
        exit(0)
    }
}

/// Reports renderer crashes, which would spoil a reading.
@MainActor
final class CompatDelegate: CefBrowserDelegate {
    static let shared = CompatDelegate()

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        print("compat renderer terminated: \(reason)")
    }
}
