# CefSwift — Hosting Modes Reference

CefSwift ships three embedding modes. The choice is permanent per browser
instance — pick based on what your app needs to render and how much native UI
must overlay the page.

## The three modes

### 1. Windowed Alloy — `CefWebView`

`CefWebView(url:)` / `CefWebView(model:)` — an `NSViewRepresentable` backed by
a real `NSView` child managed by CEF (`parent_view`). CEF handles input, IME,
accessibility, and cursor natively. Native SwiftUI UI **cannot** composite over
the page region (AppKit subview layering constraint). Maximum compatibility,
lowest friction. Use for dashboards, embedded cards, and single-browser apps.

### 2. Chrome-runtime window — `CefChromeWindow`

A CEF Views top-level window (`cef_browser_view` + `cef_window`, Chrome
runtime style). CEF owns the `NSWindow`; SwiftUI overlays (tab strip, omnibox)
are added as `NSHostingView` subviews of the CEF window's content view —
native UI composites on top of the full Chrome runtime.

Chrome-style pages (`chrome://history`, `chrome://extensions`,
`chrome://settings`) render. CEF drives the window lifecycle via
`cef_window_delegate_t`. Use for full-browser products.

### 3. OSR / Metal — `CefMetalWebView`

Offscreen rendering: CEF paints into a shared `IOSurface`
(`on_accelerated_paint`, `shared_texture_enabled`) composited in a
`CAMetalLayer`-backed view — a genuine in-tree `NSView` subview, retina-
correct, native UI compositable anywhere. Alloy style only (no `chrome://`).

All "native" affordances are DIY: input (`send_mouse_*` / `send_key_event` +
DIP coordinate mapping), IME (`NSTextInputClient` ↔ `ime_set_composition`),
cursor (`on_cursor_change`), context menu (`cef_context_menu_handler`),
DevTools (`show_dev_tools`). The "indistinguishable embedded web view" mode.
See [docs/osr-metal.md](docs/osr-metal.md).

## Why these three and not others

- **NSView reparenting of a Chrome browser** blanks rendering (~2 s after
  creation; Chromium's compositor re-detaches from the foreign window).
- **Remote CALayer mirroring** (via `CAContext` / `CALayerHost`) is not exposed
  by CEF's C API and is App-Store-hostile.
- **`multi_threaded_message_loop`** is unsupported on macOS. CefSwift uses the
  external message pump instead.

These constraints are verified against CEF 148 / macOS; see
[docs/architecture.md](docs/architecture.md) for the full technical picture.
