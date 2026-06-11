# CefSwift Examples

Two example apps, one package. Both consume the parent package via `.package(path: "..")`.

| Example | What it teaches |
| --- | --- |
| **Browser** | Building a full Arc-class browser: `CefSwiftApp` bootstrap, chrome runtime style (chrome://history, chrome://extensions, chrome://settings, DevTools), tab management over multiple `CefWebViewModel`s, omnibox with search fallback, popup → new tab via `onPopupRequest`, load progress, favicons, keyboard shortcuts (⌘T/⌘W/⌘L/⌘R), custom cache path, smoke-test mode for CI |
| **Gallery** | Embedding web content as ordinary SwiftUI: `CefWebView` cards in a `LazyVGrid`, per-view alloy runtime style, `isAudioMuted`, `onConsoleMessage` bridged into a native list, navigation driven by native `Picker`/`TextField`, live `CefConfiguration` inspection, custom chromium switches |

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
