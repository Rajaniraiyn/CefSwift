# Configuration

Everything tunable in CefSwift, in three layers: the runtime
(`CefConfiguration`, set once at launch), per-browser options
(`CefBrowserOptions`), and build-time choices on the plugin (flavor, version,
platform).

## CefConfiguration

Supply it from your app type:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.remoteDebuggingPort = 9222
        return config
    }
    var body: some Scene { /* ... */ }
}
```

Or, without `CefSwiftApp`, pass it to
`CefRuntime.shared.initialize(configuration:)` yourself.

| Knob | Type / default | Effect |
|---|---|---|
| `noSandbox` | `Bool`, `true` | `false` enables the Chromium macOS sandbox end-to-end (helpers seal themselves via `libcef_sandbox.dylib` before loading CEF). Requires a properly signed bundle — see [sandbox.md](sandbox.md). |
| `rootCachePath` | `URL?`, `~/Library/Application Support/<bundle-id>/CefSwift` | Root for all profile data (cookies, local storage, caches). |
| `cachePath` | `URL?` | A specific profile directory under the root. Unset = "incognito-like" global profile semantics per CEF defaults. |
| `locale` | `String?` | UI locale, e.g. `"de"`. Defaults to the system locale. |
| `userAgentProduct` | `String?` | Product token inserted into the default Chromium user agent (e.g. `"MyApp/1.0"`). |
| `logSeverity` | `CefLogSeverity`, `.default` | `.verbose`/`.debug`/`.info`/`.warning`/`.error`/`.fatal`/`.disable`. |
| `logFile` | `URL?` | Chromium log destination (default: `debug.log` next to the cache). |
| `remoteDebuggingPort` | `Int?` | Opens the Chrome DevTools Protocol on `localhost:<port>` — attach Chrome's `chrome://inspect`, Playwright, etc. |
| `persistSessionCookies` | `Bool` | Keep session cookies across launches. |
| `safeStorage` | `CefSafeStoragePolicy`, `.automatic` | How cookies are encrypted at rest. `.automatic` skips the keychain (and its prompt) for ad-hoc-signed dev builds. See [the safe-storage section below](#the-keychain-chromium-safe-storage-prompt). |
| `defaultRuntimeStyle` | `CefRuntimeStyle`, `.default` (= chrome) | Default style for new browsers; see below. |
| `windowlessRenderingEnabled` | `Bool`, `false` | Required for `CefMetalWebView` (OSR). Process-wide — must be set before `CefRuntime.initialize`. |
| `externalMessagePump` | `Bool`, `true` | Leave on. SwiftUI owns the run loop; see [architecture.md](architecture.md). |
| `frameworkDirectory` | `URL?` | Override where the CEF framework is found (default: the app bundle's `Contents/Frameworks/`). Useful for unbundled dev setups. |
| `browserSubprocessPath` | `URL?` | Override the helper executable path. |
| `customSchemes` | `[CefCustomScheme]`, `[]` | Custom URL schemes registered in **every** CEF process (the helper side is automated via a `--cefswift-schemes` switch). Serve them with `CefRuntime.registerSchemeHandler(scheme:domain:handler:)` — e.g. `CefBundleSchemeHandler(directory:)` for bundled web UI. The reserved `cefswift` bridge scheme is always added. |
| `extraCommandLineSwitches` | `[String: String?]` | Any Chromium switch — `nil` value for boolean switches: `["disable-gpu-shader-disk-cache": nil]`. |
| `onBeforeCommandLineProcessing` | closure | The last word: inspect/mutate the full `CefCommandLine` before Chromium parses it. |

## Beyond CefConfiguration: runtime-level plug points

| Surface | What it does |
|---|---|
| `CefRuntime.shared.registerSchemeHandler(scheme:domain:handler:)` | Routes a scheme to a `CefSchemeHandler` (`func response(for: CefSchemeRequest) async -> CefSchemeResponse`, whole-body buffered). Pair with `customSchemes` above; `CefBundleSchemeHandler(directory:indexFile:)` serves local files with UTType-based MIME detection. |
| `CefRuntime.shared.bridge` | JS ↔ Swift function bridge: `bridge.register("name") { (input: In) in Out }` (Codable) and pages call `await window.cefSwift.invoke('name', {…})`. Push the other way with `bridge.broadcast(event:data:)` → `window.cefSwift.on('name', fn)`. Shim auto-injection toggle: `bridge.autoInjectsShim`. See [JS ↔ Swift bridge](#js--swift-bridge) below. |
| Downloads | Per browser: `CefBrowserDelegate.browser(_:decidePolicyForDownload:suggestedName:)` (return `.allow(destination:)` / `.deny`; default saves to `~/Downloads/<suggested name>`) plus `browser(_:downloadDidProgress:)` with a `CefDownload` snapshot (id, url, bytes, completion, path). On `CefWebViewModel`: the `onDownloadDecision` / `onDownloadProgress` closures. |

## Runtime styles: chrome vs alloy

`CefRuntimeStyle` is the single most consequential knob.

### `.chrome` (the default)

The browser view is a real Chrome browser without Chrome's window chrome:

- **Tabs** exist under the hood (one per browser view), with Chrome's session
  and profile machinery.
- **Extensions** — Chrome extensions can load and run.
- **`chrome://` pages** — `chrome://history`, `chrome://extensions`,
  `chrome://settings`, `chrome://version`, `chrome://gpu`, … all work when
  navigated to.
- **Profiles** — Chrome's profile model backs the cache paths.
- Chrome's standard dialogs, permission prompts, find bar behavior, etc.

This is what you want for anything browser-shaped. See
[architecture.md — hosting modes](architecture.md#hosting-modes).

### `.alloy`

CEF's traditional lightweight embedded style: no Chrome UI machinery, no
extensions, no `chrome://` internals — just a rendering engine in a view.
Slightly lighter, fully delegate-driven. Right for "a web card in my
dashboard" cases where you want zero browser semantics.

Set per browser via `CefBrowserOptions.runtimeStyle`, or globally via
`CefConfiguration.defaultRuntimeStyle`.

## CefBrowserOptions (per browser)

```swift
var options = CefBrowserOptions()
options.runtimeStyle = .alloy
options.backgroundColor = .windowBackgroundColor
let model = CefWebViewModel(url: url, options: options)
```

| Option | Effect |
|---|---|
| `runtimeStyle` | Chrome vs alloy for this browser only. |
| `backgroundColor` | Paint color before the page renders (kills the white flash in dark UIs). |

(Deliberately small in v1; more knobs land here as they prove necessary.)

## Build-time: plugin flags

The `cef` plugin chooses *which CEF binary* you run:

```sh
# Flavor: minimal (default) or standard (includes CEF debug build)
swift package ... cef download --flavor standard
swift package ... cef bundle --product MyApp --flavor standard

# Platform: defaults to the host; cross-download for the other Mac arch
swift package ... cef download --platform macosx64

# Version override: any exact CEF version string from cef-builds index
swift package ... cef download --cef-version "148.0.10+g7ee53f5+chromium-148.0.7778.218"

# Codesigning identity: '-' = ad-hoc; default auto-detects the first
# "Apple Development" identity, else "Developer ID Application", else ad-hoc
swift package ... cef bundle --product MyApp --sign "Apple Development: Jane Doe (TEAMID)"
```

`cef bundle` signs the whole bundle inside-out (framework → helpers → app).
The identity comes from, in order of precedence: the `--sign` flag, the
`"signingIdentity"` key in `cefapp.json` next to the target sources, then
auto-detection via `security find-identity -v -p codesigning`. Signing with a
real identity makes the keychain "Always Allow" grant stick across rebuilds
(see [the safe-storage section](#the-keychain-chromium-safe-storage-prompt)).

The pinned default lives in `CEF_VERSION.json` at the package root (the
plugin walks up to find the root manifest when invoked from the Examples
package, or accepts `--manifest <path>`). The pin is kept current
automatically — see [automation.md](automation.md).

Other plugin verbs: `cef info` (pinned version, cache state, flavors),
`cef clean` (delete the `.cef/` cache).

## The Keychain "Chromium Safe Storage" prompt

When Chromium first uses the real keychain it creates the key it encrypts
cookies with — the **"Chromium Safe Storage"** item — and macOS shows the
*"<YourApp> wants to use your confidential information stored in 'Chromium
Safe Storage'"* dialog. `CefConfiguration.safeStorage` decides whether that
ever happens:

```swift
config.safeStorage = .automatic     // the default
```

| Policy | Behavior |
|---|---|
| `.automatic` (default) | Dev builds (ad-hoc signed / unsigned): mock key, **no prompt ever**. Properly signed builds: real keychain, one-time prompt. |
| `.keychain` | Always use the user's keychain — exactly what Chrome does. One prompt; **Always Allow** sticks for signed builds. |
| `.mockKeychain` | Never touch the keychain (`--use-mock-keychain`). Cookies are "encrypted" with a fixed mock key — fine for demos, kiosks, and CI; not for browsing profiles you care about. |

**How `.automatic` detects a dev build:** at startup CefKit inspects the main
executable's static code signature (Security framework,
`SecCodeCopySigningInformation`). An empty/absent certificate chain means
ad-hoc or unsigned — the signature of every local `swift build` and of
`cef bundle`'s ad-hoc fallback — so the mock key is used and the prompt never
appears. A real certificate chain (Apple Development, Developer ID, App
Store) means the keychain is used, Chrome-style. If the signature can't be
inspected at all, CefKit conservatively assumes a properly signed build and
uses the real keychain — the safe failure mode for user data.

**Why the prompt re-appears for ad-hoc dev builds:** the keychain item's
access control list records the app's *code-signature identity*. Ad-hoc
signatures change on every rebuild, so the "Always Allow" grant can never
match the next build. Signing with a stable identity fixes this: `cef bundle`
auto-detects one (or take `--sign` / cefapp.json `"signingIdentity"`), and
Xcode-managed signing does the same. With a real identity the prompt is
one-time: click **Always Allow** once and it never returns, across rebuilds
and updates.

**Why the dialog can't be Touch ID or restyled:** it is the legacy keychain
ACL prompt, drawn by the macOS security daemon (`securityd`), not by your
app. There is no API to replace it, suppress it for the real keychain, or
upgrade it to Touch ID/local authentication. Chrome shows the exact same
dialog on first run.

User-specified switches always win: if you set `use-mock-keychain` yourself
in `extraCommandLineSwitches`, the policy never duplicates or overrides it.

## JS ↔ Swift bridge

`CefBridge` lets page JavaScript call Swift functions and get a typed reply
back as a `Promise`. It is built on CefSwift's custom-scheme machinery: the
reserved `cefswift` scheme (registered automatically in every process) routes
`POST cefswift://bridge/<name>` requests to functions you register.

```swift
// Typed (Codable in/out — recommended):
struct Person: Codable { let name: String }
struct Greeting: Codable { let message: String }

CefRuntime.shared.bridge.register("greet") { (person: Person) in
    Greeting(message: "Hello, \(person.name)!")
}

// Raw (Data in/out) when you want to handle encoding yourself:
CefRuntime.shared.bridge.register("raw") { (body: Data) async throws -> Data in
    body
}
```

Handlers are `async` and run off the main thread — hop to `@MainActor` for
UI work. Thrown errors surface in JS as a rejected `Promise` (HTTP 500); an
unknown function name rejects with a 404.

```js
const reply = await window.cefSwift.invoke('greet', { name: 'Ada' });
console.log(reply.message); // "Hello, Ada!"
```

`window.cefSwift` is defined by a small shim available as
`CefBridge.javascriptShim` (idempotent). Two delivery options:

1. **Embed the shim in your pages** (recommended for production). If you
   serve your UI from a custom scheme, put `<script>…shim…</script>` in the
   HTML — shim present before any page code runs.
2. **Auto-injection** (`bridge.autoInjectsShim`, default `true`). Injects at
   load-end, but only while at least one bridge function is registered.
   Caveat: load-end fires *after* the page's own scripts start, so code
   running at parse time or `DOMContentLoaded` may not see `window.cefSwift`
   yet. For deterministic startup, use option 1 with `autoInjectsShim = false`.

Transport: `POST cefswift://bridge/<function-name>`; the scheme is
`standard | secure | corsEnabled | fetchEnabled`, responses carry
`Access-Control-Allow-Origin: *`, `OPTIONS` preflights answered. Responses
fully buffered in v1 — keep payloads reasonably sized.

**Security:** bridge handlers run with your app's full privileges, and any
page in any browser of your app can call them. Validate and clamp all
inputs; decode with strict Codable types, not dictionaries. Don't expose
generic primitives ("run shell command"); design narrow, purpose-specific
functions. If you load arbitrary third-party content, don't register
sensitive functions in those browsers. Replies are visible to the page.

### Swift → JS events

`bridge.broadcast(event:data:)` pushes a JSON-encoded payload to every active
browser as `window.cefSwift._emit("<event>", <json>)`. Pages subscribe via
`window.cefSwift.on("<event>", fn)` (returns an unsubscribe closure). Encoding
errors are logged to stderr and the broadcast dropped; pages without the shim
or without a listener silently ignore. A pre-encoded JSON string overload
(`broadcast(event:json:)`) is available for callers using a custom encoder.

```swift
CefRuntime.shared.bridge.broadcast(event: "tick", data: ["t": Date().timeIntervalSince1970])
```

```js
const off = window.cefSwift.on('tick', payload => console.log(payload.t));
```

The Gallery example ships a "Swift ↔ JS Bridge" card (`gallery://` page
served by a `CefSchemeHandler` with shim embedded; auto-invokes `greet` on
load and mirrors each call into a SwiftUI log). See
`Examples/Sources/Gallery/BridgeCard.swift`.

## Links, popups & new windows

When a page tries to open a link or popup — `target=_blank`, `window.open`,
⌘/Ctrl-click, middle-click, Shift-click — CefSwift surfaces a
`CefWindowOpenRequest` to your delegate and asks for a `CefWindowOpenAction`.

```swift
func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction
```

`CefWindowOpenRequest` carries: `targetURL`, `frameName`, `disposition`
(mirrors Chromium's `WindowOpenDisposition` — `.currentTab`,
`.newForegroundTab`, `.newBackgroundTab`, `.newPopup`, `.newWindow`),
`userGesture`, popup `features`, and `isSourceOffscreen`. Use
`disposition.prefersForeground` to decide whether a new tab fronts.

Return one of:

- **`.deny`** — suppress.
- **`.openInCurrentBrowser`** — load in *this* browser. Safe for OSR.
- **`.allowNativePopup`** — let CEF create a native popup browser/window.
  **Only safe for windowed/chrome browsers.** Automatically downgraded to
  `.openInCurrentBrowser` (or `.deny` with no URL) for OSR — a CEF popup
  created for an OSR parent gets no render handler and cannot be hosted.
- **`.handled`** — *you* opened your own tab/window; CEF's native popup is
  blocked.

If you don't implement the delegate, the default per hosting mode:

| Source | URL present | Default |
|--------|-------------|---------|
| OSR | yes | `.openInCurrentBrowser` |
| OSR | no (`about:blank`) | `.deny` |
| Windowed / chrome | yes | `.openInCurrentBrowser` |
| Windowed / chrome | no | `.allowNativePopup` |

Guarantee: an OSR browser never silently spawns an unhosted native popup.
The downgrade is applied in two places (policy helper + `on_before_popup`).

```swift
// Arc-style tabs: open links as tabs, honoring the disposition.
func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
    guard let url = request.targetURL else { return .deny }
    let tab = BrowserTab(url: url)
    tabs.append(tab)
    if request.disposition.prefersForeground { select(tab) }
    return .handled
}

// For CefWebView / CefMetalWebView, use the closure instead of subclassing:
model.onWindowOpen = { request in .openInCurrentBrowser }
```

The older `requestsPopupFor(_:) -> CefPopupDecision` / `onPopupRequest`
still work — bridged into the new API (`.allow` → `.allowNativePopup` with
the OSR downgrade, `.block` → `.deny`, `.openInSameBrowser` →
`.openInCurrentBrowser`). Prefer the new API for foreground/background-tab
control and popup features.

## Context menus

The default page context menu already offers Back/Forward/Reload,
Cut/Copy/Paste (in editable fields), Copy Link Address, Copy/Save Image,
View Page Source, and Inspect/DevTools, gated to the click target. Leaving
an item in the menu and returning `false` from the command delegate runs
CEF's built-in behavior.

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

App-defined command IDs must be in
`CefMenuModel.userCommandIDFirst ... userCommandIDLast`. The standard CEF
command IDs are mirrored by `CefContextMenuCommand` (`.back`, `.copy`,
`.viewSource`, …); `CefMenuCommandRange` helps classify a command id.

Hosting: windowed/chrome browsers present CEF's own native menu;
`CefMetalWebView` (OSR) has no CEF window, so CefSwift presents an `NSMenu`
built from the `CefMenuModel`, then reports the chosen command back to CEF.
