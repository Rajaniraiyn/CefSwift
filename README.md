# CefSwift

CefSwift embeds Chromium in any macOS app written in Swift, through the
[Chromium Embedded Framework](https://github.com/chromiumembedded/cef) (CEF).
It exposes what CEF and Chromium can do as Swift types: browsers in SwiftUI
and AppKit views, windowed or offscreen; Chrome-style windows with Chrome's
own pages, settings and extensions; profiles, requests, DevTools, custom
schemes and a JavaScript bridge. Optional libraries add passkeys the app
answers and Chromium's bookmark, history and suggestion stores. That is
enough for a full web browser; the Browser example below is one.

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

`CefSwiftUI` re-exports `CefKit`, the core library. An AppKit app depends on
`CefKit` alone: its `CefWindowedBrowserView` and `CefOffscreenBrowserView`
host a browser without SwiftUI (see [In AppKit](docs/guide.md#in-appkit)).
Optional features are libraries of their own on top of `CefKit`: add
`CefPasskeys` for passkeys the app answers, and `CefChromium` for Chromium's
own browser features: its bookmarks, history and address-bar suggestions,
and its bubbles, find bar and status bubble in Chrome-style windows, anchored,
replaced with your own interface or hidden. `CefChromium` is bound to
Chromium-private interfaces of the pinned CEF, so it is the part most likely
to need attention when CEF updates.

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

### Use Chrome-style windows

Chromium shows Chrome's own pages and UI only in windows it creates. A
`CefWindow` is one, holding one browser; macOS can group several under a
native tab bar. The toolbar is SwiftUI. This app uses
`defaultLaunchBehavior(_:)`, so set `platforms: [.macOS(.v15)]`.

```swift
import AppKit
import CefSwiftUI
import SwiftUI

@main
struct MyBrowser: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .chrome }
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // `CefWindow`s are not SwiftUI scenes. Settings is the only
        // scene, so keep SwiftUI from opening it at launch.
        Settings { EmptyView() }
            .defaultLaunchBehavior(.suppressed)   // macOS 15
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
        var configuration = CefWindow.Configuration()
        configuration.tabbingIdentifier = "tabs"
        let window = CefWindow(browser: browser, configuration: configuration)
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
covers identifiers, signing, entitlements, notarization and the bundle layout;
`swift package cef doctor <App.app>` reports what a built bundle can do.

## Two starting points

| | Your own or trusted content | Arbitrary sites, with Chrome's services |
|---|---|---|
| Configuration | `CefRuntime.Configuration.embedded` | `CefRuntime.Configuration.chrome` |
| Host | `CefWebView` in your own windows (Alloy style) | `CefWindow` (Chrome style), or `CefRuntime.shared.openChromeWindow(url:)` for Chrome's complete UI |
| Chrome runtime (`chrome://` pages, extensions, history) | No | Yes |
| Background services | Off | On |

## Where things live

| Where | What | Examples |
|---|---|---|
| `CefKit` (core) | What any app embedding CEF needs and could not write itself: the runtime, browsers, profiles, the AppKit host views, CEF Views windows (`CefWindow`), handlers and delegates, offscreen rendering and its accessibility, discarding | `CefRuntime`, `CefBrowser`, `CefProfile`, `CefOffscreenBrowserView`, `CefWindow` |
| `CefSwiftUI` | SwiftUI on top of `CefKit`, nothing else | `CefSwiftApp`, `CefWebView`, `setToolbar`, `setPageOverlay` |
| `CefPasskeys`, `CefChromium` (optional) | Capabilities on Chromium internals some apps want: passkeys the app answers; Chromium's bookmark, history and suggestion stores and its bubbles | `CefPasskeyController`, `CefBookmarks`, `CefChromiumSurface` |
| `Examples` | Product decisions written against the public API: UI, defaults, heuristics for when to use a capability | the Browser's toolbar, swipe indicator, Memory Saver, permission names |

The rule: the library holds what an app cannot write against its public
API, because it calls the CEF C API, hooks Chromium or works around a CEF
or Chromium limit. Everything else belongs to the app.

## Features

| Feature | API | Guide |
|---|---|---|
| Observable browser model | `CefBrowser` | [Browsers](docs/guide.md#browsers) |
| Waiting for a navigation to load, with its outcome | `load(_:)` → `CefNavigation`, `waitUntilLoaded(timeout:)` | [Waiting for a load](docs/guide.md#waiting-for-a-load) |
| SwiftUI and AppKit views, windowed or offscreen | `CefWebView`, `CefWindowedBrowserView`, `CefOffscreenBrowserView` | [Showing a browser](docs/guide.md#showing-a-browser) |
| JavaScript evaluation with timeouts, user scripts and style sheets | `evaluateJavaScript(_:timeout:)`, `CefUserScript` | [JavaScript](docs/guide.md#javascript) |
| Typed calls between JavaScript and Swift | `CefBridge` | [Bridge](docs/guide.md#bridge) |
| Asynchronous decisions: permissions, dialogs, downloads, certificate errors | `CefBrowserDelegate` | [Decisions](docs/guide.md#decisions) |
| Native default sheets, localizable and each replaceable | `CefDialogPresenter`, `CefDownloadPresenter`, … | [Built-in sheets](docs/guide.md#built-in-sheets) |
| Downloads: a profile policy, a save panel, observable downloads for a download manager | `CefProfile.downloadPolicy`, `CefProfile.downloads`, `CefDownload` | [Downloads](docs/guide.md#downloads) |
| Context menu | `CefBrowser.Configuration.ContextMenu` | [Context menu](docs/guide.md#context-menu) |
| Chrome-style windows (CEF Views), SwiftUI toolbars, a view over the page, popups, native tabs | `CefWindow`, `pageOverlay` | [Chrome-style windows](docs/guide.md#chrome-style-windows) |
| Chrome commands and Chrome UI trimming | `CefChromeCommand`, `CefRuntime.Configuration.ChromeToolbar` | [Chrome commands](docs/guide.md#chrome-commands) |
| Rebranded and restyled `chrome://` pages | `productName`, `stringOverrides`, `CefUserScript.styleSheet(_:matching:includingShadowRoots:)` | [Chromium's own pages](docs/guide.md#customizing-chromiums-own-pages) |
| Profiles, cookies, Chromium preferences | `CefProfile` | [Profiles](docs/guide.md#profiles) |
| The app's own requests through Chromium's network stack, sharing a profile's cookies, cache and proxy | `CefProfile.data(for:)`, `bytes(for:)` | [Requests through Chromium's network stack](docs/guide.md#requests-through-chromiums-network-stack) |
| Chromium's bookmarks, history and omnibox suggestions (the optional `CefChromium` library) | `CefBookmarks`, `CefHistory`, `CefAutocomplete` | [Bookmarks, history and suggestions](docs/guide.md#bookmarks-history-and-suggestions) |
| Discarding hidden browsers to free memory, and restoring them when shown (when to discard is the app's choice) | `discard()`, `discardBlockers()`, `lifecycle`, `lifecycleChangedAt` | [Discarding browsers](docs/guide.md#discarding-browsers) |
| Chrome DevTools Protocol, in-process | `CefDevTools` | [DevTools](docs/guide.md#devtools) |
| Your own set-up code for every browser of a configuration, before its first page if it must | `CefBrowserAttachment` | [Attachments](docs/guide.md#attachments) |
| Passkeys answered by the app from its own store, or refused (the optional `CefPasskeys` library) | `CefPasskeyController`, `CefPasskeyStore` | [Passkeys](docs/guide.md#passkeys) |
| Content served from your own URL scheme | `CefSchemeHandler` | [Serving your own content](docs/guide.md#serving-your-own-content) |
| Protected media: Widevine in Chromium; the Browser example shows FairPlay services in the system's WebKit beside it | `CefRuntime.Configuration.services.protectedMedia` | [Playing streaming services](docs/guide.md#playing-streaming-services) |

## Examples

[`Examples/`](Examples/README.md) is a separate package with five apps:

- **Browser**: a tabbed browser built on the public API: a SwiftUI
  toolbar, address-bar suggestions, bookmarks, history, private tabs,
  downloads, popups, a swipe indicator, and a Memory Saver that puts
  background tabs to sleep.
- **Showcase**: three demos of embedding web content in SwiftUI.
- **Minimal**: one `CefWebView` on the `.embedded` configuration, and the
  lean case of the footprint benchmark.
- **Compat**: one page in one kind of host with chosen CefSwift features,
  for the web-compatibility matrix (`Scripts/compat-matrix.py`).
- **SelfTest**: end-to-end checks against the real Chromium runtime, run by CI.

## Requirements

- macOS 14 or later (the examples need macOS 15), Apple silicon or Intel.
- Swift 6 toolchain. The Command Line Tools are enough; Xcode is optional.

The CEF version is pinned in `CEF_VERSION.json` and updated by
[automation](docs/automation.md).

## Documentation

- [Guide](docs/guide.md): how to do each task.
- [Architecture](docs/architecture.md): how CefSwift works inside.
- [Bundling](docs/bundling.md): the app bundle, signing, capabilities and distribution.
- [Sandbox](docs/sandbox.md): Chromium's macOS sandbox.
- [Automation](docs/automation.md): CEF updates, CI and releases.
- [Contributing](CONTRIBUTING.md): building, testing and regenerating the C bridge.

## License

BSD 3-Clause, the same as CEF. See [LICENSE](LICENSE).
