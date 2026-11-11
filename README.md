# CefSwift

Chromium for Swift apps on macOS, built on the [Chromium Embedded Framework](https://github.com/chromiumembedded/cef).
Embed a web view in SwiftUI, or build a complete browser — with an API that
reads like the rest of your Swift code.

![The Browser example](docs/images/browser.png)

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

## What you get

- **`CefBrowser`** — an `@Observable` model of one browser. Bind SwiftUI to
  `title`, `url`, `isLoading`, `estimatedProgress`, `downloads`; call
  `load`, `goBack`, `find`, `printToPDF`, `snapshot`.
- **`CefWebView`** — shows a browser in SwiftUI. Render *windowed* (Chromium's
  native view) or *offscreen* (a layer that SwiftUI content can overlap).
- **`CefBrowserWindow`** — a Chrome-style window: the full Chrome runtime with
  `chrome://settings`, extensions, history, passwords and PDF viewing, under a
  toolbar you write in SwiftUI.
- **`CefBridge`** — typed, promise-based calls between JavaScript and Swift:
  `await app.greet({ name: "Ada" })`.
- **Async JavaScript** — `try await browser.evaluateJavaScript("document.title")`.
- **`CefDevTools`** — the Chrome DevTools Protocol, in-process: emulation,
  network events, screenshots, anything Puppeteer can do.
- **`CefBrowserDelegate`** — `async` policy decisions (permissions, dialogs,
  authentication, downloads, certificate errors) with native defaults.
- **`CefProfile`** — isolated or persistent profiles with cookies, Chromium
  preferences and theming.
- **Customization** — context-menu entries, request filtering, user scripts
  and stylesheets, Chromium preferences, Chrome commands, extensions, feature
  flags, and your product name in place of "Chromium" — on Chromium's own
  `chrome://` pages as well as yours.

See the [guide](docs/guide.md) for each of these in use.

## Getting started

Add the package and depend on `CefSwiftUI` (or `CefKit` for AppKit-only code):

```swift
dependencies: [
    .package(url: "https://github.com/Rajaniraiyn/CefSwift", branch: "main"),
],
targets: [
    .executableTarget(name: "MyApp", dependencies: [
        .product(name: "CefSwiftUI", package: "CefSwift"),
    ]),
]
```

Chromium needs an app bundle with helper processes, so build with the bundled
command plugin instead of `swift run`:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp
open MyApp.app
```

The first run downloads the pinned CEF build (about 135 MB). See
[bundling](docs/bundling.md) for signing, identifiers and Xcode.

## Two kinds of app

| | Embedding web content | Building a browser |
|---|---|---|
| Configuration | `CefConfiguration.embedded` | `CefConfiguration.browser` |
| Host | `CefWebView` in your own windows | `CefBrowserWindow`, or `CefRuntime.openChromeWindow` for Chrome's full UI |
| Chrome runtime (`chrome://` pages, extensions) | no | yes |
| Idle cost | background services off | everything a browser needs |

## Examples

`Examples/` contains three apps — bundle any of them with
`swift package --package-path Examples … cef bundle --product <Name>`:

- **Browser** — a tabbed browser with a Safari-style toolbar, private tabs,
  downloads, custom context menu and Chromium's internal pages.
- **Showcase** — SwiftUI embedding: observable state, native overlays over an
  offscreen page, the JavaScript bridge, app content from a custom scheme.
- **SelfTest** — end-to-end checks against the real Chromium runtime; CI runs it.

## Requirements

macOS 14+, Swift 6, Apple silicon or Intel. CEF is pinned in `CEF_VERSION.json`
and kept current automatically ([automation](docs/automation.md)).

## Documentation

[Guide](docs/guide.md) · [Architecture](docs/architecture.md) ·
[Bundling](docs/bundling.md) · [Sandbox](docs/sandbox.md) ·
[Automation](docs/automation.md)

## License

BSD 3-Clause, the same as CEF. See [LICENSE](LICENSE).
