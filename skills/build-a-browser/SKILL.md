---
name: build-a-browser
description: Build a complete macOS web browser in Swift on Chromium with CefSwift, from an empty folder to a bundled app that opens. Use when the user asks for a browser, an Arc- or Chrome-like app, vertical tabs, spaces, a command bar, or browser features (tabs, address bar, bookmarks, history, extensions, downloads, find, private windows, passkeys, streaming) built on CefSwift or Chromium in Swift.
---

# Build a browser with CefSwift

A CefSwift browser is Chromium's own tabbed windows (`CefChromeWindow`)
with Chrome's tab strip and toolbar covered by your SwiftUI. Chromium keeps
the tabs, history, bookmarks, suggestions, extensions and downloads; you
draw them and send commands. Most browser features are a view over an API
that already exists. Write UI, not browser engine code.

Also load the `cefswift` skill if it is installed: it has the module, host
and bundling rules and an API cheat sheet.

## Rules that keep it running

1. Never `swift run`. Build with
   `swift package --allow-writing-to-package-directory --allow-network-connections all cef bundle --product <App>`
   and launch `open dist/<App>.app`.
2. No App Sandbox entitlement. No Mac App Store.
3. `@main` conforms to `CefSwiftApp`, not `App`, with
   `runtimeConfiguration` based on `.chrome`.
4. Platform `.macOS(.v15)` for the package (SwiftUI's `WindowDragGesture`
   and `defaultLaunchBehavior` need it).
5. Browser windows come from `CefChromeWindow.open`, not from a SwiftUI
   `WindowGroup`. The app's only scene is `Settings`, with
   `.defaultLaunchBehavior(.suppressed)`.
6. Dress windows in `CefProfile.default.tabs.onWindowOpened`, so windows
   Chromium opens itself (a tab dragged out, ⌘⇧T on a window, an
   extension) get your UI too.
7. Keep no list of tabs. Read `window.tabs`, `window.activeTab`,
   `profile.tabs.windows`; they are `@Observable` and follow Chromium.
8. Views that show page state read it in their own `body`
   (`TabButton(tab:)`, `Toolbar(page:)`), since `setTopBar`'s closure runs
   once.

## Steps

1. Create the package from [references/starter.md](references/starter.md),
   five files: `Package.swift`, `cefapp.json`, `MyBrowserApp.swift`,
   `Browser.swift`, `TopBar.swift`. Rename `MyBrowser` to the app's name.
   The starter already has private windows (⌘⇧N); note that
   `onWindowOpened` is per profile, so a new profile needs its own.
2. Bundle and open it (rule 1). The first bundle downloads CEF (about
   135 MB) and compiles CefSwift: several minutes. Fix compile errors and
   rerun until `dist/<App>.app` exists.
3. Check it opens: `open dist/<App>.app`, then confirm the process runs
   (`pgrep -x <App>`) and look at the window: your tab strip must cover
   Chrome's. For logs, run `dist/<App>.app/Contents/MacOS/<App>` from a
   terminal instead.
   If Chrome's own tab strip and toolbar show (your bar never appears) and
   the log says `Chromium did not open the window`, `CefChromeWindow.open`
   timed out waiting for CefChromium's hidden service hosts to read
   Chromium's tab model, so the window was never dressed. Windows titled
   `chrome://bookmarks/strings.m.js#cefswift-service` that show
   `ERR_FAILED` are those hosts failing to load. Quit (`pkill -x <App>`)
   and open the app again once. If it happens again, it is not your code:
   stop, report the log lines to the user, and check the Gallery
   (`Gallery -demo TabStripDemo` in a CefSwift checkout) on the same Mac.
4. Add features one at a time from the checklist below, rebundling after
   each. Add `.product(name: "CefPasskeys", package: "CefSwift")` only if
   passkeys are wanted.
5. Layout and power features: [references/recipes.md](references/recipes.md)
   has vertical tabs (Arc-style sidebar), spaces and a command bar.

## Feature checklist

Each row is already in CefSwift. The Browser example has a complete
version of each to read before writing your own:
`https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/<Folder>`
(raw files at `https://raw.githubusercontent.com/Rajaniraiyn/CefSwift/main/Examples/Sources/Browser/…`).
Signatures of the calls below: the `cefswift` skill's `references/api.md`.

| Feature | API | Browser example |
|---|---|---|
| Tabs, groups, pinning, reorder, drag between windows | `CefChromeWindow.tabs`, `groups`, `openTab`, `CefTab.select/close/pin/move(to:in:)`, `profile.tabs.group(_:)`, `CefTab.Transfer` (drag) | `Core/TabRail` |
| Vertical tabs | `profile.tabs.layout = .vertical(width:)` + `window.setSidebar` | `Core/BrowserWindow.swift` |
| New tab, close, reopen closed | `window.openTab`, `tab.close()`, `window.reopenClosedTab()`, `profile.tabs.recentlyClosed`, `reopen(_:)` | `Core/BrowserScene.swift` |
| Back, forward, reload, zoom | `page.goBack()`, `goForward()`, `reload()`, `zoomLevel`, `zoom(.zoomIn)` | `Core/Toolbar.swift` |
| Address field with suggestions | `profile.autocomplete.results(for:)` (stream; latest query wins) | `AddressBar` |
| Security badge, page info, site permissions | `CefConnectionSecurity`, `profile.siteSettings` | `PageInfo` |
| Permission prompts (camera, location) | `CefPageDelegate.page(_:decidePermissionFor:)` or `CefProfileDelegate` | `PageInfo` |
| Bookmarks, ⌘D | `profile.bookmarks` (`add`, `tree`, `recent`, `bookmarks(for:)`, `remove`, `changes`) | `Bookmarks` |
| History menu, top sites | `profile.history` (`search`, `entries`, `topSites`, `favicon(for:size:)`) | `History`, `StartPage` |
| Start page | `CefSchemeHandler` on a custom scheme + `CefBridge` | `StartPage` |
| Find (⌘F) | `window.setFindBar { session in … }` (`CefFindSession`), `page.execute(.find)` | `FindBar` |
| Hovered-link status | `page.statusText`, `window.setPageOverlay` | `StatusBubble` |
| Downloads | `profile.downloads`, `page.downloads`, `profile.downloadPolicy` | `Downloads` |
| Extensions, Web Store, action popups | `profile.extensions` (`installed`, `setEnabled`, `uninstall`, `loadUnpacked`), `CefExtension.action` | `Extensions` |
| Private windows (⌘⇧N) | `CefChromeWindow.open(url:profile: CefProfile.incognito())` | `PrivateTabs` |
| Profiles (work, personal) | `CefProfile.persistent(id:displayName:)` | `PrivateTabs` (pattern) |
| Restore windows after quit or crash | `profile.tabs.previousSession`, `restorePreviousSession()` | `Core/RestorePrompt.swift` |
| Sleeping tabs | `tab.discard()`, `page.lifecycle`, `isDiscarded` | `TabDiscarding` |
| Swipe back and forward | `CefPage.Configuration.allowsBackForwardNavigationGestures`, `navigationGestureProgress` | `SwipeIndicator` |
| QR code, share, Cast | `chromiumSurfaceAnchor`, `setCustomPresentation(for:)`, `CefMediaRouter` | `ChromiumPanels` |
| `chrome://settings` and other internal pages | `page.execute(.showSettings)`, `CefUserScript.styleSheet` on `chrome://` | `ChromiumPages` |
| Sign in with Google | Works as in Chrome, nothing to add (verified by hand) | – |
| Passkeys | Chromium's by default; `CefPasskeyController` (CefPasskeys) for your own UI | `Passkeys` |
| Streaming (Netflix, Disney+) | A `WKWebView` window beside Chromium (FairPlay) | `WebKitTabs` |
| Task manager | `CefTaskManager` | `TaskManager` |
| Open links from other apps, single instance | `CefRuntime.shared.onRelaunch`, the `defaultBrowser` capability | `SingleInstance` |
| Light and dark pages | `profile.setColorScheme(_:accentColor:)` | `Appearance` |
| DevTools | `page.execute(.showDevTools)`, `page.showDevTools()` | `Core/BrowserScene.swift` |

## Do not

- Do not keep your own history, bookmark store, suggestion ranking or tab
  list. Chromium has them: `profile.history`, `profile.bookmarks`,
  `profile.autocomplete`, `window.tabs`. Your copy would miss what Chrome's
  UI, shortcuts and extensions change.
- Do not write an extension system. `profile.extensions` is Chrome's; the
  Web Store's "Add to Chrome" works in `CefChromeWindow`.
- Do not build tabs from several `CefWindow`s or `CefWebView`s. They are
  not Chromium tabs, so extensions, ⌘⇧T and history see none of them.
- Do not try to play Netflix-class streaming in Chromium: no H.264, HEVC,
  AAC, and Widevine only as L3. Open those sites in a WebKit window
  (`WKWebView`, FairPlay), as the Browser example's `WebKitTabs` does.
- Do not write a WebAuthn implementation. Chromium answers passkeys;
  `CefPasskeyController` in CefPasskeys if the app must answer them.
- Do not put interactive UI in `setPageOverlay`: it never takes events.
  Use the top bar, the sidebar, or a child `NSPanel` (the command bar
  recipe).
- Do not add the App Sandbox entitlement, and do not `swift run`.

## Architecture to grow into

The Browser example (`Examples/Sources/Browser` in the CefSwift repository,
about 5,600 lines) is a small core plus a folder per feature:

- `Core/BrowserController.swift`: the windows (from `CefTabs`), opening
  windows and tabs with the features' page configuration, and the
  `CefPageDelegate` of every tab, which hands navigation and permission
  decisions to the features in order.
- `Core/BrowserWindow.swift`: dresses each `CefChromeWindow`: top bar
  (tab rail and toolbar) or sidebar, page overlay.
- `Core/BrowserFeature.swift`: the protocol a feature implements, all
  optional: `start`, `configure(_:)` (each tab's `CefPage.Configuration`),
  `windowDidOpen`, `decidePolicy`, `decidePermission`, `commands`,
  `settings`, `toolbarItems(_:for:)`, `pageOverlay(for:)`.
- `BrowserApp.swift`: one line per feature. Delete a line and its folder to
  remove it.

Start with the starter's three Swift files. When the app has more than four or
five features, move to this shape.

## Done when

- `dist/<App>.app` exists and `open` shows a window with your tab strip
  over a loaded page.
- New tab, close tab, switching tabs and typing an address work.
- Each feature the user asked for maps to a row above and uses that API.
