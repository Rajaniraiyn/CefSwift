# Examples

Three apps built on CefSwift. Bundle and run one from the repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Browser --output dist
open Examples/dist/Browser.app
```

| App | Shows |
|---|---|
| **Browser** | A tabbed browser: Chrome-style `CefBrowserWindow`s grouped as native tabs, a three-part SwiftUI toolbar with an address field that shows the site and its security and edits the full address, tab icons, the page as an inset card, popups as panels layered over their opener, private tabs, downloads, a customized context menu, `chrome://settings` trimmed to what works in an embedded Chromium, an About page of its own in place of Chromium's, and tabs Chromium opens itself shown as its own tabs. `browser://playground/` has popups, a download, a page that asks before leaving and an unreachable site to try. |
| **Showcase** | Embedding in SwiftUI with the lean `.embedded` configuration: observable browser state, native UI over an offscreen page with a swipe-to-navigate indicator, and a typed JavaScript bridge to a page served from a custom scheme. |
| **SelfTest** | End-to-end checks against the real Chromium runtime. Prints one line per check, quits through `cef_shutdown()` and exits with the number of failures; CI runs it. |

## Launch arguments

Both apps can start in a given state, for trying things out and for
automated screenshots:

```sh
# Showcase: open a demo ("Web View", "Native Overlay", "JavaScript Bridge").
Examples/dist/Showcase.app/Contents/MacOS/Showcase -demo "JavaScript Bridge"

# Browser: open tabs, run JavaScript in the last one once it has loaded,
# start editing the address, force an appearance.
Examples/dist/Browser.app/Contents/MacOS/Browser \
    -urls "https://swift.org browser://playground/" \
    -evaluate "openPopup()" -focusAddressBar YES -appearance dark
```

`-evaluate` takes a script that does not start with `(` (Cocoa would read
that as a list); prefix such a script with `void `.
