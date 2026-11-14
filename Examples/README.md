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

A tabbed browser (`Sources/Browser`), composed of features on a small
core. Each feature is a folder of `Features/` written against CefSwift's
public API; CefSwift itself has no notion of a browser.

**The core** (`Core/`) is what every feature relies on:

- `BrowserController`: the tabs, each a Chrome-style `CefWindow` grouped
  with the others as native macOS tabs. It opens tabs (in a private
  profile, or the profile of the tab that opened them), puts each window
  together from the features, shows popups as panels over their opener
  (`PopupPresenter`), and is every tab's `CefBrowserDelegate`, handing
  navigation and permission decisions to the features.
- `BrowserFeature`: the points a feature plugs into, each with a default
  that does nothing.
- `BrowserScene`: the Settings window and the menu bar, filled with the
  features' rows and commands; `CefRuntime.Configuration.browser`.
- Back and forward and the New Tab button, the tab's icon, File › New Tab
  and the View menu's reload, zoom and Developer Tools; what typed text
  means (`TypedAddress`: an address, or a search); the `browser://` scheme
  features serve their pages from (`BrowserPages`); and the launch
  arguments (`LaunchOptions`).

**The features**, listed one per line in `BrowserApp.swift`:

| Feature | What it adds | Built on |
|---|---|---|
| `AddressBar` | The address field: the site, load progress, editing with ranked suggestions (↑ ↓ choose, Return opens, Esc closes) and inline completion; File › Open Location | `CefAutocomplete` |
| `PrivateTabs` | File › New Private Tab, and the field's "Private" badge | `CefProfile.incognito()` |
| `PageInfo` | The field's security badge and page info (connection, certificate, site permissions); the sheet asking whether a site may use the camera, location and the like | `CefSiteSettings`, `CefConnectionSecurity` |
| `Bookmarks` | The star in the field (⌘D) and the Bookmarks menu | `CefBookmarks` |
| `History` | The History menu: back, forward and the latest pages | `CefHistory` |
| `StartPage` | `browser://start/`, which new tabs open: frequently visited sites and recent bookmarks | `CefSchemeHandler`, `CefBridge`, `topSites()` |
| `FindBar` | Edit › Find, a Safari-style bar under the toolbar | `setFindBar`, `CefFindSession` |
| `StatusBubble` | The hovered link's address over the page | `statusText`, `pageOverlay` |
| `SwipeIndicator` | The browser's own back and forward swipe indicator | `navigationGestureProgress`, `pageOverlay` |
| `Appearance` | Settings › Appearance, for the windows and the pages | `CefProfile.setColorScheme` |
| `Downloads` | A toolbar button listing downloads | `CefBrowser.downloads` |
| `TabDiscarding` | Memory Saver: hidden tabs put to sleep after a while or under memory pressure; Settings › Put tabs to sleep; a button that wakes them | `discard()`, `lifecycle` |
| `ChromiumPanels` | QR code and Share buttons, View › Cast, and optionally the browser's own QR code and Cast panels | `CefChromiumSurface`, `CefMediaRouter` |
| `ChromiumPages` | `chrome://settings` without what does nothing in an embedded Chromium, an About page of the browser's own, and a Browser menu of Chromium's pages | `CefUserScript.styleSheet`, navigation policy |
| `Playground` | `browser://playground/` (Help › Playground): popups, a download, a page that asks before leaving, an unreachable site, Widevine and FairPlay test streams | `CefSchemeHandler` |
| `WebKitTabs` | Streaming services (Netflix, Disney+ and others) in tabs shown by the system's WebKit, which plays FairPlay; View › Open in WebKit, and "Open in Chromium" back | `Sources/SystemEngine` |
| `Passkeys` | Passkeys answered by Chromium or by the browser itself, and the saved passkeys, in Settings | `CefPasskeyController` |
| `TaskManager` | Window › Task Manager | `CefTaskManager` |
| `ChromeTabs` | Tabs Chromium opens itself, shown as the browser's own | `CefRuntime.onChromeTab` |
| `SingleInstance` | Launching the app again opens a tab, or one for each URL or file passed | `CefRuntime.onRelaunch` |

`Sources/SystemEngine` (`SystemBrowser`, `SystemWebView`) is a small
`WKWebView` wrapper on CefKit's public API, for pages that need FairPlay or
H.264 and AAC, which Chromium in CefSwift does not have.

### Adding or removing a feature

A feature is a type conforming to `BrowserFeature` that implements only
the points it uses (`Core/BrowserFeature.swift`): `start(_:)` once
Chromium runs; `configure(_:)` for each new tab's
`CefBrowser.Configuration`; `windowDidOpen(_:)` for each tab and popup
window; `decidePolicy(for:in:)` and `decidePermission(for:in:)`, which
return `nil` to leave the decision to the features after it; and views and
commands: `commands(for:)`, `settings`, `toolbarItems(_:for:)` and
`pageOverlay(for:)`. `FindBar` is a whole feature:

```swift
struct FindBar: BrowserFeature {
    func windowDidOpen(_ window: CefWindow) {
        window.setFindBar { session in Bar(session: session) }
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { controller.current?.execute(.find) }.keyboardShortcut("f")
        }
    }

    private struct Bar: View { … }
}
```

Add a folder for it under `Features/` and a line to `BrowserApp.features`;
the order of the lines is the order of the toolbar items, menu commands and
settings. Toolbar and overlay views can read the `BrowserController` from
the environment. To remove a feature, delete its line and its folder (and
its tests, for `TabDiscarding`). The address field shows the other
features' `.addressField…` items, so without `AddressBar` they have
nowhere to appear; without `StartPage`, new tabs open `about:blank`.

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

## Xcode

`Xcode/XcodeExample.xcodeproj` is a SwiftUI app built by Xcode rather than
SwiftPM: one `CefWebView`, as in Minimal. It depends on the CefSwift
checkout as a local package and is set up as
[the README](../README.md#with-xcode) describes: App Sandbox off,
[`CefSwift.xcconfig`](Xcode/CefSwift.xcconfig) as the target's
configuration file, and the CefSwift Run Script phase. It signs ad hoc
("Sign to Run Locally"), so it builds without a team.

Open it in Xcode and Run, or build, run, archive and export it from the
command line:

```sh
Scripts/check-xcode-example.sh
```

The script builds Debug and Release with `xcodebuild`, archives and exports
the app (`ExportOptions.plist`, method `mac-application`, which copies the
app as it is signed), launches each with `-smoke YES` (load the page, print
`PASS loaded …`, quit), and runs `cef doctor` on the exported app. It keeps
its derived data in `Examples/Xcode/build`; delete it afterwards.
