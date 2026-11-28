# CefSwift

CefSwift embeds Chromium in macOS apps written in Swift, through the
[Chromium Embedded Framework](https://github.com/chromiumembedded/cef) (CEF).
Use it for an app shell whose sections are web pages, for a web browser,
or for any app that shows web content. It exposes CEF and Chromium as
Swift types: pages in SwiftUI
and AppKit views, windowed or offscreen; Chrome-style windows with
Chrome's own pages; Chromium's own tabbed windows under your own tab
interface; profiles, requests, DevTools, custom schemes and a JavaScript
bridge.

![The Browser example: a tab rail and toolbar over Chromium's tabs, showing swift.org](docs/images/browser.png)

CefSwift uses the official prebuilt CEF distribution at the version
`CEF_VERSION.json` pins; custom CEF builds are not supported. It is
pre-1.0, and its API can change between minor releases, so the sample
depends on one minor version.

## Modules

| Module | What it is | Needed |
|---|---|---|
| `CefKit` | The core: the runtime, pages, profiles, delegates, the AppKit host views (`CefWindowedPageView`, `CefOffscreenPageView`), CEF Views windows (`CefWindow`), offscreen rendering, discarding | Yes |
| `CefSwiftUI` | SwiftUI on top of CefKit: `CefSwiftApp`, `CefWebView`, toolbar and overlay modifiers. Re-exports CefKit | For SwiftUI apps |
| `CefChromium` | Chromium's own browser features: bookmarks, history, address-bar suggestions, extensions, Chromium's tabbed windows and tab strip (`CefChromeWindow`, `CefTabs`), and Chromium's bubbles, find bar and status bubble. Bound to Chromium-private interfaces of the pinned CEF | Optional |
| `CefPasskeys` | WebAuthn requests answered by the app from its own store, or refused | Optional |
| `cefswift` tool, `CefPlugin` (`swift package cef …`) | Download CEF, assemble, sign, check, package and notarize the `.app` (logic in `CefBundling`) | Build time |
| `CefHelper`, `CefRenderer`, `CefHelperStartup`, `CefBase`, `CCef` | The helper-process executable, its renderer-side code, the helper's sandbox startup library, shared reference counting and strings, and the CEF C headers and loader | Internal; built and bundled for you |

An app depends on `CefSwiftUI`, or on `CefKit` alone for AppKit, and adds
`CefChromium` or `CefPasskeys` if it needs them.
[Architecture](docs/architecture.md#modules) describes each module.

## Getting started

An app that embeds Chromium is an app bundle with Chromium's framework and
five helper apps inside. Build it with SwiftPM or with Xcode: both run the
same `cefswift` tool to add the framework and helpers, sign them and check
the result, so the bundles are the same. [Bundling](docs/bundling.md)
covers each track.

### From a template

A browser of your own, from nothing, in two commands: the first creates
the package (`--template app` for an app shell of web pages, `minimal` for
one web view, `--xcode` for an Xcode project too), the second builds and
opens it.

```sh
curl -fsSL https://raw.githubusercontent.com/Rajaniraiyn/CefSwift/main/Scripts/new-app.sh \
    | sh -s -- MyBrowser --template browser
cd MyBrowser && swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyBrowser --open
```

The browser template is a trimmed copy of the Browser example: the tab
rail, address bar with suggestions, bookmarks, history, extensions,
downloads, find bar and tab discarding, one folder per feature. In a
package that depends on CefSwift, `swift package cef new <Name>` does the
same ([Starting from a template](docs/bundling.md#starting-from-a-template)).

### With SwiftPM

1. Depend on CefSwift:

   ```swift
   // swift-tools-version: 6.0
   // Package.swift
   import PackageDescription

   let package = Package(
       name: "MyApp",
       platforms: [.macOS(.v14)],
       dependencies: [
           .package(url: "https://github.com/Rajaniraiyn/CefSwift", .upToNextMinor(from: "0.2.0")),
       ],
       targets: [
           .executableTarget(name: "MyApp", dependencies: [
               .product(name: "CefSwiftUI", package: "CefSwift"),
           ]),
       ]
   )
   ```

2. Write the app ([below](#show-a-web-page)) in `Sources/MyApp/MyApp.swift`.
3. Bundle and run it with the package's `cef` command plugin:

   ```sh
   swift package --allow-writing-to-package-directory --allow-network-connections all \
       cef bundle --product MyApp
   open dist/MyApp.app
   ```

The first run downloads the pinned CEF build (about 135 MB) into `.cef/`.
Add `.cef/` and `dist/` to `.gitignore`. `swift run` cannot start
Chromium, which runs only from the bundle. Settings go in a `cefapp.json`
beside the sources ([Per-product settings](docs/bundling.md#per-product-settings)).

### With Xcode

1. In an app project (File › New › Project › macOS › App, SwiftUI), add the
   package: File › Add Package Dependencies…, enter
   `https://github.com/Rajaniraiyn/CefSwift`, and add `CefSwiftUI` to the
   app target.
2. In the target's Signing & Capabilities, remove App Sandbox. Official CEF
   builds do not run under it, and the build phase stops with an error if
   it is on ([why](docs/bundling.md#app-sandbox)).
3. Copy [`Examples/Xcode/CefSwift.xcconfig`](Examples/Xcode/CefSwift.xcconfig)
   into the project and choose it as the target's configuration file
   (Project › Info › Configurations). For a local package, set its
   `CEFSWIFT_PACKAGE_DIR` to the package's path.
4. In Build Phases, add a Run Script phase at the end, turn off "Based on
   dependency analysis", and run:

   ```sh
   "$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh"
   ```

5. Write the app ([below](#show-a-web-page)), then Run.

The first build downloads CEF into `.cef/` beside the project. Settings are
build settings: Xcode's own, and `CEF_…` ones for what only CefSwift has.
[`Examples/Xcode`](Examples/Xcode) is a project set up this way.

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
runs. In Xcode's SwiftUI previews, which cannot start Chromium, a
`CefWebView` shows a placeholder. An AppKit app uses CefKit's host views
instead ([In AppKit](docs/guide.md#in-appkit)).

## Choosing a host

| | Your own or trusted content | Arbitrary sites, with Chrome's services |
|---|---|---|
| Configuration | `CefRuntime.Configuration.embedded` | `CefRuntime.Configuration.chrome` |
| Host | `CefWebView` or the AppKit host views, in your own windows (Alloy style) | `CefWindow` (a Chrome-style window of one tab); `CefChromeWindow` in CefChromium (Chromium's tabbed windows, with your own tab interface over Chrome's); `CefRuntime.shared.openChromeWindow(url:)` for Chrome's complete UI |
| `chrome://` pages, extensions, history | No | Yes |
| Background services | Off | On |

The [guide](docs/guide.md) covers each task: pages and views,
JavaScript and the bridge, decisions and built-in sheets, profiles and
requests, Chrome-style windows and Chromium's tabs, extensions, passkeys,
DevTools, custom schemes and streaming media.

## Examples

[`Examples/`](Examples/README.md) is a separate package. It needs macOS 15.
Bundle and run an example from the repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Gallery
open Examples/dist/Gallery.app
```

| Example | What it is |
|---|---|
| `Gallery` | 30 small demos, one capability each, in one SwiftUI app with a sidebar to pick them |
| `Browser` | A tabbed browser: a small core and a folder per feature, with a SwiftUI tab rail and toolbar over Chromium's own tab model |
| `Minimal` | One `CefWebView` on the `.embedded` configuration |
| `Compat` | One page in one kind of host, for the web-compatibility matrix (`Scripts/compat-matrix.py`) |
| `SelfTest` | End-to-end checks against the real Chromium runtime; CI runs it |
| `SystemEngine` | A library target, not an app: the Browser's WebKit tabs for FairPlay content |
| [`Examples/Xcode`](Examples/README.md#xcode) | An Xcode project with one `CefWebView`, built with CefSwift's build phase |

## Known limits

These come from CEF 156 and official CEF builds. The guide's
[Known limits](docs/guide.md#known-limits) lists the rest.

- No App Sandbox, so no Mac App Store: Chromium registers a Mach service
  the App Sandbox refuses. Bundling stops with an error if it is on.
  Chromium's own sandbox still confines the helpers ([Sandbox](docs/sandbox.md)).
- One Chrome-style browser view per window. A `CefWindow` holds one
  page, and Chromium counts it as a popup window of one tab. Only
  windows Chromium draws itself (`CefChromeWindow`, `openChromeWindow`)
  have real Chromium tabs.
- CEF restores no tabs or windows at startup. CefChromium can reopen the
  previous session when the app asks
  ([Restoring tabs and sessions](docs/guide.md#restoring-tabs-and-sessions)).
- CefSwift ships no Chrome extension. Users install extensions from the
  Chrome Web Store, and an app can install or bundle its own
  ([Extensions](docs/guide.md#extensions)).
- CefKit turns Chromium's `RemoteCoreAnimationAPI` feature off by default:
  with it on, pages Chromium draws itself do not reach the screen on
  macOS 27.2 ([why](docs/architecture.md#presenting-pages)).
- No H.264, HEVC or AAC, and Widevine only as a software (L3) client.

## Requirements

- macOS 14 or later (the examples need macOS 15), Apple silicon or Intel.
  CI builds for macOS 14 and runs on macOS 15; it compiles for Intel but
  runs nothing there.
- A Swift 6 toolchain. The Command Line Tools are enough for SwiftPM; an
  Xcode project needs Xcode 16 or later.

The CEF version is pinned in `CEF_VERSION.json` and updated by
[automation](docs/automation.md).

Upgrading an existing profile from CEF 156 to 158 can require signing in to
sites again. [Profile upgrade details](docs/guide.md#upgrading-profiles-from-cef-156)

## Documentation

- [Guide](docs/guide.md): how to do each task.
- [Architecture](docs/architecture.md): how CefSwift works inside.
- [Design notes](docs/design-notes.md): measurements behind design choices, and mechanisms measured and not used.
- [Bundling](docs/bundling.md): the app bundle, signing, capabilities and distribution.
- [Sandbox](docs/sandbox.md): Chromium's macOS sandbox.
- [Automation](docs/automation.md): CEF updates, CI and releases.
- [Contributing](CONTRIBUTING.md): building, testing and regenerating the C bridge.

## License

BSD 3-Clause, the same as CEF. See [LICENSE](LICENSE).
