# Architecture

## Module graph

```
                    ┌──────────────┐
                    │  CefSwiftUI  │  SwiftUI: CefSwiftApp, CefWebView,
                    └──────┬───────┘  CefMetalWebView, CefChromeWindow
                           │
                    ┌──────▼───────┐
                    │    CefKit    │  Swift core: CefRuntime, CefBrowser,
                    └──┬────────┬──┘  CefConfiguration, delegates (@MainActor)
                       │        │
            ┌──────────▼──┐  ┌──▼──────────┐
            │    CCef     │  │ CCefAppKit  │
            │ (C target)  │  │ (ObjC)      │
            └─────────────┘  └─────────────┘
   vendored CEF capi headers   CEFApplication: NSApplication
   + dlopen/dlsym loader       conforming to CrAppControlProtocol

            ┌─────────────┐
            │ cef-helper  │  one-line main: CefRuntime.helperMain()
            └─────────────┘  bundled 5× by the CefPlugin
```

CCef vendors the CEF `include/` tree (BSD) but only exposes the C-safe subset
(`include/capi/*.h`, `include/internal/`, `cef_api_hash.h`, version headers).
The C++ headers are on disk but never imported.

## The dlopen loader: zero link-time CEF

CefSwift never links against CEF. `Chromium Embedded Framework.framework`
exports the full `cef_*` C API as ordinary symbols; CCef's loader
(`ccef_loader.c`):

1. `dlopen`s the framework binary with `RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST`,
   resolved relative to the executable (main app: `<exe>/../Frameworks/...`;
   helpers: `<exe>/../../../...`).
2. `dlsym`s every symbol CefSwift uses into a function-pointer table. The
   symbol list is a single X-macro list (`ccef_symbols.h`) — one-line to add.
3. Defines real-named trampoline functions (`cef_initialize`, …) that forward
   through the table, so Swift code calls the C API naturally.

A missing symbol fails the load with the symbol's name — never a crash at
call time.

Before anything else in every process CefSwift calls
`cef_api_hash(CEF_API_VERSION, 0)`. `CEF_API_VERSION` is pinned in
`ccef_config.h`; CEF's versioned-API mechanism keeps that C API ABI-stable
across releases, which is what makes automated CEF bumps
([automation.md](automation.md)) safe.

## Refcounting & strings

The CEF C API uses intrusive refcounting (every object starts with
`cef_base_ref_counted_t`):

- **Objects CefSwift implements** use the extended-struct trick: a struct
  whose first member is the CEF struct, followed by an `Unmanaged`
  backpointer to the Swift object. `add_ref`/`release` adjust an atomic
  counter that retains/releases the Swift side; callbacks recover `self` by
  casting the struct pointer back.
- **Objects CEF hands to us** follow capi rules: pass +1 (call `add_ref`)
  before handing an object into CEF; objects arriving in callbacks come +1
  and get released unless retained; `cef_string_userfree_t` results are
  freed with `cef_string_userfree_utf16_free`.

`cef_string_t` is UTF-16. A `CefString` RAII wrapper converts via
`cef_string_utf8_to_utf16` and guarantees cleanup. Most CEF structs begin
with `size_t size` that must be set to `sizeof(...)` before use.

## External message pump & threading

macOS CEF does not support `multi_threaded_message_loop`, and SwiftUI owns
the main run loop — so CefSwift uses CEF's external message pump:

- `cef_settings_t.external_message_pump = 1`.
- CEF calls `on_schedule_message_pump_work(delay_ms)` when it wants CPU.
- CefSwift schedules a main-thread timer (clamped to 33 ms max) that calls
  `cef_do_message_loop_work()`.
- A re-entrancy guard prevents recursive entry (CEF may pump nested run loops).

Result: Chromium and SwiftUI share one main thread cooperatively, near-zero
idle CPU. The CEF UI thread *is* the macOS main thread; CefKit is
`@MainActor` end to end.

`NSApplication` must conform to CEF's `CefAppProtocol` (`isHandlingSendEvent`)
and wrap `sendEvent:` with that flag. The principal class must be
`CEFApplication` before anything touches `NSApp` — which is why
`CefSwiftApp.main()` exists: it installs `CEFApplication`, initializes
`CefRuntime`, and only then enters SwiftUI's `App.main()`. The standard
`NSApplicationMain` path is never used. `terminate:` is intercepted so
quitting routes through browser close and `cef_quit_message_loop` instead of
killing renderers mid-flight.

## Process model

Chromium is multi-process. The main app runs the browser process; renderers,
GPU, plugin, and alert processes are launched from the five helper `.app`s
in `Contents/Frameworks/` (see [bundling.md](bundling.md)). Every helper is
the same `cef-helper` binary: it loads the framework, calls `cef_api_hash`,
then `cef_execute_process` and exits with its return value — CEF decides
what kind of process to become from argv.

## Hosting modes

CEF/Chromium binds a Chrome-runtime browser's compositor to its own
`NSWindow`. Native-parent (`parent_view`) embedding forces *Alloy* style on
macOS, and plain NSView reparenting of a Chrome browser blanks rendering.
CefSwift ships three hosting modes — pick by what you're building.

| Mode | Type | Chrome runtime (`chrome://`, extensions) | Native UI *over* the page |
|---|---|---|---|
| **`CefChromeWindow`** (full browser) | CEF-owned `NSWindow` | full | SwiftUI overlay in the same window |
| **`CefWebView`** (windowed Alloy) | `NSViewRepresentable`, `parent_view` | partial; chrome:// management UIs blank | no (CEF draws the region) |
| **`CefMetalWebView`** (OSR) | `IOSurface`→`CALayer` subview | no (Alloy only) | yes (genuine in-tree subview) |

### `CefChromeWindow` — full browser, Arc-class

A CEF Views top-level window (`cef_window` + `cef_browser_view`, Chrome
style, Chrome's own toolbar hidden via `CEF_CTT_NONE`). CEF owns the window
— which is what unlocks Chrome style — and your SwiftUI chrome is hosted in
an `NSHostingView` stacked above the browser region. `setContentInsets`
reserves space by resizing the browser view via a CEF `BoxLayout`.

```swift
let window = CefChromeWindow.open(
    url: URL(string: "https://example.com")!,
    initialBounds: CGRect(x: 160, y: 160, width: 1180, height: 800)
) { window in
    window.setContentInsets(NSEdgeInsets(top: 96, left: 0, bottom: 0, right: 0))
    window.setOverlay { MyArcChrome() }
}
```

Your overlay should paint an opaque toolbar in the top inset strip and be
transparent below. Clicks on transparent (non-control) regions are forwarded
down to the browser view. Because CEF owns the window, it lives outside
SwiftUI's `Scene` graph — open from a controller, not a `WindowGroup`. See
`Examples/Sources/Browser` for the reference implementation: `chrome://history`,
`chrome://extensions`, `chrome://settings`, `chrome://downloads`,
`chrome://flags` all render here (and are blank in Alloy embedding).

### `CefWebView` — windowed Alloy (embedded content)

`NSViewRepresentable` with `parent_view` embedding. CEF handles input, IME,
and accessibility natively (VoiceOver, CJK composition, candidate windows,
focus traversal all work). Trade-offs: CEF draws the region, so you cannot
composite native UI over the page inside the same view, and the chrome://
management UIs render blank because they need the Chrome *window* machinery
embedded views never get (history is still recorded, downloads still
proceed — surfaced via `CefBrowserDelegate`).

Set `CefBrowserOptions.runtimeStyle = .alloy` for the lightest weight.

### `CefMetalWebView` — OSR / Metal

Chromium renders offscreen into a shared `IOSurface`; CefSwift composites it
in a `CALayer`-backed `NSView`. The result is a genuine in-tree subview —
drop it anywhere in a SwiftUI/AppKit hierarchy and native UI composites over
and around it.

```swift
static var cefConfiguration: CefConfiguration {
    var c = CefConfiguration()
    c.windowlessRenderingEnabled = true   // REQUIRED for OSR; process-wide
    return c
}

ZStack {
    CefMetalWebView(model: model)
    Badge().padding()   // composited on top of the web pixels
}
```

Render path: `cef_render_handler_t.on_accelerated_paint` →
`CALayer.contents = IOSurface` (zero-copy, retina-correct, wrapped in a
`CATransaction`). CPU fallback via `on_paint` → `CGImage`. `<select>`
popups go to a dedicated `popupLayer` sized by `on_popup_size`.

OSR has no CEF window, so every native affordance is wired by hand
(`CefMetalHostView*.swift`):

- **Mouse / scroll / cursor** — `send_mouse_*`, `on_cursor_change`.
- **Mouse back/forward buttons** — thumb buttons 3/4 → `goBack`/`goForward`;
  matching up is swallowed so they never reach the page as a middle click.
- **Keyboard typing** — `send_key_event` with mac→Windows VK mapping
  (`CefKeyCodes`); deferred `keyDown` model (KEYDOWN+CHAR) so JS key
  handlers fire and the caret moves.
- **Keyboard shortcuts & editing** — `performKeyEquivalent(with:)` forwards
  web-editing combos (Cmd+A/C/V/X/Z, caret/word nav, generic Cmd/Ctrl combos)
  to the renderer as KEYDOWN+CHAR and consumes them, so the page's JS
  handlers fire and `preventDefault()` is respected. Edit-menu / Services /
  programmatic invocations route the standard `@objc` selectors (`copy:`,
  `paste:`, `selectAll:`, `undo:`, …) to focused-frame clipboard commands
  on `CefBrowser`. True app-global shortcuts (Cmd+Q/W/M/H/`/,/Space/Tab) are
  passed through.
- **IME** — `NSTextInputClient` ↔ `ime_set_composition` /
  `ime_commit_text`; `firstRect` uses `on_ime_composition_range_changed`.
- **Emoji & accent palette** — insert via the `insertText` path; positioned
  at the caret via `firstRect(forCharacterRange:)`. Caveat: CEF's OSR API
  exposes no caret rect for non-composition selections, so the very first
  emoji/accent insertion into a field with no prior composition anchors at
  the view's top-left rather than pixel-perfectly at the caret. Once any
  composition has occurred, the cached caret rect tracks correctly.
- **Context menu** — `run_context_menu` snapshots the model and presents a
  native `NSMenu` *asynchronously* (a modal loop inside the callback
  crashes CEF).
- **Gestures** — magnify → page zoom (`set_zoom_level`); smartMagnify
  toggles 1:1 / zoomed; swipe → goBack/goForward (we don't also drive
  Chromium's overscroll nav, avoiding double-navigation). Rotate is a
  documented no-op (no rotation channel in `cef_browser_host_t`).
- **Drag & drop** — both directions: system→page via `NSDraggingDestination`
  + `cef_drag_data_create` + `drag_target_*`; page→system via the render
  handler's `start_dragging` driving an `NSDraggingSession`.
- **Touch (raw)** — opt-in via `CefBrowserOptions.forwardsRawTouchEvents`
  (default off; indirect-touch forwarding is unreliable — the explicit
  gestures above are the robust path).
- **Accessibility** — `set_accessibility_state(STATE_ENABLED)` + the
  `cef_accessibility_handler_t` bridge decode CEF's serialized AXTree into
  per-node `NSAccessibilityElement` proxies (role/title/value/children/screen
  frame). VoiceOver can navigate web content; honest gaps remain — no AX
  hit-testing, no live focus/selection tracking into VO, no `AXTextMarker`,
  no actions, partial role map.

**Constraints:** Alloy style only (windowless rendering forces Alloy on
macOS); `windowlessRenderingEnabled` is process-wide and must be set before
`CefRuntime.initialize` (the factory traps with an actionable message if not).

### Picking a mode

- Full browser, `chrome://` everything works → `CefChromeWindow`.
- Embedded web content in a SwiftUI layout, VoiceOver/IME for free →
  `CefWebView` (`.alloy` for pure content).
- Native UI composited over the page (no `chrome://`) → `CefMetalWebView`.
