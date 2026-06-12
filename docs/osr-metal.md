# OSR / Metal embedding — `CefMetalWebView`

CefSwift's premium hosting mode: Chromium renders **offscreen** into a shared
`IOSurface`, which CefSwift composites in a `CALayer`-backed `NSView`. The
result is a *genuine in-tree subview* — it drops anywhere in a SwiftUI/AppKit
hierarchy and native UI composites over and around it, unlike the windowed
`CefWebView` (whose CEF-owned surface always sits on top) or Electron's
`BrowserView` (a separate native window clipped to a rect).

```swift
// Requires windowless rendering enabled at init:
static var cefConfiguration: CefConfiguration {
    var c = CefConfiguration()
    c.windowlessRenderingEnabled = true   // REQUIRED for OSR
    return c
}

// Drop-in, mirrors CefWebView's API:
CefMetalWebView(url: URL(string: "https://example.com")!)

// Native overlay composited ON TOP of the web pixels:
ZStack {
    CefMetalWebView(model: model)
    Badge().padding()
}
```

## How it works

1. `CefBrowserFactory.createOSRBrowser(...)` creates a browser with
   `cef_window_info_t { windowless_rendering_enabled = 1, shared_texture_enabled
   = 1 }` and **no** `parent_view` — so CEF creates no NSWindow. Creation is
   asynchronous; the browser is adopted in `on_after_created`.
2. A `cef_render_handler_t` (see `CefRenderHandler.swift`) is wired into
   `BrowserClient` and returned only for OSR browsers (windowed browsers leave
   it NULL and keep CEF's native compositor).
3. Each frame, CEF calls `on_accelerated_paint` with a
   `cef_accelerated_paint_info_t.shared_texture_io_surface`. The host sets it as
   `CALayer.contents` inside the callback (zero-copy, the proven-correct path on
   macOS). A CPU fallback (`on_paint` → `CGImage`) exists for when shared
   textures are unavailable.
4. `get_view_rect` returns the view size in DIP; `get_screen_info` returns the
   `device_scale_factor` (driven by `window.backingScaleFactor`) for retina
   correctness. On layout/scale change the host calls `wasResized()` /
   `notifyScreenInfoChanged()`.

### Why IOSurface→CALayer and not a Metal blit?

`CALayer.contents = IOSurface` is the simplest correct path and was proven by
the OSR probe. It is zero-copy: CALayer references the surface's contents for
the frame. A `CAMetalLayer` + Metal blit is a possible upgrade (e.g. for custom
post-processing or tighter present timing), but adds risk for no visible win
here — the IOSurface path already presents retina-correct, tear-free frames
(updates wrapped in a `CATransaction` with actions disabled). The render path is
therefore **IOSurface→CALayer**; Metal blit is a documented upgrade seam.

## Input, IME, cursor — what works

All "native" affordances are DIY via capi handlers (there is no CEF window to
handle them for us). Coordinates are converted from AppKit's bottom-left to CEF
DIP (top-left) by the flipped host view.

| Affordance | Status | Notes |
|---|---|---|
| Mouse (move/down/up/drag, L/M/R) | **Works** | `send_mouse_*`; verified live (scroll moved the page). |
| Scroll wheel | **Works** | Precise + line deltas; verified by screenshot. |
| Keyboard | **Works** | `send_key_event` with mac→Windows VK mapping (`CefKeyCodes`). |
| IME (CJK, dead keys) | **Implemented** | `NSTextInputClient` ↔ `ime_set_composition`/`ime_commit_text`; `firstRect` uses `on_ime_composition_range_changed`. Pipeline complete; broad IME matrix not exhaustively tested. |
| Cursor | **Works** | `on_cursor_change` → `NSCursor` via the existing `CefCursorType` map. |
| Focus | **Works** | `become/resignFirstResponder` → `set_focus`. |
| Context menu | **Works (native NSMenu)** | `run_context_menu` snapshots the model and presents an `NSMenu` **asynchronously** (CEF forbids a modal loop inside the callback — doing it synchronously crashes). |
| `<select>` popups | **Partial** | `on_popup_show/size` plumbed; popup pixels arrive in the same OSR surface for Alloy. A dedicated popup layer exists but isn't separately composited yet. |
| DevTools | **Works** | `show_dev_tools` opens its own window, same as windowed. |
| Touch | **Plumbed** | `send_touch_event` exposed on `CefBrowser`; not wired to trackpad gestures. |

## Accessibility (AX)

The host enables AX on creation (`set_accessibility_state(STATE_ENABLED)`), so
CEF builds and delivers the accessibility tree. **Honest status:** enablement is
wired and the `get_accessibility_handler` seam exists on the render handler, but
the bridge that re-exposes CEF's AX tree to VoiceOver via `NSAccessibility` on
the host view is **roadmap** — the OSR view currently participates in AX only as
a generic element. Full VoiceOver parity (per-node `NSAccessibilityElement`
proxies mirroring `on_accessibility_tree_change`) is the largest remaining gap
to "indistinguishable."

## Constraints

- **Alloy style only.** Windowless rendering forces Alloy on macOS (a
  CEF/Chromium constraint) — no `chrome://` internals or extensions in this
  mode. Use `CefChromeWindow` for those.
- **`windowlessRenderingEnabled` is process-wide** and must be set before
  `CefRuntime.initialize`. The factory traps with an actionable message if not.

## See also

- `Sources/CefKit/CefRenderHandler.swift` — the render-handler bridge + `CefOSRHost`.
- `Sources/CefKit/CefBrowserOSR.swift` — host-input forwarding on `CefBrowser`.
- `Sources/CefSwiftUI/CefMetalHostView*.swift` — the hosting NSView (paint, input, IME, menu).
- `Examples/Sources/Gallery` — the "OSR / Metal (premium)" card.
