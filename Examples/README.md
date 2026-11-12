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
`CefBrowserWindow`, and the tabs are grouped as native macOS tabs.

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
  (`ChromiumPanels.swift`).
- Two-finger swipes go back and forward, with CefSwift's swipe indicator.
- A bookmark star (⌘D), Bookmarks and History menus, and a start page at
  `browser://start/` with frequently visited sites and recent bookmarks,
  whose data comes through a `CefBridge`.
- Site icons on tabs, on "Switch to Tab" suggestions and on the start
  page's tiles; the page as an inset card; and popups as panels layered over
  the window that opened them.
- Private tabs, downloads, and a customized context menu.
- Passkeys answered by Chromium or by the browser itself, chosen in
  Settings, which also lists and removes the browser's saved passkeys.
- `chrome://settings` without what does nothing in an embedded Chromium
  (sign-in, default browser, and the Appearance options for Chrome's own
  toolbar, tab strip and bookmarks bar), and an About page of its own in
  place of Chromium's.
- Tabs that Chromium opens itself, shown as the app's own tabs.
- Streaming services (Netflix, Disney+ and others) in tabs shown by the
  system's WebKit, which plays FairPlay-protected video, marked with a
  WebKit badge; View › Open in WebKit moves any page there, and the tab's
  "Open in Chromium" button moves it back.
- A single instance: launching the app again while it runs opens a new tab,
  or a tab for each URL or file path passed on the command line.

`browser://playground/` has popups, a download, a page that asks before
leaving, an unreachable site, a Widevine-protected test stream that plays in
Chromium, and a link to a FairPlay test player to open in WebKit.

## Showcase

Embedding web content in SwiftUI with the `.embedded` configuration
(`Sources/Showcase`). Its sidebar has three demos:

- **Web View**: a windowed browser with observable state.
- **Native Overlay**: SwiftUI content over an offscreen page, with a
  swipe-to-navigate indicator.
- **JavaScript Bridge**: a typed bridge to a page served from a custom
  scheme.

## Minimal

The smallest CefSwift app (`Sources/Minimal`): one window with one
`CefWebView`, on the `.embedded` configuration. `-url <address>` shows
another page, `-cacheDirectory <path>` keeps Chromium's data there,
`-sandbox YES` runs its helpers in Chromium's sandbox, and
`-memoryPolicy standard|reduced|minimal` chooses a `CefMemoryPolicy`, and
`-protectedMedia YES` lets Chromium fetch Widevine.

## Compat

One page in one kind of host with chosen CefSwift features on
(`Sources/Compat`), for the web-compatibility matrix that
`Scripts/compat-matrix.py` runs: what pages can observe about each host
and feature, next to stock Google Chrome. `-host window|windowed|offscreen`
picks a `CefBrowserWindow` or a view, `-preset default|browser|embedded`
the configuration, and `-features` a comma-separated list of `devtools`,
`runtime`, `page`, `bridge`, `anyframe`, `userscript`, `evaluate`,
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
Accessibility permission.

## Launch arguments

Browser and Showcase can start in a given state, for trying things out and
for automated screenshots. Arguments are read as user defaults
(`-key value`).

```sh
# Showcase: open a demo ("Web View", "Native Overlay" or "JavaScript Bridge").
Examples/dist/Showcase.app/Contents/MacOS/Showcase -demo "JavaScript Bridge"

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
