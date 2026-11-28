# Starter: a browser in five files

`Package.swift`, `cefapp.json` and three Swift files. They compile against
CefSwift 0.2 and bundle into an app whose Chromium windows carry your own
tab strip and toolbar. Replace `MyBrowser` with the app's name everywhere
(target, folder, struct, `cefapp.json`).

```sh
mkdir -p MyBrowser/Sources/MyBrowser && cd MyBrowser
printf '.build/\n.cef/\ndist/\n' > .gitignore
```

## Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyBrowser",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Rajaniraiyn/CefSwift", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .executableTarget(
            name: "MyBrowser",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
                .product(name: "CefChromium", package: "CefSwift"),
            ],
            exclude: ["cefapp.json"]
        ),
    ]
)
```

## Sources/MyBrowser/cefapp.json

```json
// Settings for `swift package cef bundle --product MyBrowser`.
{
  "bundleIdentifier": "com.example.mybrowser",
  "displayName": "MyBrowser",
  "minimumSystemVersion": "15.0",
  "capabilities": ["camera", "microphone", "location", "defaultBrowser"],
  "usageDescriptions": {
    "camera": "Websites you allow can use the camera.",
    "microphone": "Websites you allow can use the microphone.",
    "location": "Websites you allow can see your approximate location.",
  },
  // Users pick Chromium's interface language: keep every locale pack.
  "cef": { "localizations": "all" },
}
```

## Sources/MyBrowser/MyBrowserApp.swift

The app: Chromium's `.chrome` runtime, no window scene of its own (browser windows are Chromium's), the menu commands.

```swift
// Sources/MyBrowser/MyBrowserApp.swift
import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

@main
struct MyBrowserApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.chrome
        configuration.productName = "MyBrowser"
        // Quit on the first ⌘Q instead of Chromium's "Hold ⌘Q to Quit".
        configuration.preferences["browser.confirm_to_quit"] = false
        return configuration
    }

    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        // Browser windows are Chromium's, opened by Browser, not by a scene.
        Settings { Text("MyBrowser").padding() }
            .commands { BrowserCommands(browser: delegate.browser) }
            .defaultLaunchBehavior(.suppressed)  // macOS 15: no Settings window at launch
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let browser = Browser()

    func applicationDidFinishLaunching(_ notification: Notification) {
        browser.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { browser.newWindow() }
        return true
    }
}
```

## Sources/MyBrowser/Browser.swift

The controller. It keeps no list of tabs; `CefTabs` and `CefChromeWindow.tabs` are the model. `onWindowOpened` dresses every window, including ones Chromium opens itself.

```swift
// Sources/MyBrowser/Browser.swift
import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The browser's windows and tabs. It keeps no list of tabs: Chromium's
/// tab model (`CefTabs`, `CefChromeWindow.tabs`) is the only one.
@MainActor
@Observable
final class Browser {
    static let home = URL(string: "https://duckduckgo.com/")!

    /// The private session's profile, made with the first private window.
    private var privateProfile: CefProfile?

    /// Every window, private ones included, as Chromium lists them.
    var windows: [CefChromeWindow] {
        CefProfile.default.tabs.windows + (privateProfile?.tabs.windows ?? [])
    }

    /// The window in front.
    var keyWindow: CefChromeWindow? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    func start() {
        dress(CefProfile.default)
        newWindow()
    }

    /// Gives every window of `profile` the browser's own bars: the ones the
    /// app opens and the ones Chromium opens itself (a tab dragged out, an
    /// extension's new window, a reopened window). `onWindowOpened` belongs
    /// to one profile, so each profile needs it.
    private func dress(_ profile: CefProfile) {
        profile.tabs.onWindowOpened = { [weak self] window in
            guard let self else { return }
            window.showsChromeUI = false
            window.setTopBar { TopBar(window: window, browser: self) }
        }
    }

    func newWindow(url: URL = Browser.home) {
        Task {
            do {
                _ = try await CefChromeWindow.open(url: url)
            } catch {
                NSLog("MyBrowser: could not open a window: \(error)")
            }
        }
    }

    /// A private window, on an incognito profile kept in memory only.
    func newPrivateWindow(url: URL = Browser.home) {
        let profile = privateProfile ?? CefProfile.incognito()
        if privateProfile == nil {
            privateProfile = profile
            dress(profile)
        }
        Task { _ = try? await CefChromeWindow.open(url: url, profile: profile) }
    }

    func newTab(url: URL = Browser.home, in window: CefChromeWindow? = nil) {
        guard let window = window ?? keyWindow else { return newWindow(url: url) }
        Task { try? await window.openTab(url) }
    }

    func closeTab() {
        if let tab = keyWindow?.activeTab { tab.close() } else { NSApp.keyWindow?.performClose(nil) }
    }
}

/// Typed text as a destination: an address if it looks like one, else a search.
enum TypedAddress {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.hasPrefix("about:"), let url = URL(string: text) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)") { return url }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}

struct BrowserCommands: Commands {
    let browser: Browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser.newTab() }.keyboardShortcut("t")
            Button("New Window") { browser.newWindow() }.keyboardShortcut("n")
            Button("New Private Window") { browser.newPrivateWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Button("Close Tab") { browser.closeTab() }.keyboardShortcut("w")
            Button("Reopen Closed Tab") { browser.keyWindow?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Reload") { browser.keyWindow?.activeTab?.page?.reload() }.keyboardShortcut("r")
            Button("Developer Tools") { browser.keyWindow?.activeTab?.page?.execute(.showDevTools) }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
```

## Sources/MyBrowser/TopBar.swift

The views over Chrome's tab strip and toolbar.

```swift
// Sources/MyBrowser/TopBar.swift
import CefChromium
import CefSwiftUI
import SwiftUI

/// Over Chrome's tab strip and toolbar: the tabs on one row, the toolbar
/// of the active tab under them.
struct TopBar: View {
    let window: CefChromeWindow
    let browser: Browser

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 72)  // the window buttons
                TabStrip(window: window)
                Button("New Tab", systemImage: "plus") { browser.newTab(in: window) }
            }
            .frame(maxHeight: .infinity)
            if let page = window.activeTab?.page {
                Toolbar(page: page)
                    .frame(height: 40)
                    .id(ObjectIdentifier(page))  // fresh field state per tab
            }
        }
        .padding(.horizontal, 8)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(maxHeight: .infinity, alignment: .top)
        // Empty parts of the bar move the window, as a title bar does.
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
        .background(.bar)
    }
}

/// The window's tabs, drawn from Chromium's model. Each click is a command
/// to Chromium; the strip redraws when Chromium reports the change.
struct TabStrip: View {
    let window: CefChromeWindow

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(window.tabs) { tab in TabButton(tab: tab) }
            }
        }
        .scrollIndicators(.never)
    }
}

struct TabButton: View {
    let tab: CefTab

    var body: some View {
        HStack(spacing: 6) {
            if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe")
            }
            Text(tab.title.isEmpty ? "New Tab" : tab.title).lineLimit(1)
            Button("Close Tab", systemImage: "xmark") { tab.close() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 200, alignment: .leading)
        .background(tab.isActive ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { Task { try? await tab.select() } }
    }
}

/// Back, forward, reload and the address field, bound to one tab's page.
struct Toolbar: View {
    let page: CefPage
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button("Back", systemImage: "chevron.left", action: page.goBack)
                .disabled(!page.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: page.goForward)
                .disabled(!page.canGoForward)
            Button("Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
                if page.isLoading { page.stopLoading() } else { page.reload() }
            }
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isEditing)
                .onSubmit {
                    if let url = TypedAddress.url(for: text) { page.load(url) }
                    isEditing = false
                }
        }
        .onAppear { text = page.url?.absoluteString ?? "" }
        .onChange(of: page.url) {
            if !isEditing { text = page.url?.absoluteString ?? "" }
        }
    }
}
```

## Bundle and open

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyBrowser
open dist/MyBrowser.app
```

The first run downloads CEF (about 135 MB) into `.cef/` and takes a few
minutes to compile CefSwift. A window opens on DuckDuckGo with the tab strip
across the top; ⌘T opens a tab, ⌘W closes one, ⌘⇧T reopens it, ⌘⇧N
opens a private window.
