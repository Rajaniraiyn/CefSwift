# Links, popups & new windows + context menus

How CefSwift routes the things a page does when it opens a link, a popup, or a
new window — and how to customize the page context menu. This is the
Electron-`setWindowOpenHandler` equivalent for CefSwift, designed to be **safe
by default across all three hosting modes** (windowed Alloy, chrome-runtime,
OSR/Metal).

## The window-open API

When a page tries to open a link or popup — `target=_blank`, `window.open`,
⌘/Ctrl-click, middle-click, Shift-click — CefSwift surfaces a
`CefWindowOpenRequest` to your delegate and asks for a `CefWindowOpenAction`.

```swift
func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction
```

`CefWindowOpenRequest` carries everything Chromium knows about the intent:

| Field | Meaning |
|-------|---------|
| `targetURL` | The URL to open (may be `nil` for `about:blank` popups). |
| `frameName` | The `window.open` name / `target=` value. |
| `disposition` | How Chromium classified the click (see below). |
| `userGesture` | `true` for a real click; `false` for scripted opens. |
| `features` | Popup window features (`width`/`height`/`x`/`y`/`isPopup`). |
| `isSourceOffscreen` | Whether the source browser is OSR (native popups unsafe). |

`CefWindowOpenDisposition` mirrors Chromium's `WindowOpenDisposition`. The
useful cases:

- `.currentTab` — plain click (default).
- `.newForegroundTab` — ⌘/Ctrl+Shift-click, Shift+middle-click.
- `.newBackgroundTab` — ⌘/Ctrl-click, middle-click.
- `.newPopup` — `window.open` with features / JS popup.
- `.newWindow` — Shift-click.

Use `disposition.prefersForeground` to decide whether a new tab should come to
the front (it returns `false` only for `.newBackgroundTab`).

### Actions

Return one of:

- **`.deny`** — suppress the open entirely.
- **`.openInCurrentBrowser`** — load the target in *this* browser. The safe
  choice for OSR. No-op if the request has no URL.
- **`.allowNativePopup`** — let CEF create a native popup browser/window.
  **Only safe for windowed/chrome browsers.** For an OSR browser this is
  automatically downgraded to `.openInCurrentBrowser` (or `.deny` with no URL),
  because a CEF popup created for an OSR parent gets no offscreen render handler
  and cannot be hosted.
- **`.handled`** — *you* opened your own tab/window (e.g. a new `CefWebView` or
  `CefChromeWindow`); CEF's native popup is blocked.

### Default policy per hosting mode

If you don't implement the delegate method, `CefWindowOpenPolicy.defaultAction`
applies:

| Source | URL present | Default |
|--------|-------------|---------|
| OSR | yes | `.openInCurrentBrowser` (never a native popup) |
| OSR | no (`about:blank`) | `.deny` |
| Windowed / chrome | yes | `.openInCurrentBrowser` |
| Windowed / chrome | no | `.allowNativePopup` |

The guarantee: **an OSR browser never silently spawns an unhosted native
popup.** The downgrade is applied in two places — in the policy helper and
again, defensively, in `on_before_popup` — so even a delegate returning
`.allowNativePopup` for an OSR browser is made safe.

### Tabs example (the Browser shell)

The Arc-style Browser opens links as tabs, honoring the disposition:

```swift
func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
    guard let url = request.targetURL else { return .deny }
    let tab = BrowserTab(url: url)
    tabs.append(tab)
    if request.disposition.prefersForeground { select(tab) }  // else: background tab
    return .handled  // we made our own tab; block CEF's popup
}
```

### `CefWebViewModel` hook

For `CefWebView` / `CefMetalWebView`, set the closure instead of subclassing:

```swift
model.onWindowOpen = { request in
    // OSR-safe: load in place and log the intent.
    return .openInCurrentBrowser
}
```

### Legacy `requestsPopupFor` / `CefPopupDecision`

The older `requestsPopupFor(_:) -> CefPopupDecision` delegate method and
`onPopupRequest` closure still work — they're bridged into the new API
(`.allow` → `.allowNativePopup` with the OSR downgrade, `.block` → `.deny`,
`.openInSameBrowser` → `.openInCurrentBrowser`). Prefer the new API for
foreground/background-tab control and popup features.

## Context menus

The default page context menu already offers — and CEF itself executes —
Back/Forward/Reload, Cut/Copy/Paste (in editable fields), Copy Link Address,
Copy/Save Image, **View Page Source**, and Inspect/DevTools, gated to the
click target. Leaving an item in the menu and returning `false` from the
command delegate runs CEF's built-in behavior.

### Customizing

Mutate the menu before it appears, and handle your own commands:

```swift
model.onConfigureContextMenu = { menu, params in
    menu.addSeparator()
    if params.linkURL != nil {
        menu.addItem(commandID: CefMenuModel.userCommandIDFirst + 1, title: "Open Link in This View")
    }
    menu.addItem(commandID: CefMenuModel.userCommandIDFirst, title: "Open DevTools")
}
model.onContextMenuCommand = { commandID, params in
    switch commandID {
    case CefMenuModel.userCommandIDFirst:
        model.browser?.showDevTools(); return true
    case CefMenuModel.userCommandIDFirst + 1:
        if let link = params.linkURL { model.load(link) }; return true
    default:
        return false  // let CEF run its built-in command
    }
}
```

(Browsers backed by a `CefBrowserDelegate` use the equivalent
`browser(_:configureContextMenu:params:)` / `browser(_:contextMenuCommand:params:)`
methods directly.)

App-defined command IDs must be in
`CefMenuModel.userCommandIDFirst ... userCommandIDLast`
(`MENU_ID_USER_FIRST ... MENU_ID_USER_LAST`). The standard CEF command IDs are
mirrored by `CefContextMenuCommand` (`.back`, `.copy`, `.viewSource`, …) and
`CefMenuCommandRange` helps classify a command id.

### How it's hosted per mode

- **Windowed / chrome:** CEF presents its own native menu (returning 0 from
  `run_context_menu`).
- **OSR / Metal:** there is no CEF window, so CefSwift presents the menu as a
  native `NSMenu` (`osrRunContextMenu`) built from the `CefMenuModel`, then
  reports the chosen command back to CEF, which executes the built-in action
  (or fires your command delegate for user-range IDs).
