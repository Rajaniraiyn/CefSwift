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
/// - `-cacheDirectory <path>` keeps Chromium's data there
///   (`CefRuntime.Configuration.browser`).
/// - `-benchmark YES` reports the first finished load and quits when
///   standard input closes, for `Scripts/measure-footprint.py`.
///
/// Features read their own: `-appearance` (Appearance), `-showTaskManager`
/// (TaskManager), `-showPageInfo` (PageInfo) and `-customChromiumPanels`
/// (ChromiumPanels).
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
            .compactMap { TypedAddress.destination(for: String($0)) }
        script = defaults.string(forKey: "evaluate")
        addressBarText = defaults.string(forKey: "addressBarText")
        opensPrivateTabs = defaults.bool(forKey: "private")
        benchmarks = defaults.bool(forKey: "benchmark")
        focusesAddressBar = defaults.bool(forKey: "focusAddressBar") || addressBarText != nil
    }

    /// Opens the tabs the options ask for, or one on the new tab page, and
    /// does what they ask in the last.
    func openTabs(in controller: BrowserController) {
        let urls = urls.isEmpty ? [nil] : urls.map(Optional.some)
        if benchmarks { Benchmark.reportFirstLoadAndQuitWhenInputCloses(controller) }
        let browsers = urls.map { controller.openTab(url: $0, isPrivate: opensPrivateTabs) }
        if let browser = browsers.last, script != nil || focusesAddressBar {
            Task {
                _ = try? await browser.waitUntilLoaded(timeout: .seconds(10))
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

    /// The `use` benchmark command (`Scripts/measure-services.py`): types
    /// into the address field, presses ⌘D to bookmark the page and opens
    /// the menu bar, as a person trying the browser would, then prints
    /// `cefswift-benchmark used`.
    private static func useLikeAPerson(_ controller: BrowserController) {
        Task {
            NSApp.activate()
            controller.focusAddressBar()
            try? await Task.sleep(for: .milliseconds(300))
            for character in "swi" {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .milliseconds(150))
            }
            chooseMenuItem(withShortcut: "d")
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
            try? await Task.sleep(for: .seconds(1))
            print("cefswift-benchmark used")
            fflush(stdout)
        }
    }

    /// Chooses the enabled menu bar item whose shortcut is ⌘`key`, as a
    /// person pressing it would, so the benchmark needs to know nothing of
    /// the features. SwiftUI brings a menu's items up to date when the menu
    /// is about to show, so each menu is asked to first. Returns whether
    /// there is such an item.
    @discardableResult
    private static func chooseMenuItem(withShortcut key: String, in menu: NSMenu? = NSApp.mainMenu) -> Bool {
        guard let menu else { return false }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command, item.isEnabled {
                menu.performActionForItem(at: index)
                return true
            }
            if chooseMenuItem(withShortcut: key, in: item.submenu) { return true }
        }
        return false
    }
}
