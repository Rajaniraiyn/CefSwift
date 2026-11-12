# CefSwift

CefSwift brings Chromium to Swift apps on macOS, built on the
[Chromium Embedded Framework](https://github.com/chromiumembedded/cef) (CEF).
Use it to show web content in a SwiftUI or AppKit app, or to build a tabbed
browser with Chrome's own settings, extensions, history and password manager
under a toolbar you write in SwiftUI.

![The Browser example](docs/images/browser.png)

CefSwift is pre-1.0; its API can change between releases.

## Quick start

### Add the package

```swift
// swift-tools-version: 6.0
// Package.swift
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Rajaniraiyn/CefSwift", branch: "main"),
    ],
    targets: [
        .executableTarget(name: "MyApp", dependencies: [
            .product(name: "CefSwiftUI", package: "CefSwift"),
        ]),
    ]
)
```

`CefSwiftUI` re-exports `CefKit`, the core library. Depend on `CefKit` alone
only if you host browsers without the views `CefSwiftUI` provides.

### Show a web page

```swift
import CefSwiftUI
import SwiftUI

@main
struct MyApp: CefSwiftApp {
    var body: some Scene {
        WindowGroup {
            CefWebView(url: URL(string: "https://example.com")!)
        }
    }
}
```

`CefSwiftApp` takes the place of `App`: it starts Chromium before SwiftUI
runs.

### Build a tabbed browser

Each tab is a `CefBrowserWindow`, a Chrome-style window that macOS groups
with others under a native tab bar. The toolbar is SwiftUI. This app uses
`defaultLaunchBehavior(_:)`, so set `platforms: [.macOS(.v15)]`.

```swift
import AppKit
import CefSwiftUI
import SwiftUI

@main
struct MyBrowser: CefSwiftApp {
    static var cefConfiguration: CefConfiguration { .browser }
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Browser windows are not SwiftUI scenes. Settings is the only
        // scene, so keep SwiftUI from opening it at launch.
        Settings { EmptyView() }
            .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        openTab()
    }

    /// Called by the "+" button in the native tab bar.
    @objc func newWindowForTab(_ sender: Any?) {
        openTab()
    }

    func openTab() {
        let browser = CefBrowser(url: URL(string: "https://www.swift.org")!)
        var configuration = CefBrowserWindow.Configuration()
        configuration.tabbingIdentifier = "tabs"
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        window.setToolbar {
            BackButton(browser: browser)
        } principal: {
            PageTitle(browser: browser)
        } trailing: {
            Button("New Tab", systemImage: "plus") { self.openTab() }
        }
        window.show()
    }
}

struct BackButton: View {
    let browser: CefBrowser
    var body: some View {
        Button("Back", systemImage: "chevron.left", action: browser.goBack)
            .disabled(!browser.canGoBack)
    }
}

struct PageTitle: View {
    let browser: CefBrowser
    var body: some View { Text(browser.title).lineLimit(1) }
}
```

The toolbar views are separate `View` types so that they read the
browser's state in their `body` and update when it changes.

### Build and run

Chromium runs only from an app bundle that contains its framework and five
helper apps. The package's `cef` command plugin builds one:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp
open dist/MyApp.app
```

The first run downloads the pinned CEF build (about 135 MB) into `.cef/`.
Add `.cef/` and `dist/` to `.gitignore`. [Bundling](docs/bundling.md)
covers identifiers, signing and the bundle layout.

## Two kinds of app

| | Showing web content | Building a browser |
|---|---|---|
| Configuration | `CefConfiguration.embedded` | `CefConfiguration.browser` |
| Host | `CefWebView` in your own windows | `CefBrowserWindow`, or `CefRuntime.shared.openChromeWindow(url:)` for Chrome's complete UI |
| Chrome runtime (`chrome://` pages, extensions, history) | No | Yes |
| Background services | Off | On |

## Features

| Feature | API | Guide |
|---|---|---|
| Observable browser model | `CefBrowser` | [Browsers](docs/guide.md#browsers) |
| SwiftUI and AppKit views, windowed or offscreen | `CefWebView`, `CefWindowedBrowserView`, `CefOffscreenBrowserView` | [Showing a browser](docs/guide.md#showing-a-browser) |
| JavaScript evaluation, user scripts and style sheets | `evaluateJavaScript(_:)`, `CefUserScript` | [JavaScript](docs/guide.md#javascript) |
| Typed calls between JavaScript and Swift | `CefBridge` | [Bridge](docs/guide.md#bridge) |
| Asynchronous decisions: permissions, dialogs, downloads, certificate errors | `CefBrowserDelegate` | [Decisions](docs/guide.md#decisions) |
| Context menu | `CefContextMenuConfiguration` | [Context menu](docs/guide.md#context-menu) |
| Chrome-style windows, SwiftUI toolbars, popups, native tabs | `CefBrowserWindow` | [Building a browser](docs/guide.md#building-a-browser) |
| Chrome commands and Chrome UI trimming | `CefChromeCommand`, `CefChromeUIConfiguration` | [Chrome commands](docs/guide.md#chrome-commands) |
| Rebranded and restyled `chrome://` pages | `productName`, `stringOverrides`, `CefUserScript.styleSheet(_:matching:includingShadowRoots:)` | [Chromium's own pages](docs/guide.md#customizing-chromiums-own-pages) |
| Profiles, cookies, Chromium preferences | `CefProfile` | [Profiles](docs/guide.md#profiles) |
| Bookmarks, history, address-bar suggestions | `CefBookmarks`, `CefHistory`, `CefAutocomplete` | [Bookmarks, history and suggestions](docs/guide.md#bookmarks-history-and-suggestions) |
| Chrome DevTools Protocol, in-process | `CefDevTools` | [DevTools](docs/guide.md#devtools) |
| Content served from your own URL scheme | `CefSchemeHandler` | [Serving your own content](docs/guide.md#serving-your-own-content) |

## Examples

[`Examples/`](Examples/README.md) is a separate package with four apps:

- **Browser**: a tabbed browser with a SwiftUI toolbar, address-bar
  suggestions, bookmarks, history, private tabs, downloads and popups.
- **Showcase**: three demos of embedding web content in SwiftUI.
- **Minimal**: one `CefWebView` on the `.embedded` configuration, and the
  lean case of the footprint benchmark.
- **SelfTest**: end-to-end checks against the real Chromium runtime, run by CI.

## Requirements

- macOS 14 or later (the examples need macOS 15), Apple silicon or Intel.
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is optional.

The CEF version is pinned in `CEF_VERSION.json` and updated by
[automation](docs/automation.md).

## Documentation

- [Guide](docs/guide.md): how to do each task.
- [Architecture](docs/architecture.md): how CefSwift works inside.
- [Bundling](docs/bundling.md): the app bundle, identifiers and signing.
- [Sandbox](docs/sandbox.md): Chromium's macOS sandbox.
- [Automation](docs/automation.md): CEF updates, CI and releases.
- [Contributing](CONTRIBUTING.md): building, testing and regenerating the C bridge.

## License

BSD 3-Clause, the same as CEF. See [LICENSE](LICENSE).
