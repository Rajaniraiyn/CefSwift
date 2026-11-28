---
name: cefswift
description: Embed Chromium in a macOS app written in Swift with CefSwift, the Swift and SwiftUI binding for the official prebuilt CEF. Use when a Swift package or Xcode project depends on CefSwift (imports CefSwiftUI, CefKit, CefChromium or CefPasskeys), or when the user wants Chromium pages in a Mac app, a Chromium-based browser in Swift, or to bundle, sign or notarize a CEF app.
---

# CefSwift

CefSwift wraps the official prebuilt CEF (the Chromium version in its
`CEF_VERSION.json`) as Swift types: pages in SwiftUI and AppKit views,
Chrome-style windows, Chromium's own tabbed windows under your own tab UI,
profiles, a JavaScript bridge, custom schemes, DevTools, and Chromium's
bookmarks, history, suggestions and extensions.

Docs: https://rajaniraiyn.dev/cefswift/ (`llms.txt` and `llms-full.txt` at
that root). The same content, always reachable, is the repository's
`docs/` folder: `https://raw.githubusercontent.com/Rajaniraiyn/CefSwift/main/docs/guide.md`
(also `architecture.md`, `bundling.md`, `design-notes.md`).

## Pick the modules

| Module | Add it when |
|---|---|
| `CefSwiftUI` | Any SwiftUI app. `CefSwiftApp`, `CefWebView`, toolbar and overlay modifiers. Re-exports `CefKit`. |
| `CefKit` | An AppKit app with no SwiftUI: `CefWindowedPageView`, `CefOffscreenPageView`, `CefWindow`. |
| `CefChromium` | Tabs Chromium knows (`CefChromeWindow`, `CefTabs`), bookmarks, history, address-bar suggestions, extensions, Chromium's bubbles and find bar. Bound to the pinned CEF. |
| `CefPasskeys` | The app answers WebAuthn from its own store, or refuses it. |

## Pick the host

| You want | Configuration | Host |
|---|---|---|
| Your own or trusted content inside your views | `.embedded` | `CefWebView(url:)` or `CefWebView(page)`; AppKit: `CefWindowedPageView` |
| SwiftUI over the page, transforms, thumbnails | `.embedded` + `isOffscreenRenderingEnabled = true` | `CefPage.Configuration.rendering = .offscreen` |
| One arbitrary site per window, Chrome's pages and extensions working | `.chrome` | `CefWindow` |
| A browser: several real Chromium tabs under your own tab UI | `.chrome` | `CefChromeWindow` with `showsChromeUI = false` and `setTopBar` / `setSidebar` |
| Chrome's complete UI | `.chrome` | `CefRuntime.shared.openChromeWindow(url:)` |

`CefWebView` pages are Alloy style: no `chrome://` pages, extensions or
history. Those exist only in windows Chromium creates.

## Hard rules

1. **Never `swift run`, never run `.build/…/MyApp`.** Chromium runs only
   from an app bundle with its framework and five helpers. The error is
   `CefError.frameworkNotFound`.
2. **Bundle with the `cef` plugin**, from the package root:
   `swift package --allow-writing-to-package-directory --allow-network-connections all cef bundle --product MyApp`,
   then `open dist/MyApp.app`. The first run downloads CEF (about 135 MB)
   into `.cef/`. Add `.cef/` and `dist/` to `.gitignore`.
3. **No App Sandbox.** Official CEF builds do not run under it; both build
   tracks stop with an error if it is on. Do not add
   `com.apple.security.app-sandbox`. Chromium's own sandbox still confines
   the helpers. No Mac App Store.
4. **`CefSwiftApp`, not `App`**, for the `@main` type. It installs
   `CefApplication` and starts Chromium before SwiftUI. An AppKit app calls
   `CefRuntime.shared.initialize(configuration:)` first thing in `main`.
5. Register scheme handlers in the app's `init()` (Chromium is running
   there), before any page loads. Declare the scheme in
   `runtimeConfiguration.customSchemes` too.
6. A page holds its `delegate` weakly. Keep a strong reference.
7. Everything on `CefRuntime`, `CefPage`, `CefProfile` and windows is
   `@MainActor`.
8. Depend on one minor version: `.upToNextMinor(from: "0.2.0")`. The API
   can change between minor releases before 1.0.

## Smallest app

```swift
import CefSwiftUI
import SwiftUI

@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .embedded }

    var body: some Scene {
        WindowGroup {
            CefWebView(url: URL(string: "https://example.com")!)
        }
    }
}
```

`Package.swift`, settings (`cefapp.json`) and the Xcode track:
[references/setup.md](references/setup.md).

## Verify

1. Build and bundle: `swift package … cef bundle --product MyApp`. A Swift
   compile error shows here; fix and rerun.
2. Launch: `open dist/MyApp.app`. To see Chromium's and CefSwift's log,
   run the bundle's executable from a terminal instead:
   `dist/MyApp.app/Contents/MacOS/MyApp`. The launch logs one line naming
   what the signature leaves out; that line is informational.
3. Check the bundle: `swift package … cef doctor dist/MyApp.app`. It exits
   non-zero on errors.
4. When changing CefSwift itself, run SelfTest:
   `swift package --package-path Examples … cef bundle --product SelfTest`
   then `Examples/dist/SelfTest.app/Contents/MacOS/SelfTest`. Its exit
   status is the number of failed checks. `SELFTEST_ONLY=<group>` narrows it.
5. A compile check of doc snippets: `Scripts/check-doc-samples.py` (in a
   CefSwift checkout).

## Find the API

- [references/api.md](references/api.md): cheat sheet of the types and calls
  most apps use.
- [references/setup.md](references/setup.md): package, `cefapp.json`,
  capabilities, signing, notarization, Xcode.
- [references/demos.md](references/demos.md): which Gallery demo shows each
  capability, one file each, in `Examples/Sources/Gallery/Demos/`.
- Building a browser: use the `build-a-browser` skill.

When something is not in these files, search `docs/guide.md` (task
reference), `docs/architecture.md` (internals) and `docs/bundling.md`
(bundles and signing): in the package's `.build/checkouts/CefSwift/docs/`
when CefSwift is a remote dependency, at the raw GitHub URLs above
otherwise, or in the site's `llms-full.txt`. For an exact signature, read
the source under `Sources/` the same way.

## Limits to plan around

Google sign-in works (verified by hand). What does not:

- No H.264, HEVC or AAC in Chromium, and Widevine only as software L3:
  Netflix-class services do not play. Show them in a `WKWebView` (FairPlay),
  as the Browser example's `WebKitTabs` does.
- One page per `CefWindow`; real tabs only in `CefChromeWindow`.
- CEF restores no session by itself; CefChromium's `previousSession` and
  `restorePreviousSession()` let the app do it.
- DevTools opens in its own window; it cannot be docked in your view.
