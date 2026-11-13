import AppKit
import CefSwiftUI

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

    /// Opens the tabs the options ask for, or one on the start page, and
    /// does what they ask in the last.
    func openTabs(in controller: BrowserController) {
        let urls = urls.isEmpty ? [nil] : urls.map(Optional.some)
        if benchmarks { Benchmark.reportFirstLoadAndQuitWhenInputCloses(controller) }
        let browsers = urls.map { controller.openTab(url: $0, isPrivate: opensPrivateTabs) }
        if let browser = browsers.last, script != nil || focusesAddressBar {
            Task {
                await controller.waitUntilLoaded(browser)
                if let script { _ = try? await browser.evaluateJavaScript(script, userGesture: true) }
                if focusesAddressBar {
                    // Focus goes to the key window, so wait for the app to be active.
                    // Chromium focuses the page as the window becomes key.
                    while !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .milliseconds(500))
                    controller.focusAddressBar()
                    if let text = addressBarText {
                        try? await Task.sleep(for: .milliseconds(200))
                        // Typed into the field editor, as the keyboard would.
                        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                        editor?.insertText(text, replacementRange: editor?.selectedRange() ?? NSRange())
                    }
                }
            }
        }
    }
}

/// `-benchmark YES`, for the footprint scripts.
@MainActor
enum Benchmark {
    /// Prints `cefswift-benchmark loaded <seconds since
    /// 1970>` when a page first finishes loading, and quits when standard
    /// input closes. `Scripts/measure-footprint.py` drives it.
    static func reportFirstLoadAndQuitWhenInputCloses(_ controller: BrowserController) {
        controller.onPageLoad = { [controller] _ in
            print("cefswift-benchmark loaded \(Date().timeIntervalSince1970)")
            fflush(stdout)
            controller.onPageLoad = nil
        }
        Thread.detachNewThread {
            while let line = readLine() {
                if line == "use" { DispatchQueue.main.async { MainActor.assumeIsolated { useLikeAPerson(controller) } } }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// The `use` benchmark command: types into the address field, bookmarks
    /// the page and opens the menu bar, as a person trying the browser
    /// would, then prints `cefswift-benchmark used`.
    private static func useLikeAPerson(_ controller: BrowserController) {
        Task {
            NSApp.activate()
            controller.focusAddressBar()
            try? await Task.sleep(for: .milliseconds(300))
            for character in "swi" {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(150))
            }
            if let browser = controller.current { controller.library.toggleBookmark(for: browser) }
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
            try? await Task.sleep(for: .seconds(1))
            print("cefswift-benchmark used")
            fflush(stdout)
        }
    }
}
