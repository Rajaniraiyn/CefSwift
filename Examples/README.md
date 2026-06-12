# CefSwift Examples

Three example apps, one package. All consume the parent package via `.package(path: "..")`.

| Example | What it teaches |
| --- | --- |
| **Launcher** | A single app you open once, then **launch each hosting mode / configuration demo one at a time** to compare them. A clean sidebar catalog (title + one-line description + Launch): Windowed Alloy (`CefWebView`), Chrome-runtime window (`CefChromeWindow` + SwiftUI toolbar overlay), OSR/Metal (`CefMetalWebView`), incognito vs persistent profile (`CefProfile`), a custom-scheme JS-bridge page, a permissions/JS-dialog demo, a downloads demo, and a **popups/new-tab demo** that drives the window-open disposition handler + a customized context menu. Each demo opens its own closable, re-openable window. |
| **Browser** | Building a full Arc-class browser: `CefSwiftApp` bootstrap, chrome runtime style (chrome://history, chrome://extensions, chrome://settings, DevTools), tab management over multiple `CefWebViewModel`s, omnibox with search fallback, **popup/`target=_blank` → foreground/background tab via `decideWindowOpenFor`** (honoring ⌘/middle-click), load progress, favicons, keyboard shortcuts (⌘T/⌘W/⌘L/⌘R), custom cache path, smoke-test mode for CI |
| **Gallery** | Embedding web content as ordinary SwiftUI: `CefWebView` cards in a `LazyVGrid`, per-view alloy runtime style, `isAudioMuted`, `onConsoleMessage` bridged into a native list, navigation driven by native `Picker`/`TextField`, live `CefConfiguration` inspection, custom chromium switches |

The Launcher is the place to start: it links every hosting mode and configuration
behind one window. See **[Links, popups & new windows + context menus](../docs/links-and-context-menus.md)**
for the disposition/context-menu APIs the Browser and Launcher demonstrate.

## Run with the SwiftPM plugin (recommended)

The `cef` command plugin downloads the pinned CEF distribution (once, cached in `.cef/`),
builds the product, and assembles a runnable `.app` (framework + 5 helper apps + Info.plists
+ ad-hoc codesign). From the **repository root**:

```sh
swift package --package-path Examples \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef bundle --product Browser
```

```sh
swift package --package-path Examples \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef bundle --product Gallery
```

```sh
swift package --package-path Examples \
  --allow-writing-to-package-directory \
  --allow-network-connections all \
  cef bundle --product Launcher
```

The plugin prints the path of the assembled app and an `open` hint when it finishes.

Useful variants:

```sh
# release build, standard (non-minimal) CEF flavor
swift package --package-path Examples --allow-writing-to-package-directory \
  --allow-network-connections all cef bundle --product Browser \
  --configuration release --flavor standard

# inspect pinned version + cache state / wipe the cache
swift package --package-path Examples cef info
swift package --package-path Examples --allow-writing-to-package-directory cef clean
```

> A bare `swift build --package-path Examples` compiles both executables, but the raw
> binaries cannot run: CEF requires a proper `.app` bundle with the framework and helper
> apps in place. Always launch via the bundle the plugin produces.

## Run from Xcode (XcodeGen)

[XcodeGen](https://github.com/yonaskolb/XcodeGen) turns `Examples/project.yml` into a
project (the `.xcodeproj` is gitignored — always regenerate):

```sh
cd Examples
xcodegen generate
open CefSwiftExamples.xcodeproj
```

Both targets get an Info.plist with the CEF-required keys
(`LSEnvironment.MallocNanoZone=0`, `NSPrincipalClass=NSApplication`,
`LSMinimumSystemVersion=14.0`) and a post-build phase that calls
`swift package cef bundle` so the built app is runnable. Set `CEFSWIFT_SKIP_BUNDLE=1`
to skip that phase when iterating on pure SwiftUI code.

## Smoke test (CI)

`Browser` understands a `--cef-smoke-test` flag: it loads a tiny `data:` page and exits
`0` on first successful load, `1` on load failure, `2` after a 45 s watchdog. CI runs:

```sh
timeout 90 ./Browser.app/Contents/MacOS/Browser --cef-smoke-test
```

## Screenshots

| Browser | Gallery |
| --- | --- |
| ![Browser screenshot](../docs/images/example-browser.png) | ![Gallery screenshot](../docs/images/example-gallery.png) |

*(Screenshots TODO — placeholders until first bundled run.)*
