# CefSwift

**The Chromium Embedded Framework, as if Apple shipped it.**

CefSwift is to Swift and SwiftUI what CefSharp is to .NET: a Swift Package that
embeds a full Chromium browser engine as first-class SwiftUI views. Not a
WKWebView wrapper — the real thing. Chrome's runtime style with tabs,
extensions, DevTools, and `chrome://` internals; a modern Swift 6 API surface;
and completely automated CEF download and `.app` assembly through a SwiftPM
command plugin. It is designed to scale from a single embedded web card in a
dashboard all the way up to an Arc-class browser.

> **Status:** v1. Windowed (native NSView) embedding on macOS, arm64 and x64.
> Honest limitations: no off-screen rendering yet, the Chromium sandbox is
> disabled (`no_sandbox`), and JS↔Swift bridging is not exposed. See the
> [Roadmap](#roadmap).

## Why CefSwift

- **SwiftUI-native.** `CefWebView(url:)` is a real SwiftUI view backed by an
  `@Observable` model — titles, progress, favicons, and navigation state flow
  into your UI the way Apple frameworks do.
- **Chrome runtime style.** Browsers created by CefSwift default to CEF's
  Chrome style: real tabs under the hood, extension support, profiles, and the
  full set of `chrome://` pages. This is the foundation you need to build an
  actual browser, not just render HTML. (Alloy style is one option away for
  minimal embedded views.)
- **Zero link-time CEF dependency.** CefSwift `dlopen`s the CEF framework at
  launch and resolves the C API by `dlsym`. Your package builds with nothing
  but the Swift toolchain — no Xcode, no framework search paths, no 100 MB
  binary in your repository.
- **Bundling is a one-liner.** A SwiftPM command plugin downloads the pinned
  CEF distribution, verifies it, and assembles a fully structured, codesigned
  `.app` — framework, all five helper apps, Info.plists — from the command line.
- **Self-updating.** A scheduled GitHub Actions workflow watches the CEF CDN,
  bumps the pin, re-vendors headers, and opens an auto-merging PR. Chromium
  security updates arrive as routine pull requests.

## Quick start

Add the package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rajaniraiyn/CefSwift.git", from: "1.0.0")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")]
    )
]
```

Write your app — `CefSwiftApp` is the one-line bootstrap that installs the
CEF-aware `NSApplication` subclass and initializes the runtime before SwiftUI
takes over:

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

Download CEF and produce a runnable, signed `.app` (CEF apps must be real
bundles — a bare executable cannot host Chromium):

```sh
swift package --allow-writing-to-package-directory \
              --allow-network-connections all \
              cef bundle --product MyApp
```

That's it. The plugin prints the path of the finished `MyApp.app` and a hint
to `open` it.

For programmatic control, drive the view through a model:

```swift
@State private var model = CefWebViewModel(url: URL(string: "https://example.com"))

CefWebView(model: model)
    .toolbar {
        Button("Back") { model.goBack() }.disabled(!model.canGoBack)
        ProgressView(value: model.estimatedProgress).opacity(model.isLoading ? 1 : 0)
    }
```

## How it works

```
┌────────────────────────────────────────────────────────────┐
│ MyApp.app                                                  │
│ ├─ Contents/MacOS/MyApp                 your Swift binary  │
│ └─ Contents/Frameworks/                                    │
│    ├─ Chromium Embedded Framework.framework   ← dlopen'd   │
│    ├─ MyApp Helper.app                                     │
│    ├─ MyApp Helper (GPU).app                               │
│    ├─ MyApp Helper (Renderer).app          five helpers,   │
│    ├─ MyApp Helper (Plugin).app            one binary      │
│    └─ MyApp Helper (Alerts).app                            │
└────────────────────────────────────────────────────────────┘
```

- **Runtime loading.** At launch, CefSwift locates
  `Chromium Embedded Framework.framework` inside your bundle, `dlopen`s it,
  and resolves every `cef_*` entry point into a trampoline table. Nothing
  links against CEF at build time, so `swift build` works on a machine that
  has never seen a CEF binary.
- **Five helper apps.** Chromium is multi-process. Renderer, GPU, plugin, and
  alert processes each launch as a dedicated helper `.app` whose name and
  bundle ID are load-bearing — the bundle plugin generates all of them
  correctly so you never think about it. See [docs/bundling.md](docs/bundling.md).
- **External message pump.** SwiftUI owns the main run loop, so CefSwift
  drives Chromium with CEF's external message pump: CEF tells us when it needs
  work scheduled, and a main-thread timer (clamped to 33 ms) calls
  `cef_do_message_loop_work()`. No background loops, no run-loop fights.
  See [docs/architecture.md](docs/architecture.md).
- **API-version pinning.** CefSwift compiles against a pinned
  `CEF_API_VERSION` from CEF's versioned-API mechanism, giving ABI stability
  across CEF releases — which is what makes fully automated CEF bumps safe.

## Examples

The [`Examples/`](Examples/) directory is a standalone package with two apps:

- **Browser** — an Arc-style mini browser: tab strip, omnibox with search
  fallback, back/forward/reload, progress, favicons, popup-to-new-tab,
  DevTools, and a menu of `chrome://` pages courtesy of the Chrome runtime
  style.
- **Gallery** — embedded `CefWebView` cards mixed into ordinary SwiftUI
  layout, demonstrating configuration knobs: an alloy-style card, a muted
  card, custom Chromium switches, and a console-log viewer.

Build and run with the plugin (no Xcode required):

```sh
swift package --package-path Examples \
              --allow-writing-to-package-directory \
              --allow-network-connections all \
              cef bundle --product Browser
open Examples/dist/Browser.app
```

Or generate an Xcode project if you prefer the IDE:

```sh
cd Examples && xcodegen generate && open Examples.xcodeproj
```

## Configuration

Everything is a knob on `CefConfiguration` — supply it from your app type:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.remoteDebuggingPort = 9222
        config.userAgentProduct = "MyApp/1.0"
        config.extraCommandLineSwitches = ["enable-features": "ParallelDownloading"]
        return config
    }
    // ...
}
```

| Knob | What it does |
|---|---|
| `defaultRuntimeStyle` | `.chrome` (tabs, extensions, `chrome://`) or `.alloy` (minimal) |
| `rootCachePath` / `cachePath` | Profile and cache locations |
| `remoteDebuggingPort` | Chrome DevTools Protocol on localhost |
| `logSeverity` / `logFile` | Chromium logging |
| `extraCommandLineSwitches` | Any Chromium switch, pluggable |
| `onBeforeCommandLineProcessing` | Last-word hook over the command line |

Full reference, including per-browser `CefBrowserOptions`, flavor/version
overrides on the plugin, and what each runtime style enables:
[docs/configuration.md](docs/configuration.md).

## CEF auto-update

CefSwift pins an exact CEF build in [`CEF_VERSION.json`](CEF_VERSION.json).
Twice a week, a scheduled workflow checks the CEF CDN for a newer stable
build; when one appears, it rewrites the manifest, re-vendors the CEF headers,
and opens a pull request that auto-merges once CI — including a live smoke
test that launches Chromium and loads a page — goes green. Chromium security
updates become routine. Details and required repository settings:
[docs/automation.md](docs/automation.md).

## Requirements

- macOS 14+
- Swift 6 toolchain
- Works with Command Line Tools alone — no Xcode required (Xcode is optional,
  via XcodeGen, for the examples)
- Apple silicon and Intel (`macosarm64` / `macosx64` CEF distributions)

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Module graph, dlopen loader, refcounting bridge, message pump, threading |
| [docs/bundling.md](docs/bundling.md) | Bundle anatomy, Info.plist keys, codesigning, distribution |
| [docs/configuration.md](docs/configuration.md) | Every configuration knob; runtime styles; flavors |
| [docs/chrome-style.md](docs/chrome-style.md) | Building a full browser on the Chrome runtime style |
| [docs/accessibility.md](docs/accessibility.md) | VoiceOver, keyboard, and IME behavior |
| [docs/sandbox.md](docs/sandbox.md) | Sandbox status and security posture |
| [docs/automation.md](docs/automation.md) | The CEF auto-update pipeline |

## Roadmap

- **Off-screen rendering** — `CefOSRView` with Metal compositing, for views
  that need SwiftUI effects, transforms, and full a11y-tree control.
- **Chromium sandbox** — adopt `libcef_sandbox.dylib` (the seam is already in
  place; see [docs/sandbox.md](docs/sandbox.md)).
- **IME polish** — refined composition handling for CJK input in windowed mode.
- **JS ↔ Swift bridging** — typed message ports between page JavaScript and
  Swift, CefSharp-style.
- **Hardened runtime + notarization** support in the bundle plugin.
- **Linux/Windows?** — the C-API core was designed to make this conceivable;
  no commitment yet.

## License

CefSwift is released under the [MIT License](LICENSE). The Chromium Embedded
Framework is a separate work under the BSD 3-Clause license; its headers are
vendored in `Sources/CCef` and its binaries are downloaded at build time —
ship its license with your app.
