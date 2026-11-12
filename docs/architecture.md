# Architecture

How CefSwift works inside, and why. For how to use it, see the
[guide](guide.md).

## Modules

```
CefSwiftUI   CefSwiftApp, CefWebView, CefWindowedBrowserView, CefOffscreenBrowserView,
    │        CefBrowserWindow.setToolbar and setTabAccessory
CefKit       CefRuntime, CefBrowser, CefBrowserWindow, CefBrowserDelegate, CefBridge,
    │        CefDevTools, CefProfile, configuration and policy types
CCef         vendored CEF C headers, the generated bridge, the runtime loader (C)

cef-helper   the helper-process executable, bundled five times by the plugin
CefPlugin    swift package cef download | bundle | info | clean
```

## The C bridge

CefSwift calls CEF through its C API and never links the framework.

- `Scripts/generate-bindings.py` runs the C preprocessor over the vendored
  headers at the `CEF_API_VERSION` pinned in `ccef_config.h` and writes two
  files: `ccef_capi.h`, which includes the whole C API, and
  `ccef_symbols.h`, which lists every exported `cef_*` function the pinned
  version declares.
- `ccef_loader.c` expands that list into trampolines with CEF's own function
  names. Each one looks itself up with `dlsym` on its first call, so Swift
  calls `cef_initialize(...)` directly and unused functions cost nothing.
- At start-up `CefRuntime` `dlopen`s the framework from the app bundle and
  compares `cef_api_hash` with the hash the headers define for the pinned
  version. A framework that does not match fails with
  `CefError.apiHashMismatch` instead of misbehaving.

Because the API version is pinned, CEF binaries update without changes to
the Swift code. Adopting newer C APIs is a separate step that moves the pin
([automation](automation.md#moving-cef_api_version)).

## Object ownership

CEF objects are intrusively reference-counted.

- Structs CefSwift implements (clients, handlers, callbacks) come from
  `cefAllocate`, which places a reference count and a retained Swift owner
  in a hidden header before the struct. Callbacks recover the owner with
  `cefOwner`. The owner is released when the count reaches zero.
- Objects CEF returns are held in `CefRef`, which releases them on deinit.
- An object passed to a CEF function is consumed. An object returned by
  CEF, or passed into a CefSwift callback, arrives with a reference the
  receiver must release.

## Threads

Chromium's UI thread is the app's main thread. CEF runs with an external
message pump driven from the main run loop (`CefMessagePump`), so SwiftUI and
Chromium share one thread, and the public API is `@MainActor`. The few
callbacks CEF makes on its IO thread (request filters, HTTP authentication,
scheme handlers) are `Sendable` closures or hop to the main actor before
reaching app code.

## Browsers and clients

A `CefBrowser` is created as a model and bound to a Chromium browser when it
is first hosted. Each one gets a `CefBrowserClient` that owns its handler
structs. Browsers that Chromium creates itself (popups, DevTools, tabs opened
from Chrome's UI) share their opener's client or the runtime's default
client, so every callback looks up its `CefBrowser` by Chromium's browser
identifier in `CefRuntime`'s registry. Such browsers are wrapped as they
appear: a popup inherits its opener's delegate, which hears about it through
`browser(_:didOpen:)`; a tab without an opener goes to
`CefRuntime.onChromiumOpensTab` when it is set; the rest are passed to
`CefRuntime.onBrowserCreated`.

Policy callbacks that Chromium can wait on become `async` delegate methods:
the CEF callback object is kept alive in a `Task` and completed with the
delegate's answer.

Some state has no CEF event of its own. `favicon` is downloaded with
`download_image` when the display handler reports the page's icon
addresses. `zoomLevel` is read back with `get_zoom_level` after each
navigation, each zoom command and each change made through the property,
in every browser, since Chromium keeps one level per site.

## Hosting

| Host | Style | How it draws |
|---|---|---|
| `CefWebView`, `.windowed` | Alloy | Chromium's native `NSView` as a subview of `CefWindowedBrowserView` |
| `CefWebView`, `.offscreen` | Alloy | Frames in a shared `IOSurface`, set as layer contents by `CefOffscreenBrowserView`, which forwards input |
| `CefBrowserWindow` | Chrome | A CEF Views window; your toolbar is an `NSToolbar` and your accessory a title-bar accessory view |
| `CefRuntime.openChromeWindow` | Chrome | Chrome's own window and UI |

macOS provides Chrome style only in windows Chromium creates, which is why
the Chrome-style hosts own their `NSWindow`. A `CefBrowserWindow` draws the
whole content area in one layer, so `contentInsets` and
`contentCornerRadius` are drawn by a native view laid over the page that
paints everything except the page's rectangle and passes events through.

## Chromium's AppKit classes

The framework exports only CEF's C API, but Chromium's macOS UI is AppKit,
and its Objective-C classes are visible to the Objective-C runtime.
`CefObjCHook` overrides a few of their methods. Each override is looked up
by class name, selector and type encoding; a missing one is logged, left
out, and listed by SelfTest's "runtime hooks" check, and the feature that
needs it falls back to Chromium's own behavior. An override added to a
class that inherits the method stays on that class alone.

**Surfaces.** Chromium's bubbles, dialogs, find bar and status bubble are
Views widgets, each in a `NativeWidgetMacNSWindow` that Chromium attaches to
the browser window as a child window. Every CEF Views window is a
`CefNSWindow`, a subclass; `CefSurfaceTracker` overrides its
`-addChildWindow:ordered:` and `-removeChildWindow:`. As Chromium attaches a
widget, `CefBrowserWindow` makes it transparent; once attached, it reads
what the widget shows and applies the kind's presentation: it restores the
widget and moves it under its anchor with `setFrameOrigin(_:)` (and again
when the widget or the window moves or resizes), or keeps it transparent,
ignoring the mouse, and closes it as Esc would, or for the find bar with
`IDC_CLOSE_FIND_OR_STOP`. Status bubbles and fullscreen notices are only
kept transparent, since Chromium reuses their windows.

A widget's kind comes from the class of the view inside it. Views reports
each view's class name to accessibility as `AXDOMClassList`, so the tracker
walks the widget's accessibility tree (`QRCodeGeneratorBubble`,
`CastDialogView`, `FindBarView`, `LoginView`, `StatusView`,
`SubtleNotificationView`, `DownloadBubbleContentsView`, …). When no class
matches, the title is compared with Chromium's localized strings for each
kind, read by identifier from the resource bundle
(`cef_resource_bundle_t`); anything else is `.other`, with the title or the
first specific class name. The QR code bubble's address comes from its text
field's accessibility value.

Commands that open a surface the window replaces or hides never reach
Chromium: `CefBrowser.execute(_:)` and the command handler's
`on_chrome_command` hand them to the window's presenter first. The custom
find bar drives CEF's `find`/`stop_finding` and reads `on_find_result`; the
custom status bubble reads `on_status_message`; the Cast picker uses CEF's
`cef_media_router_t`.

CEF's own hooks do not cover placement: `cef_window_delegate_t` and
`cef_browser_view_delegate_t` have no say in where bubbles go, and Chromium
anchors them to its toolbar's buttons. `CEF_CTT_NORMAL` and
`CEF_CTT_LOCATION` do not change where they appear in a `CefBrowserWindow`,
which does not add Chrome's toolbar view (`get_chrome_toolbar`) to its
window; adding it would draw Chrome's toolbar.

**Swipes.** For Chrome-style browsers, Chromium sets a
`ChromeRenderWidgetHostViewMacDelegate` on each page's
`RenderWidgetHostViewCocoa`; its `HistorySwiper` turns overscrolling
two-finger swipes into navigation and draws progress with a
`HistoryOverlayController`. CefSwift overrides the delegate's
`-shouldAllowHistorySwiping`, to follow
`allowsBackForwardNavigationGestures`, and the controller's
`-initForMode:`, `-showPanelForView:`, `-setProgress:finished:` and
`-dismiss`, to report progress to `navigationGestureProgress` and to skip
Chrome's overlay unless `.chromium` is chosen. Alloy-style browsers have no
such delegate; views track swipes themselves with
`NSEvent.trackSwipeEvent`, the offscreen view from its own scroll events
and the windowed view from a local event monitor, since Chromium's view
receives the events. The built-in indicator is a layer-backed view over the
page that never takes events.

## DevTools, JavaScript and the bridge

`CefDevTools` attaches a DevTools message observer to the browser and speaks
the Chrome DevTools Protocol in-process. `evaluateJavaScript`, user scripts,
`snapshot` and `CefBridge` are built on it:

- `evaluateJavaScript` is `Runtime.evaluate` with `awaitPromise`.
- User scripts are `Page.addScriptToEvaluateOnNewDocument`. Chromium does
  not run those in its `chrome://` pages, so there CefSwift evaluates them as
  each page starts loading.
- The bridge registers a binding (`Runtime.addBinding`) and injects its
  JavaScript half, a shim, at document start. Chromium adds the binding to
  every document's global object; the shim removes it from there and, only
  in documents that `access` permits, keeps it privately and defines the
  bridge's global. Calls arrive as `Runtime.bindingCalled` events that carry
  the execution context, whose origin and frame Chromium reports; Swift
  checks them against `access` again. Replies and events go back through
  `Runtime.evaluate`. Changing `access` replaces the shim, so it applies
  from the next document.

Browsers with bridges or user scripts are created on `about:blank`, set up,
and then navigated, so the first real document already has them.

## Internal-page services

CEF has no API for bookmarks, history or omnibox suggestions, but
Chromium's own pages reach those services: `chrome://bookmarks` through the
`chrome.bookmarks` extension API, and `chrome://history`, the new tab page
and `chrome://omnibox` through Mojo page handlers. `CefInternalPageService`
parks a hidden Chrome-style browser on such a page, created on first use,
and calls into the page through the DevTools Protocol. A call that times
out, or a renderer that dies, discards the browser; the next call starts a
new one.

Service browsers are left out of `CefRuntime.browsers` and
`CefBrowserWindow.all`. Their windows are transparent, ignore the mouse and
are ordered out whenever Chromium shows them, as it does when it brings its
windows forward. A service browser holds its profile, so a non-default
profile's service browsers close when its last browser closes, and start
again on the next call; the default profile's stay until the app quits.
Chromium saves every Chrome-style window in its session, these included,
and reopens them after a crash; their addresses carry a marker fragment, so
`CefRuntime` recognizes and closes them.

`chrome://history` cannot open in an incognito profile, so `CefHistory`
throws there instead of starting a service. An incognito profile's
bookmarks are the default profile's `CefBookmarks`, since Chromium shares
the original profile's bookmarks with its incognito profile.

## Quitting

`CefApplication.terminate(_:)` asks `CefRuntime` first. The runtime closes
every browser, so pages can run `beforeunload`, and declines the request. As
the last browser and the last Chromium window are destroyed, it calls
`terminate(_:)` again from the run loop, then calls `cef_shutdown()`. Calling
`cef_shutdown()` earlier, or from inside a CEF callback, crashes. A page that
asks to stay cancels the quit.

## Relaunching

Chromium allows one process per data directory. A second launch finds the
running one, hands it its command line and working directory, and exits;
`CefRuntime.initialize(configuration:)` throws
`CefError.anotherInstanceRunning` in that process. The running process
receives the launch from Chromium, activates the app and calls
`CefRuntime.onRelaunch` on the next run-loop turn, outside Chromium's
callback.

## Processes

The app is Chromium's browser process. Renderer, GPU and utility processes
run from the helper apps inside the bundle, all the same `cef-helper` binary,
which calls `CefRuntime.helperMain()`. Custom URL schemes reach helpers on
their command line (`--cefswift-schemes`), so every process registers the
same list. With the sandbox on, each helper seals itself before it loads the
framework ([sandbox](sandbox.md)).
