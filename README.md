# CefSwift

Chromium Embedded Framework for SwiftUI apps on macOS.

## Why

- Embed real Chromium (not WKWebView) in a SwiftUI app with a single view.
- Three hosting modes: a windowed native browser, a Chrome-runtime window with tabs and `chrome://` pages, and an offscreen Metal-backed view for mixing web content into custom layouts.
- A SwiftPM command plugin downloads the pinned CEF distribution and assembles a signed `.app` with the five helper bundles. No Xcode required.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/Rajaniraiyn/CefSwift.git", from: "0.1.0")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")]
    )
]
```

## Quick start

```swift
import SwiftUI
import CefSwiftUI

@main
struct MyApp: CefSwiftApp {
    var body: some Scene {
        WindowGroup {
            CefWebView(url: URL(string: "https://example.com")!)
        }
    }
}
```

Build a runnable `.app` (CEF can't run from a bare executable):

```sh
swift package --allow-writing-to-package-directory \
              --allow-network-connections all \
              cef bundle --product MyApp
```

## Hosting modes

| View | Backing | Use for |
|---|---|---|
| `CefWebView` | Native `NSView`, Alloy runtime | Embedded web content in a SwiftUI layout |
| `CefChromeWindow` | Chrome runtime window | Tabs, extensions, `chrome://` pages — full browser UI |
| `CefMetalWebView` | Offscreen render, `IOSurface` → `CALayer` | Custom compositing, transforms, mixing into Metal scenes |

## Examples

The [`Examples/`](Examples/) directory is a standalone package:

- **Browser** — tabbed browser on the Chrome runtime: omnibox, DevTools, popups, `chrome://` menu.
- **Gallery** — `CefWebView` cards inside ordinary SwiftUI layout.
- **Launcher** — minimal launcher demonstrating window-open routing and link handling.

Run any of them:

```sh
swift package --package-path Examples \
              --allow-writing-to-package-directory \
              --allow-network-connections all \
              cef bundle --product Browser
open Examples/dist/Browser.app
```

## Status

macOS only. Requires macOS 14+, Swift 6, and a CEF 148+ distribution (downloaded automatically by the plugin, pinned in [`CEF_VERSION.json`](CEF_VERSION.json), refreshed by a scheduled workflow). Apple silicon and Intel.

Current limitations: the Chromium sandbox is disabled, and JS↔Swift bridging is not yet exposed.

## Documentation

See [`docs/`](docs/) for architecture (hosting modes, OSR/Metal, threading), bundling, configuration (JS bridge, links/popups, context menus), sandboxing, and the auto-update pipeline.

## License

BSD 3-Clause. See [LICENSE](LICENSE). The Chromium Embedded Framework is a separate work under the same license; ship its license alongside your app.

---

Made with ❤️ by [Rajaniraiyn](https://github.com/Rajaniraiyn)
