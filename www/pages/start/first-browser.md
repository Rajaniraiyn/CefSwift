---
title: "Your first browser in 10 minutes"
description: "From an empty folder to a tabbed Chromium browser with your own SwiftUI tab strip and address field."
---

This builds a browser whose windows and tabs are Chromium's own
(`CefChromeWindow`), with Chrome's tab strip and toolbar covered by a
SwiftUI bar of yours. Extensions' `chrome.tabs`, ⌘T, ⌘⇧T and dragging a
tab out behave as in Chrome, because the tabs are Chrome's. You keep no
list of tabs: the bar draws `window.tabs`.

Gallery: [`TabStripDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/TabStripDemo.swift). The [Browser example](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser) is the full
version of what follows.

## 1. The package

```sh
mkdir MyBrowser && cd MyBrowser
mkdir -p Sources/MyBrowser
printf '.build/\n.cef/\ndist/\n' > .gitignore
```

`Package.swift`:

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
            ]
        ),
    ]
)
```

## 2. The app

`Sources/MyBrowser/MyBrowserApp.swift`. `CefSwiftApp` starts Chromium
before SwiftUI. Browser windows are Chromium's, so the app's only scene
is Settings, kept from opening at launch.

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
        configuration.preferences["browser.confirm_to_quit"] = false
        return configuration
    }

    @NSApplicationDelegateAdaptor private var delegate: BrowserDelegate

    var body: some Scene {
        Settings { Text("MyBrowser").padding() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Tab") { delegate.newTab() }.keyboardShortcut("t")
                }
            }
            .defaultLaunchBehavior(.suppressed)  // macOS 15
    }
}

@MainActor
final class BrowserDelegate: NSObject, NSApplicationDelegate {
    let home = URL(string: "https://duckduckgo.com/")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every window gets the bar: those the app opens and those
        // Chromium opens itself (a tab dragged out, an extension's window).
        CefProfile.default.tabs.onWindowOpened = { window in
            window.showsChromeUI = false
            window.setTopBar { TopBar(window: window) }
        }
        Task { try await CefChromeWindow.open(url: self.home) }
    }

    func newTab() {
        guard let window = CefProfile.default.tabs.windows.last else { return }
        Task { try await window.openTab(self.home) }
    }
}
```

## 3. The bar

`Sources/MyBrowser/TopBar.swift`: the tabs, then the active tab's toolbar.
Each button is a command to Chromium, and the bar redraws when Chromium
reports the change.

```swift
// Sources/MyBrowser/TopBar.swift
import CefChromium
import CefSwiftUI
import SwiftUI

struct TopBar: View {
    let window: CefChromeWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 72)  // the window buttons
                ForEach(window.tabs) { tab in
                    Button(tab.title.isEmpty ? "New Tab" : tab.title) { Task { try await tab.select() } }
                        .fontWeight(tab.isActive ? .semibold : .regular)
                        .lineLimit(1)
                }
                Spacer()
            }
            .frame(maxHeight: .infinity)
            if let page = window.activeTab?.page {
                AddressField(page: page).id(ObjectIdentifier(page))
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }  // macOS 15
        .background(.bar)
    }
}

struct AddressField: View {
    let page: CefPage
    @State private var text = ""

    var body: some View {
        HStack {
            Button("Back", systemImage: "chevron.left", action: page.goBack).disabled(!page.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: page.goForward).disabled(!page.canGoForward)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let typed = text.contains(".") && !text.contains(" ") ? "https://\(text)" : "https://duckduckgo.com/?q=\(text)"
                    if let url = URL(string: text.contains("://") ? text : typed) { page.load(url) }
                }
        }
        .labelStyle(.iconOnly)
        .padding(.bottom, 6)
        .onAppear { text = page.url?.absoluteString ?? "" }
        .onChange(of: page.url) { text = page.url?.absoluteString ?? "" }
    }
}
```

## 4. Bundle and open

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyBrowser
open dist/MyBrowser.app
```

The first bundle downloads CEF (about 135 MB). Never `swift run`: Chromium
starts only from the bundle.

## Next

- Ranked suggestions under the field: [Address bar and suggestions](/browser/address-bar).
- Tabs down the side, Arc style: `CefProfile.default.tabs.layout = .vertical(width: 240)`
  and `window.setSidebar { … }` ([Tabs and the tab strip](/browser/tabs)).
- Bookmarks, history, extensions, downloads, find, private windows: the
  pages under Build a browser, and the `build-a-browser` skill for an agent
  ([Build with an agent](/start/agents)).
