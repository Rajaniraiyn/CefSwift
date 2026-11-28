# Build a browser

An outline of a tabbed browser on CefSwift, from an empty package to a
signed app. Each step names the API it uses; the `Browser` example in the
repository's `Examples/` is the finished version.

## Overview

A browser built on CefSwift is three layers: Chromium, which CefKit
starts and talks to; the pages and windows CefKit and CefSwiftUI host; and
the product, which is yours: the tab model, the toolbar, the defaults and
the policies. CefSwift keeps out of the third layer, so the steps below
say what the library does and leave the decisions to the app.

### Step 1: Make the package and bundle it

Add CefSwift to a package with an executable target, and describe the app
in a `cefapp.json` beside its sources (bundle identifier, display name,
minimum system version). The `cef` plugin downloads the pinned CEF, builds
the app and its helpers and assembles a signed bundle:

```sh
swift package --allow-writing-to-package-directory \
    --allow-network-connections all cef bundle --product MyBrowser
open dist/MyBrowser.app
```

Chromium runs only from such a bundle, with its helper apps; `swift run`
is not enough.

### Step 2: Start Chromium

Conform the `@main` type to ``CefSwiftApp`` and return
`CefRuntime.Configuration.chrome` from `runtimeConfiguration`: Chrome's
services (history, passwords, autofill, extensions) on, which a browser
wants and an embedded web view does not.

```swift
@main
struct MyBrowser: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .chrome }

    var body: some Scene {
        WindowGroup { BrowserWindow() }
    }
}
```

### Step 3: Show a page and drive it

Keep `CefPage` values in your state and show the selected one in a
``CefWebView``. Bind the toolbar to the page's observable state and call
its methods:

```swift
struct BrowserWindow: View {
    @State private var page = CefPage(url: URL(string: "https://example.com")!)

    var body: some View {
        CefWebView(page)
            .navigationTitle(page.title)
            .toolbar {
                Button("Back", systemImage: "chevron.left") { page.goBack() }
                    .disabled(!page.canGoBack)
                Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
            }
    }
}
```

An address field turns typed text into a URL or a search; that heuristic
is the app's (the example's `AddressBar` feature).

### Step 4: Tabs and new windows

A tab is a page in your model. Decide what a link that opens a window does
in `CefPageDelegate.page(_:decideWindowOpenFor:)`: open it as a new tab
of your own and return `.handled`, or let Chromium open a popup
(`.allowNativePopup`), which `page(_:didOpen:)` hands you. Discard
background tabs to save memory with `CefPage.discard()`; a discarded page
is created again as soon as it is shown, navigated or used.

### Step 5: Answer the page

Permissions, downloads, JavaScript dialogs, file choosers, HTTP
authentication and certificate errors come to `CefPageDelegate`, with
their defaults on `CefProfileDelegate`. Each has a built-in sheet (a
`Cef…Presenter`) that answers when you implement nothing; implement the
method to show your own interface or apply a policy.

### Step 6: Chrome-style windows and Chromium's interface

For extensions, `chrome://` pages, the password manager and Chromium's
bubbles, host the page in a `CefWindow`, a Chrome-style window, and give it
a SwiftUI toolbar with `CefWindow.setToolbar(leading:principal:trailing:)`.
With CefChromium, `CefChromeWindow` keeps Chromium's own tab strip, and
`chromiumSurfacePolicy` decides where Chromium's bubbles show.

### Step 7: Bookmarks, history and suggestions

CefChromium reaches Chromium's own stores: `profile.bookmarks`,
`profile.history` (search, remove, top sites, favicons) and
`profile.autocomplete` for the address field's suggestions.

### Step 8: Profiles and privacy

Each `CefProfile` has its own cookies, storage, settings and site
permissions: `CefProfile.persistent(id:displayName:)` for a person,
`CefProfile.incognito()` for a private window. `profile.preferences` and
`profile.siteSettings` back a settings screen; `cookies(for:)`,
`deleteCookies(for:named:)` and `clearHTTPCache()` back "clear browsing
data".

### Step 9: Ship it

`cef bundle` signs with the identity it detects, or ad hoc with
`--sign -`. Sign with your Developer ID identity (`--sign`), notarize with
`swift package cef notarize`, and check the result with
`swift package cef doctor`. The repository's `docs/bundling.md` covers
signing, entitlements and the Xcode build phase.

## See Also

- ``CefWebView``
- ``CefSwiftApp``
