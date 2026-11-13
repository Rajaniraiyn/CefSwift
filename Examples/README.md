# Examples

Five apps built on CefSwift, in a package of their own that depends on the
checkout above it. They need macOS 15. Bundle and run one from the
repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Browser
open Examples/dist/Browser.app
```

## Browser

A tabbed browser (`Sources/Browser`). Each tab is a Chrome-style
`CefWindow`, and the tabs are grouped as native macOS tabs.

- A SwiftUI toolbar in three parts. The address field shows the site and its
  security, edits the full address, and offers Chromium-ranked suggestions
  as you type: ↑ and ↓ choose, Return opens, Esc closes. The top
  suggestion completes the address inline, selected after the caret:
  typing on keeps what still matches, Delete removes the completion,
  Return opens it and Esc goes back to what you typed.
- Chromium's interface, arranged around the toolbar: the QR code bubble
  hangs from its button, the Share button opens macOS's share menu, and
  Cast and Chromium's other toolbar bubbles hang from the address field.
  The find bar (⌘F) and the link status bubble are the browser's own
  SwiftUI views; with "Use the browser's QR code and Cast panels" in
  Settings, so are the QR code bubble and the Cast picker
  (`ChromiumPanels.swift`). These, and the suggestions, bookmarks and
  history below, use the `CefChromium` library.
- Two-finger swipes go back and forward, with the browser's own swipe
  indicator (`SwipeIndicator.swift`) laid over the page in the window's
  `pageOverlay`, in place of Chromium's arrow.
- A bookmark star (⌘D), Bookmarks and History menus, and a start page at
  `browser://start/` with frequently visited sites and recent bookmarks,
  whose data comes through a `CefBridge`.
- Site icons on tabs, on "Switch to Tab" suggestions and on the start
  page's tiles; the page as an inset card; and popups as panels layered over
  the window that opened them.
- Private tabs, downloads, and a customized context menu.
- Passkeys answered by Chromium or by the browser itself (a
  `CefPasskeyController` from the `CefPasskeys` library), chosen in
  Settings, which also lists and removes the browser's saved passkeys.
- `chrome://settings` without what does nothing in an embedded Chromium
  (sign-in, default browser, and the Appearance options for Chrome's own
  toolbar, tab strip and bookmarks bar), and an About page of its own in
  place of Chromium's.
- Tabs that Chromium opens itself, shown as the app's own tabs.
- Streaming services (Netflix, Disney+ and others) in tabs shown by the
  system's WebKit, which plays FairPlay-protected video, marked with a
  WebKit badge; View › Open in WebKit moves any page there, and the tab's
  "Open in Chromium" button moves it back. The WebKit side
  (`Sources/SystemEngine`: `SystemBrowser`, `SystemWebView`) is a small
  `WKWebView` wrapper on CefKit's public API, for pages that need FairPlay
  or H.264 and AAC, which Chromium in CefSwift does not have.
- Memory Saver (Settings › Put tabs to sleep): tabs hidden for 15 minutes
  or an hour, or every hidden tab when macOS reports memory pressure, are
  discarded with `CefBrowser.discard()` and dimmed in the toolbar
  (`TabDiscarding.swift`). The timing and selection are the browser's own
  policy, unit-tested by `swift test --package-path Examples`.
- A single instance: launching the app again while it runs opens a new tab,
  or a tab for each URL or file path passed on the command line.

`browser://playground/` has popups, a download, a page that asks before
leaving, an unreachable site, a Widevine-protected test stream that plays in
Chromium, and a link to a FairPlay test player to open in WebKit.

## Gallery

A library of small examples (`Sources/Gallery`), each showing one
capability in one file of SwiftUI and CefSwift code you can copy:
`Demos/<Name>Demo.swift`. The sidebar groups them; the detail shows the
running demo, what it shows, and its file.

- **Web Views**: observable state and awaited loads; offscreen rendering
  under SwiftUI; swipe navigation with the app's own indicator;
  `CefWindowedBrowserView` in an `NSViewRepresentable`, without CefSwiftUI.
- **Page**: find in page (`CefFindSession`); the context menu; PDF and
  printing; DevTools and the DevTools Protocol.
- **JavaScript**: `evaluateJavaScript`; a typed `CefBridge` both ways;
  user scripts and style sheets; frames.
- **Content and Network**: a custom scheme serving the app's resources;
  requests through Chromium's network stack; profiles and cookies;
  permissions and site settings; downloads.
- **Chrome-Style Windows**: a `CefWindow` with a SwiftUI toolbar; Chromium's
  find bar, status bubble and QR code bubble replaced with SwiftUI.
- **Runtime**: the task manager; discarding and restoring; the media
  router's devices.
- **Chromium Data** (`CefChromium`): bookmarks, history and address
  suggestions.
- **Passkeys** (`CefPasskeys`): passkeys answered from an in-memory store.

Every demo works offline. Pages come from a `gallery://` scheme handler,
and those that need real HTTP (cookies, permissions, passkeys, downloads,
requests) from a small server on `localhost` (`Support/`). The one runtime
configuration is the `.chrome` preset with offscreen rendering on, as
Chrome-style windows, Chromium's data and the media router need, and a
mock keychain, so no keychain prompt appears.

To add a demo, write a type that conforms to `Demo` (title, summary,
symbol, category, `makeView()`) in `Demos/`, and list it in `Demos.all`.

`-smoke` (or `GALLERY_SMOKE=1`) opens every demo in turn, waits until it
reports ready (its pages loaded, or its own work done), prints
`PASS <demo>` or `FAIL <demo> — <reason>` and a `SUMMARY` line, and quits
with the number of failures as its exit status. A demo also fails if it
leaves a browser or window open. `GALLERY_SMOKE_ONLY=BridgeDemo,RequestsDemo`
runs only those. It keeps Chromium's data in a temporary directory.

## Minimal

The smallest CefSwift app (`Sources/Minimal`): one window with one
`CefWebView`, on the `.embedded` configuration. `-url <address>` shows
another page, `-cacheDirectory <path>` keeps Chromium's data there,
`-sandbox NO` runs its helpers outside Chromium's sandbox,
`-processPolicy automatic|onDemand|minimal` chooses a
`CefRuntime.ProcessPolicy`, and `-protectedMedia YES` lets Chromium fetch
Widevine.

## Compat

One page in one kind of host with chosen CefSwift features on
(`Sources/Compat`), for the web-compatibility matrix that
`Scripts/compat-matrix.py` runs: what pages can observe about each host
and feature, next to stock Google Chrome. `-host window|windowed|offscreen`
picks a `CefWindow` or a view, `-preset default|chrome|embedded`
the configuration, and `-features` a comma-separated list of `devtools`,
`runtime`, `page`, `bridge`, `userscript`, `evaluate`,
`passkeys` and `accessibility`. The script's documentation lists the rest.

```sh
swift package --package-path Examples --allow-writing-to-package-directory \
    --allow-network-connections all cef bundle --product Compat
Scripts/compat-matrix.py probe --out /tmp/compat
Scripts/compat-matrix.py table --out /tmp/compat
```

## SelfTest

End-to-end checks against the real Chromium runtime (`Sources/SelfTest`).
It prints one line per check, quits through `cef_shutdown()`, and exits with
the number of failures. CI runs it; [CONTRIBUTING](../CONTRIBUTING.md#verify-with-selftest)
describes running it locally.

`SELFTEST_ONLY=<group>[,<group>…]` runs only the named groups of checks
(`SelfTest.checkGroups` lists them), such as `SELFTEST_ONLY=passkeys`.
`SELFTEST_ONLY=accessibility` runs only the offscreen accessibility
checks, and adds `NOTE` lines measuring a large page's load with and
without the tree. `SELFTEST_ONLY=accessibility-external` instead shows the
accessibility test page without reading it, prints `READY <pid>`, and
waits `SELFTEST_AX_HOLD` seconds (15 by default) for a separate process to
read it through the `AXUIElement` API, which needs that process to have
Accessibility permission. `SELFTEST_ISOLATED`, `SELFTEST_STRICT` and
`SELFTEST_JSON` are described in
[CONTRIBUTING](../CONTRIBUTING.md#verify-with-selftest).

## Launch arguments

Browser and Gallery can start in a given state, for trying things out and
for automated screenshots. Arguments are read as user defaults
(`-key value`).

```sh
# Gallery: open a demo, by the name of its type.
Examples/dist/Gallery.app/Contents/MacOS/Gallery -demo BridgeDemo

# Gallery: open every demo in turn; the exit status is the number of failures.
Examples/dist/Gallery.app/Contents/MacOS/Gallery -smoke

# Browser: open tabs, run JavaScript in the last one once it has loaded,
# start editing the address, and force an appearance.
Examples/dist/Browser.app/Contents/MacOS/Browser \
    -urls "https://swift.org browser://playground/" \
    -evaluate "openPopup()" -focusAddressBar YES -appearance dark

# Browser: a private tab with "swift" typed into the address field, which
# shows its suggestions. Without -urls, tabs open the start page.
Examples/dist/Browser.app/Contents/MacOS/Browser -private YES -addressBarText swift
```

| Browser argument | Effect |
|---|---|
| `-urls "<url> <url> …"` | Opens each as a tab. |
| `-evaluate "<script>"` | Runs JavaScript in the last tab once it has loaded. |
| `-focusAddressBar YES` | Starts with the address field editing. |
| `-addressBarText <text>` | Starts editing with that text typed. |
| `-private YES` | Opens the tabs as private tabs. |
| `-appearance light\|dark\|system` | Overrides the appearance setting. |
| `-showTaskManager YES` | Opens the Task Manager window. |
| `-showPageInfo YES` | Opens the page info of the first secure page shown. |
| `-customChromiumPanels YES` | Uses the browser's QR code and Cast panels, as the setting does. |
| `-cacheDirectory <path>` | Keeps Chromium's data there instead of in Application Support. |

Minimal and Browser also take `-benchmark YES`: the app prints
`cefswift-benchmark loaded <seconds since 1970>` when its first page
finishes loading, and quits when standard input closes.
[`Scripts/measure-footprint.py`](../Scripts/measure-footprint.py) uses it to
measure launch time, process count and memory:

```sh
Scripts/measure-footprint.py Examples/dist/Minimal.app
Scripts/measure-footprint.py Examples/dist/Browser.app -- --js-flags=--lite-mode
```

Cocoa reads a value that starts with `(` as a list, so prefix such a script
with `void `.
