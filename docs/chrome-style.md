# Building a full browser: hosting modes & the Chrome runtime

CefSwift can power anything from a single embedded web card to a full
Arc/Atlas-class browser. Which you build comes down to **how the CEF browser is
hosted** — and that choice is constrained by a hard Chromium fact:

> **CEF/Chromium binds a Chrome-runtime browser's compositor to its own
> `NSWindow`.** Native-parent (`parent_view`) embedding forces *Alloy* style on
> macOS, and plain NSView reparenting of a Chrome browser blanks rendering.

So CefSwift ships **three hosting modes**, each proven with screenshots. Pick by
what you're building:

| Mode | Type | Chrome runtime (`chrome://`, extensions, profiles) | Native UI *over* the page | Use it for |
|---|---|---|---|---|
| **Chrome-runtime window** ⭐ | `CefChromeWindow` | ✅ full | ✅ SwiftUI overlay in the same window | A full browser (Arc-class) |
| **Windowed Alloy** | `CefWebView` | ⚠️ partial (see table) | ❌ (CEF draws the region) | Embedded web content, dashboards |
| **Chrome-style child window** | `CefChromeWebView` | ✅ full | ❌ (it's an overlay window) | A Chrome view inside an existing SwiftUI window |

---

## ⭐ `CefChromeWindow` — the full-browser mode (recommended)

This is CefSwift's flagship hosting mode (the *inverted-ownership* model). One
real `NSWindow`, no child-window overlay, no frame-syncing:

- It's a **CEF Views top-level window** (`cef_window` + `cef_browser_view`,
  Chrome style, Chrome's own toolbar hidden via `CEF_CTT_NONE`). CEF creates and
  owns the window — which is exactly what unlocks Chrome style.
- Your **SwiftUI chrome** (tab strip, omnibox, …) is hosted in an
  `NSHostingView` added as a subview of the CEF window's content view, stacked
  **above** the browser region. Native UI composites on top of the live page.
- The page is **inset, not covered**: `setContentInsets(_:)` reserves space by
  *resizing the browser view* within the window (via a CEF `BoxLayout`), so web
  content fills the area below your toolbar — the real Arc/Chrome layout.
- The full Chrome runtime renders. **`chrome://history`,
  `chrome://extensions`, `chrome://settings`, `chrome://downloads`,
  `chrome://flags`** — the WebUI pages that are blank in Alloy embedding — all
  work here, as do extension installs and Chrome profiles.

```swift
let window = CefChromeWindow.open(
    url: URL(string: "https://example.com")!,
    initialBounds: CGRect(x: 160, y: 160, width: 1180, height: 800)
) { window in
    window.setContentInsets(NSEdgeInsets(top: 96, left: 0, bottom: 0, right: 0))
    window.setOverlay { MyArcChrome() }   // tab strip + omnibox, on top
}
```

### How overlays + insets fit together

The overlay `NSHostingView` is stretched across the whole window. Your SwiftUI
view should paint an **opaque toolbar in the top inset strip** (e.g. the top 96
pt) and be **transparent below**, so the page shows through and stays
interactive. CefSwift's overlay host forwards clicks that land on transparent
(non-control) regions down to the browser view, so taps over the page reach the
page while taps on your toolbar/tab strip hit SwiftUI.

```
┌──────────────────────────────────────────┐  ← one NSWindow (CEF-owned)
│  ▒▒ SwiftUI overlay: toolbar + tab strip ▒▒│  ← opaque, top inset (96pt)
├──────────────────────────────────────────┤
│                                            │
│        Chrome-runtime web content          │  ← browser view, inset below
│        (chrome://… renders here)           │
│                                            │
└──────────────────────────────────────────┘
```

`setContentInsets(_:)` and `setOverlay(_:)` are safe to call again at any time
(e.g. when your toolbar height changes). On window resize the overlay tracks the
window automatically and the BoxLayout keeps the browser view inset.

### App model: CEF owns the window

Because CEF — not SwiftUI — owns this `NSWindow`, the window lives **outside
SwiftUI's `Scene` graph**. This is expected and correct for a browser shell;
don't try to declare it in a `WindowGroup`. The clean pattern:

1. Bootstrap CEF with `CefSwiftApp` as usual.
2. Hold an app-level **`CefChromeWindowController`** (`@State` / `@Observable`),
   or your own controller object.
3. Open chrome windows from it once the runtime is up — e.g. from a tiny
   placeholder `WindowGroup`'s `.task`, or an `NSApplicationDelegate`.

```swift
@main
struct BrowserApp: CefSwiftApp {
    @State private var shell = BrowserShell()           // your controller
    var body: some Scene {
        WindowGroup {
            Color.clear.frame(width: 1, height: 1)      // placeholder, hidden
                .task { shell.openWindow(initialURL: homeURL) }
        }
    }
}
```

The `Browser` example (`Examples/Sources/Browser`) is the reference
implementation of this mode: a CEF-owned chrome window, an Arc-style SwiftUI
tab strip + omnibox hosted on top, web content inset below, and a **Chrome**
menu that opens `chrome://history` / `extensions` / `settings` / `downloads` /
`flags` as tabs that actually render.

### What you get

The wrapped `browser` is an ordinary `CefBrowser`: delegate events, JavaScript
execution, downloads, DevTools, find-in-page, zoom, the JS bridge and custom
schemes all work exactly as for `CefWebView`. Plus, because it's the full Chrome
runtime: real tab semantics, extensions, `chrome://` WebUI, profiles, permission
prompts, HTTPS interstitials, PDF viewer, autofill and print-preview machinery —
Chrome's implementations, not reimplementations.

---

## `CefWebView` — windowed Alloy (embedded content)

`CefWebView` (`NSViewRepresentable`, `parent_view` embedding) renders inside an
ordinary SwiftUI layout. CEF handles input/IME/accessibility natively; it's the
default and the most compatible mode. The trade-offs:

- CEF draws the page region, so you **cannot composite native UI over the page**
  inside the same view (overlay siblings in SwiftUI won't show above it).
- Embedded browsers are forced to **Alloy style**, so several `chrome://` WebUI
  pages load but render blank. Verified in CefSwift-embedded views (CEF 148):

  | Page | Embedded (`CefWebView`) | `CefChromeWindow` |
  |---|---|---|
  | `chrome://version`, `gpu`, `process-internals`, `net-internals`, `net-export`, `about` | ✅ renders | ✅ renders |
  | `chrome://history` | ⚠️ blank | ✅ renders |
  | `chrome://extensions` | ⚠️ blank | ✅ renders |
  | `chrome://settings` | ⚠️ blank | ✅ renders |
  | `chrome://downloads` | ⚠️ blank | ✅ renders |
  | `chrome://flags` | ⚠️ blank | ✅ renders |

  The blank pages are tabbed Chrome UI that needs the Chrome *window* machinery
  embedded views never get. The underlying services still run (history is
  recorded, downloads proceed — surfaced via `CefBrowserDelegate`); only those
  management UIs don't render. Use `CefChromeWindow` when you need them.

Use `CefWebView` for dashboard cards, docs panes, HTML reports — anything that
should behave like *content*, not a browser. Set
`CefBrowserOptions.runtimeStyle = .alloy` for the lightest weight (no Chrome
machinery at all). The **Gallery** example shows embedded cards.

---

## `CefChromeWebView` — Chrome-style child-window overlay (alternative)

When you want the full Chrome runtime (and its `chrome://` pages) **inside an
existing SwiftUI window** rather than a separate CEF-owned window,
`CefChromeWebView` is the documented alternative. It attaches a frameless,
CEF-created `NSWindow` as a child window of your hosting window and keeps it
frame-synced to the view's bounds. The Chrome runtime renders (it's a real CEF
window under the hood), but:

- It draws **above all sibling SwiftUI/AppKit content** in that region (don't
  place native overlays over it).
- Spaces/fullscreen transitions and window-dragging can briefly show the overlay
  detached; it's a separate window to AppKit.

Prefer `CefChromeWindow` for full browsers — it avoids the child-window seams by
owning the window outright and lets you composite native chrome on top.
`CefChromeWebView` is for embedding a Chrome view into a window you also fill
with other SwiftUI content.

---

## Forthcoming: OSR / Metal (`CefMetalWebView`)

A windowless (OSR) mode where CEF paints into a shared `IOSurface`
(`on_accelerated_paint`) composited in a `CAMetalLayer`-backed view — a genuine
in-tree subview, native UI compositable anywhere, retina-correct. Alloy style
only (no `chrome://`); input/IME/cursor/accessibility/context-menu are wired by
hand. The "indistinguishable embedded web view" primitive. See
[`docs/osr-metal.md`](osr-metal.md) and [`DESIGN.md`](../DESIGN.md).

---

## Choosing a mode

- **Building a browser?** → `CefChromeWindow`. Real Chrome runtime, native
  chrome on top, `chrome://` everything works.
- **Embedding web content in a SwiftUI app?** → `CefWebView` (`.alloy` for pure
  content, `.default`/chrome for browser-ish behavior).
- **Need Chrome `chrome://` pages *inside* an existing SwiftUI window?** →
  `CefChromeWebView` (overlay caveats apply).
- **Need native UI composited over an embedded page, no `chrome://`?** →
  (forthcoming) `CefMetalWebView` OSR mode.
