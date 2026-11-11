# Architecture

## Modules

```
CefSwiftUI   CefSwiftApp, CefWebView, host views, CefBrowserWindow.setToolbar
    │
CefKit       CefRuntime, CefBrowser, CefBrowserWindow, CefBridge, CefDevTools,
    │        CefProfile, CefBrowserDelegate, configuration types
    └── CCef         vendored CEF C headers + runtime loader (C)

cef-helper   the helper-process executable, bundled five times by the plugin
CefPlugin    `swift package cef download | bundle | info | clean`
```

## The C bridge

CefSwift talks to CEF through its C API and never links the framework.

- `Scripts/generate-bindings.py` preprocesses the vendored headers at the
  pinned `CEF_API_VERSION` and writes two generated files: `ccef_capi.h`
  (an umbrella include of the whole C API) and `ccef_symbols.h` (every
  exported `cef_*` function).
- `ccef_loader.c` expands that list into trampolines with CEF's real function
  names. Each binds itself with `dlsym` on first call, so Swift calls
  `cef_initialize(...)` directly and unused functions cost nothing.
- At start-up `CefRuntime` `dlopen`s the framework from the app bundle and
  checks `cef_api_hash` against the hash the headers define for the pinned
  version. A mismatched framework fails with a clear error instead of
  misbehaving.

Because the API version is pinned, CEF binaries can be updated without
touching Swift code; adopting newer C APIs means bumping the pin in
`ccef_config.h` and regenerating.

## Object ownership

CEF objects are intrusively reference-counted.

- **Structs CefSwift implements** (handlers, delegates, callbacks) come from
  `cefAllocate`, which places a refcount and a retained Swift owner in a
  hidden header before the struct. Callbacks recover the owner with
  `cefOwner`; the owner is released when the count reaches zero.
- **Objects CEF gives us** are held in `CefRef`, which releases on deinit.
- **The rules**: an object passed *to* a CEF function is consumed; an object
  *returned* by CEF, or passed into one of our callbacks, arrives with a
  reference we must release.

## Threads

Chromium's UI thread is the app's main thread: CEF runs with an external
message pump driven from the main run loop (`CefMessagePump`), so SwiftUI and
Chromium share it. Public API is `@MainActor`. The few callbacks CEF makes on
its IO thread — request filtering, authentication, scheme handlers — are
`Sendable` closures or hop to the main actor before reaching your code.

## Browsers and clients

`CefBrowser` is created as a model first and bound to a Chromium browser when
it is hosted. Each gets a `CefBrowserClient` owning its handler structs.
Browsers that Chromium creates on its own (popups, DevTools, tabs opened in
Chrome's UI) reuse their opener's client or the runtime's default client, so
every callback resolves its `CefBrowser` by Chromium's browser identifier
through `CefRuntime`'s registry. Those browsers are wrapped automatically and
announced via `CefBrowserDelegate.browser(_:didOpen:)` and
`CefRuntime.onBrowserCreated`.

Policy callbacks that Chromium can wait on are bridged to `async` delegate
methods: the CEF callback object is kept alive in a `Task` and completed with
the delegate's answer.

## Hosting

| Host | Style | How it draws |
|---|---|---|
| `CefWebView`, `.windowed` | Alloy | Chromium's native `NSView` as a subview |
| `CefWebView`, `.offscreen` | Alloy | shared `IOSurface` set as layer contents; input forwarded by `CefOffscreenBrowserView` |
| `CefBrowserWindow` | Chrome | a CEF Views window; your toolbar is an `NSToolbar` item or title-bar accessory |
| `CefRuntime.openChromeWindow` | Chrome | Chrome's own window and UI |

macOS only provides Chrome style in windows Chromium creates, which is why
the full-browser hosts own their `NSWindow`.

## JavaScript bridge and DevTools

`CefDevTools` attaches a DevTools message observer to the browser and speaks
the Chrome DevTools Protocol in-process. `evaluateJavaScript`, user scripts,
`snapshot` and `CefBridge` are built on it:

- the bridge registers a binding (`Runtime.addBinding`) and injects its
  JavaScript half at document start (`Page.addScriptToEvaluateOnNewDocument`);
- calls arrive as `Runtime.bindingCalled` events carrying the execution
  context, whose origin and frame Chromium reports — the basis of the access
  policy;
- replies and events are delivered with `Runtime.evaluate`.

Browsers with bridges or user scripts are created on `about:blank`, set up,
and only then navigated, so the first document already has them.

## Processes

The app is Chromium's browser process. Renderers, GPU and utility processes
run from the helper apps inside the bundle, all the same `cef-helper` binary
calling `CefRuntime.helperMain()`. Custom URL schemes are forwarded to
helpers on their command line so every process registers the same list.
