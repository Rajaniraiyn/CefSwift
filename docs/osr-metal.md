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
| Mouse (move/down/up/drag, L/M/R) | **Works** | `send_mouse_*`; verified live (scroll moved the page). Double/triple-click selection works (`clickCount` forwarded). |
| Mouse back/forward buttons | **Works** | Thumb buttons 3/4 (`otherMouseDown` `buttonNumber`) → `goBack()`/`goForward()`; the matching up is swallowed so they never reach the page as a middle click. Other `other` buttons send as middle. |
| Scroll wheel | **Works** | Precise + line deltas; verified by screenshot. |
| Keyboard (typing) | **Works** | `send_key_event` with mac→Windows VK mapping (`CefKeyCodes`); deferred `keyDown` model (KEYDOWN+CHAR) so JS key handlers fire and the caret moves. |
| Keyboard shortcuts / editing commands | **Works** | See the dedicated section below — `performKeyEquivalent` forwards web-editing combos to the renderer; Edit-menu actions route to focused-frame clipboard commands. |
| IME (CJK, dead keys) | **Implemented** | `NSTextInputClient` ↔ `ime_set_composition`/`ime_commit_text`; `firstRect` uses `on_ime_composition_range_changed`. Pipeline complete; broad IME matrix not exhaustively tested. |
| Emoji & symbols palette / accent popup | **Works (positioning best-effort)** | Cmd+Ctrl+Space palette and press-and-hold accent popups insert via the `insertText` path; positioned at the caret via `firstRect(forCharacterRange:)`. See the limitation note below. |
| Cursor | **Works** | `on_cursor_change` → `NSCursor` via the existing `CefCursorType` map. |
| Focus | **Works** | `become/resignFirstResponder` → `set_focus`; plus window become/resign-key mirrored to `set_focus` while the view is first responder, and `on_take/set/got_focus` bridged to the delegate so tabbing in/out works. |
| Context menu | **Works (native NSMenu)** | `run_context_menu` snapshots the model and presents an `NSMenu` **asynchronously** (CEF forbids a modal loop inside the callback — doing it synchronously crashes). |
| `<select>` popups | **Works** | `on_paint`/`on_accelerated_paint` now carry the paint element type; `PET_POPUP` frames are routed to a dedicated `popupLayer` sized by `on_popup_size` and shown/hidden by `on_popup_show`, composited above the content layer. |
| Gestures — pinch zoom | **Works** | `magnify(with:)` accumulates `event.magnification` into the browser host **page zoom** (`set_zoom_level`/`zoomLevel`). |
| Gestures — smart magnify | **Works** | `smartMagnify(with:)` (two-finger double-tap) toggles between 1:1 and a zoomed step. |
| Gestures — swipe nav | **Works** | `swipe(with:)` (three-finger, or the user-configured two-finger) → `goBack()` / `goForward()`. AppKit delivers this gesture exclusively of the `scrollWheel` momentum stream, so it never double-fires against a normal two-finger scroll; we do **not** also drive Chromium's built-in horizontal-overscroll navigation, avoiding a double-navigation. |
| Gestures — rotate | **N/A** | No rotation channel in `cef_browser_host_t`; intentional no-op (documented in `CefMetalHostView+Gestures.swift`). |
| DevTools | **Works** | `show_dev_tools` opens its own window, same as windowed. |
| Touch (raw) | **Opt-in** | `touchesBegan/Moved/Ended/Cancelled` → `send_touch_event` (indirect trackpad touches), gated behind `CefBrowserOptions.forwardsRawTouchEvents` (default off; indirect-touch forwarding is unreliable, so the explicit gestures above are the robust path). `CefBrowser.sendTouchEvent(...)` is the API. |
| Drag & drop (system → page) | **Works** | Host view is an `NSDraggingDestination`; enter/over/exit/drop build a `cef_drag_data_t` (`cef_drag_data_create` + text/html/url/files) and call `drag_target_*`. |
| Drag & drop (page → system) | **Works** | Render handler `start_dragging`/`update_drag_cursor` bridged; begins an `NSDraggingSession` from the view (`NSDraggingSource`), reporting completion via `drag_source_ended_at` + `drag_source_system_drag_ended`. |

## Keyboard shortcuts, clipboard & editing commands

A real web page handles editing shortcuts in two layers: the page's own JS
`keydown` handlers (which may `preventDefault()`), and the browser's default
edit commands inside `<input>`/`<textarea>`/`contentEditable`. An OSR view has
no native field and no CEF window, so we reproduce both layers explicitly.

**Two complementary paths (`CefMetalHostView+Editing.swift`):**

1. **Live keyboard shortcuts → `performKeyEquivalent(with:)`.** On macOS,
   Command-key combinations are offered to the key view via
   `performKeyEquivalent` *before* the main menu. When the OSR view is first
   responder we **forward the key event itself** to the renderer (as
   `KEYEVENT_KEYDOWN` + `KEYEVENT_CHAR`) and return `true` to consume it.
   Forwarding (rather than calling `CefBrowser.copySelection()` directly) is
   deliberate: it fires the page's JS key handlers, respects `preventDefault()`,
   and lets Chromium apply correct semantics in inputs / `contentEditable` /
   page selection — exactly like a real browser.

2. **Edit menu / Services / programmatic → responder actions.** The standard
   `@objc` selectors (`copy(_:)`, `cut(_:)`, `paste(_:)`, `pasteAsPlainText(_:)`,
   `delete(_:)`, `selectAll(_:)`, `undo(_:)`, `redo(_:)`) route to focused-frame
   clipboard commands on `CefBrowser` (`CefBrowserEditing.swift`), which resolve
   `get_focused_frame` (fallback `get_main_frame`) and call the matching
   `cef_frame_t` command (`copy`/`cut`/`paste`/`paste_and_match_style`/`del`/
   `select_all`/`undo`/`redo`). `validateMenuItem`/`validateUserInterfaceItem`
   enable these whenever a browser is focused (optimistic — the renderer no-ops
   a command that doesn't apply, matching WKWebView).

**Forwarding policy (the rule we chose), tested in `OSRInputConformanceTests`:**

| Combo | Behavior | Why |
|---|---|---|
| Cmd+A / C / V / X / Z, Shift+Cmd+Z, Cmd+Shift+V | **Forward + consume** | Web editing shortcuts — the page/renderer performs them. |
| Cmd + arrows, Cmd/Option+Backspace, Option+arrows | **Forward + consume** | Caret/word/line navigation & delete inside inputs. |
| Any other Command **or** Control combo | **Forward + consume** | Generic web shortcuts; JS handlers get them. |
| Cmd+Q, Cmd+W, Cmd+M, Cmd+H, Cmd+\`, Cmd+, , Cmd+Space, Cmd+Tab | **Pass through** | True app/OS-global shortcuts — never swallowed by the page. |
| Plain keys, Shift-only, Option-only (accents), function/media keys | **Pass through** | Plain keys arrive via `keyDown`; intercepting here would double-send. |

Plain editing **inside inputs** (type, select-all, copy/cut/paste, undo,
arrow/word/line nav, backspace/forward-delete, Home/End/PageUp/Down) and
**page-level selection copy** all flow through these paths.

## Emoji palette & caret positioning — honest limitation

The emoji & symbols palette (Cmd+Ctrl+Space) and press-and-hold accent popup
insert glyphs through the `NSTextInputClient.insertText` path (so they land in
the focused field). Their on-screen position comes from
`firstRect(forCharacterRange:)`, which anchors at the caret using, in order:

1. **Live composition bounds** — exact per-glyph boxes from
   `on_ime_composition_range_changed` during an active IME composition.
2. **Last-known caret rect** — we cache (1) (`lastKnownCaretRectDIP`) so the
   anchor stays at the real caret right after a composition ends.
3. **Focused-view fallback** — for a *plain* caret with no composition history,
   CEF's OSR API exposes no caret rectangle for a non-composition selection
   (`on_text_selection_changed` carries text + range, not bounds), so we anchor
   near the top-left of the view rather than the screen origin.

**Limitation:** for the very first emoji/accent insertion into a field where no
IME composition has yet occurred, the popup anchors at the view's top-left, not
pixel-perfectly at the caret. Once any composition (or a prior emoji insertion
that goes through composition) has happened, the cached caret rect makes it
track correctly. A fully exact non-composition caret rect would require CEF to
surface caret bounds on text-selection changes, which it does not today.

## Modifier mapping

`CefMetalHostView.cefModifiers` maps Shift/Control/Option/Command/CapsLock and
pressed mouse buttons to `EVENTFLAG_*`. Key events additionally set
`EVENTFLAG_IS_KEY_PAD` for numeric-keypad keys (`isKeyPadEvent`, mirroring
cefclient). macOS exposes no `EVENTFLAG` for the **Fn** key or **NumLock**, so
those are intentionally omitted (same as cefclient). `makeKeyEvent` sets
`character` from `event.characters` (with modifiers, so Option-composed glyphs
are correct) and `unmodified_character` from `event.charactersIgnoringModifiers`.

## Accessibility (AX)

The host enables AX on creation (`set_accessibility_state(STATE_ENABLED)`), so
CEF builds and delivers the accessibility tree.

**What works now:** `cef_accessibility_handler_t` is bridged via the render
handler's `get_accessibility_handler`. `on_accessibility_tree_change` and
`on_accessibility_location_change` deliver CEF's serialized AXTree, which is
decoded into a Swift `CefAXValue` graph and mirrored into per-node
`NSAccessibilityElement` proxies (`CefOSRAccessibilityBridge` /
`CefAXNodeElement`). Each proxy carries a **role** (a subset of Chromium AX
roles mapped to AppKit roles — button/link/staticText/textField/checkBox/
radioButton/image/list, else group), **title** (`attributes.name`), **value**
(`attributes.value`), **children** (from `child_ids`), and a **screen frame**
(from the node `location`, converted view-DIP→screen). The host view exposes
itself as an AX group labeled "Web content" whose children are the mapped root
nodes, and posts `.layoutChanged` on each tree update. `lastMappedAXNodeCount`
is exposed for diagnostics.

**Honest status / remaining gaps:** VoiceOver can navigate the top-level web
content tree and read role + name/value for mapped nodes. It is **not** full
parity: no AX hit-testing, no live focus/selection tracking into VoiceOver, no
text-range/`AXTextMarker` navigation, no actions (press/increment), and the
role map is partial. This is a real baseline, not a stub — but "indistinguishable"
AX remains the largest roadmap item.

## Constraints

- **Alloy style only.** Windowless rendering forces Alloy on macOS (a
  CEF/Chromium constraint) — no `chrome://` internals or extensions in this
  mode. Use `CefChromeWindow` for those.
- **`windowlessRenderingEnabled` is process-wide** and must be set before
  `CefRuntime.initialize`. The factory traps with an actionable message if not.

## See also

- `Sources/CefKit/CefRenderHandler.swift` — the render-handler bridge + `CefOSRHost`.
- `Sources/CefKit/CefBrowserOSR.swift` — host-input forwarding on `CefBrowser`.
- `Sources/CefKit/CefBrowserEditing.swift` — focused-frame clipboard/editing commands.
- `Sources/CefSwiftUI/CefMetalHostView+Editing.swift` — `performKeyEquivalent` policy + Edit-menu responder actions.
- `Sources/CefSwiftUI/CefMetalHostView*.swift` — the hosting NSView (paint, input, IME, menu, gestures).
- `Examples/Sources/Gallery` — the "OSR / Metal (premium)" card.
