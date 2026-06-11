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
- **`chrome://` internals — with a big caveat.** CEF forces **Alloy style**
  for browsers embedded via a parent NSView (i.e. every `CefWebView`), and
  several Chrome WebUI pages need a real Chrome-style *window* to render
  content. Verified behavior in CefSwift-embedded views (CEF 148; each page
  loaded via `Browser --open-url` and screenshot-inspected):

  | Page | Embedded (`CefWebView`) result |
  |---|---|
  | `chrome://version` | ✅ works — full build/flag diagnostics |
  | `chrome://gpu` | ✅ works — graphics feature status + report download |
  | `chrome://process-internals` | ✅ works — renderer/process info |
  | `chrome://net-internals` | ✅ works — DNS/sockets/proxy tools |
  | `chrome://net-export` | ✅ works — network log capture UI |
  | `chrome://about` (alias `chrome://chrome-urls`) | ✅ works — lists all pages |
  | `chrome://history` | ⚠️ loads but renders a **blank page** |
  | `chrome://extensions` | ⚠️ blank page |
  | `chrome://settings` | ⚠️ blank page |
  | `chrome://downloads` | ⚠️ blank page |
  | `chrome://flags` | ⚠️ blank page |

  The blank pages are tab-scoped Chrome UI that requires the Chrome browser
  *window* machinery embedded views never get. The underlying services still
  run (history is recorded, downloads proceed — surfaced natively through
  `CefBrowserDelegate`'s download methods); only those management UIs don't
  render. The Browser example's Chrome menu lists exactly the working set.

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
- **Downloads:** decide per download (`.allow(destination:)`/`.deny`) and
  observe progress via `CefBrowserDelegate` /
  `CefWebViewModel.onDownloadDecision`/`onDownloadProgress`
  (see [configuration.md](configuration.md)).
- **Custom schemes + JS ↔ Swift bridge:** serve `myapp://` content from Swift
  (`CefConfiguration.customSchemes` + `registerSchemeHandler`) and call Swift
  functions from page JS (`CefRuntime.shared.bridge`,
  see [js-bridge.md](js-bridge.md)).
- Arbitrary Chromium switches and command-line hooks for everything else.

The **Browser** example (`Examples/Sources/Browser`) is the reference
implementation: tab strip, omnibox with search fallback, progress, favicons,
popup-to-new-tab, DevTools menu, and a `chrome://` pages menu.

## What's not exposed yet (roadmap)

- **Context-menu customization** — Chrome's default menus appear; injecting
  your own items isn't surfaced yet.
- **Chrome-style windows** — the tabbed Chrome window UI (which would make
  chrome://history/extensions/settings render) isn't exposed; CefSwift
  embeds browsers as NSViews, which CEF pins to Alloy style.
- **Extension management UI** — `chrome://extensions` renders blank when
  embedded (see the table above).
- **Reading/writing history & bookmarks programmatically** — no Swift API
  over them yet (and the `chrome://history` UI doesn't render embedded).
- **Per-tab throttling/discarding controls.**

## When to use alloy instead

If a view should behave like *content*, not a browser — a dashboard card, a
docs pane, an HTML-rendered report — use `.alloy`
(`CefBrowserOptions.runtimeStyle = .alloy`). It skips Chrome's browser
machinery: no extensions, no `chrome://`, lighter weight, everything
delegate-driven. The Gallery example shows both styles side by side.
