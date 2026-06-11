# Building a full browser: the Chrome runtime style

CefSwift defaults to CEF's **Chrome runtime style**: each browser view is
backed by Chrome's real browser machinery rather than the bare rendering
engine. This is what makes an Arc-class browser feasible on CefSwift rather
than merely a web view.

## What Chrome style gives you

- **Real tab semantics.** Every `CefBrowser` is a Chrome tab under the hood,
  with Chrome's session, navigation, and lifecycle behavior. Your SwiftUI tab
  strip (one `CefWebViewModel` per tab, like the Browser example) maps 1:1
  onto genuine Chrome tabs.
- **Extensions.** Chrome extensions can be installed and run; visit
  `chrome://extensions` to manage them.
- **`chrome://` internals.** Navigate any browser to Chrome's internal pages:

  | Page | What it is |
  |---|---|
  | `chrome://history` | Full browsing history UI |
  | `chrome://extensions` | Extension management |
  | `chrome://settings` | Chrome settings surface |
  | `chrome://downloads` | Download manager |
  | `chrome://version` | Build/flag diagnostics |
  | `chrome://gpu` | GPU feature status |
  | `chrome://net-export` | Network logging |

- **Profiles.** Chrome's profile model backs `rootCachePath`/`cachePath`, so
  separate profiles (work/personal, per-space) are separate cache paths.
- **Browser-grade behavior for free:** permission prompts, HTTPS interstitials,
  PDF viewer, autofill plumbing, find-in-page, print preview machinery —
  Chrome's implementations, not reimplementations.

## What CefSwift exposes today (v1)

- Chrome-style browsers as SwiftUI views (`CefWebView` /
  `CefBrowserFactory.createBrowser`), windowed (native NSView) embedding.
- Navigation + state: URL/title/loading/progress/back/forward/favicon via
  `CefWebViewModel` or `CefBrowserDelegate`.
- Popup routing: decide `.allow` / `.block` / `.openInSameBrowser` per popup —
  the Browser example turns popups into new tabs.
- DevTools: `browser.showDevTools()` / `closeDevTools()`, plus the
  `remoteDebuggingPort` configuration for CDP automation.
- Zoom, audio mute, find-in-page, JavaScript execution
  (`executeJavaScript(_:)`, fire-and-forget), console message observation.
- Arbitrary Chromium switches and command-line hooks for everything else.

The **Browser** example (`Examples/Sources/Browser`) is the reference
implementation: tab strip, omnibox with search fallback, progress, favicons,
popup-to-new-tab, DevTools menu, and a `chrome://` pages menu.

## What's not exposed yet (roadmap)

- **Context-menu customization** — Chrome's default menus appear; injecting
  your own items isn't surfaced yet.
- **Download UI hooks** — downloads follow Chrome defaults;
  a delegate surface is planned.
- **JS ↔ Swift bridging** — typed message ports between page JS and Swift.
- **Reading/writing history & bookmarks programmatically** — today you get
  the `chrome://history` UI, not a Swift API over it.
- **Per-tab throttling/discarding controls.**

## When to use alloy instead

If a view should behave like *content*, not a browser — a dashboard card, a
docs pane, an HTML-rendered report — use `.alloy`
(`CefBrowserOptions.runtimeStyle = .alloy`). It skips Chrome's browser
machinery: no extensions, no `chrome://`, lighter weight, everything
delegate-driven. The Gallery example shows both styles side by side.
