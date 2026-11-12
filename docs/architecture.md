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

CefBase      reference counting, strings and process messages, shared by
             CefKit and the helper (no Foundation, no AppKit)
CefRenderer  renderer-side features on the V8 API, run by the helper
CefHelper    the helper-process executable (cefswift-helper)

CefPlugin    swift package cef download | bundle | info | clean; builds the
             helper products and assembles the app
```

## The C bridge

CefSwift calls CEF through its C API and resolves every function at run
time, so the Swift modules build without the framework.

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
- In a bundle from `cef bundle`, the app executable also links the
  framework, weakly, so dyld loads it at launch and `dlopen` returns the
  library already loaded. See [Loading the framework at launch](#loading-the-framework-at-launch).

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
Chromium share one thread, and the public API is `@MainActor`.

CEF calls a few handlers on other threads. Where each arrives in CEF 156,
from the C API's comments and checked with `cef_currently_on` and thread
names at run time:

| Callback | Thread | CefKit |
|---|---|---|
| `cef_resource_request_handler_t.on_before_resource_load`, `get_resource_request_handler` | IO (`Chrome_IOThread`) | The request filter runs there, isolated to `CefIOActor`. |
| `cef_scheme_handler_factory_t.create` | IO | Creates the resource handler. |
| `cef_resource_handler_t.get_response_headers`, `cancel` | IO | Read and change the handler's locked state. |
| `cef_resource_handler_t.open`, `skip`, `read` | Chromium's thread pool (`ThreadPoolForegroundWorker`), in sequence | `open` starts the `CefSchemeHandler` in a task; `read` copies buffered bytes or waits for them. |
| `cef_request_handler_t.get_auth_credentials` | IO | Hops to the main actor for the delegate; CEF 156 does not call it. |
| `cef_cookie_visitor_t.visit`, `cef_download_handler_t` | UI | No hop needed. |
| `cef_render_handler_t`, `cef_accessibility_handler_t`, everything else | UI | `MainActor.assumeIsolated`. |
| `on_schedule_message_pump_work` | Any | Posts to the main queue. |

**Thread actors.** `CefIOActor` and `CefFileActor` are global actors
whose executor, `CefThreadExecutor`, posts each job to a CEF thread with
`cef_post_task`: `TID_IO`, and `TID_FILE_USER_VISIBLE`, a sequence on
Chromium's thread pool for blocking work. Its isolation checks
(`checkIsolated()`, `isIsolatingCurrentContext()`) ask
`cef_currently_on`, so a CEF callback on the IO thread is code isolated
to `CefIOActor` without a hop. The runtime asks an executor only from
macOS 15 on; `CefIOActor.assumeIsolated` and
`CefFileActor.assumeIsolated` check the thread themselves, so they work
on macOS 14 too.

Chromium's task runners exist from `on_context_initialized` to the end of
`cef_shutdown()`. Outside that span, jobs run on a serial dispatch queue
of the executor's own: before start-up at once; on start-up the queue
empties before jobs go to Chromium; from the moment `CefRuntime` begins
shutting down, jobs wait and run on the queue after `cef_shutdown()`
returns, once Chromium's threads are gone. A job Chromium destroys without
running goes to the queue the same way. So no job is lost or runs at the
same time as another, and quitting waits for nothing.

**Scheme handlers.** A `CefSchemeHandler` runs with its own isolation:
nonisolated on Swift's concurrent executor, or on `CefIOActor` or the
main actor if its type is isolated to one. Its body is data, a file or an
async sequence of `Data`. A file is read in 256 KB chunks on
`CefFileActor`; a sequence is iterated in a task. Either runs at most
1 MB ahead of the page: a write waits until `read` drains the buffer.
`read` copies what is buffered, or, with nothing buffered, keeps CEF's
buffer and callback until the next chunk arrives. Chromium skips to the
start of a requested range itself, then serves the rest of the body with
the handler's status, so CefKit answers single byte ranges completely
(206 with `Content-Range` and only the range's bytes, or 416) and reports
Chromium's skip as done.

The request filter was already synchronous on the IO thread, and the
scheme handler already answered off the main thread, so neither changed
the main thread's work. A page that fetches 500 1 KB responses and one of
200 MB through a scheme handler, with a request filter on every request,
keeps the main thread busy for about 70 ms either way (Chromium's own work
for the requests). The 200 MB body raised the app's peak footprint by
194 MB as one `Data`, and by 12 MB as a stream or a file, in the same
time (about 200 ms).

The renderer side runs on the renderer's main thread (`TID_RENDERER`),
which is the helper process's main thread, so its extensions are
`@MainActor` and CEF's callbacks enter it with `MainActor.assumeIsolated`.
CEF 156's `cef_render_process_handler_t` reports only frames' contexts
(`on_context_created`, `on_context_released`); it has no callbacks for
worker or service-worker contexts, so the renderer side has no worker
hooks.

## Browsers and clients

A `CefBrowser` is created as a model and bound to a Chromium browser when it
is first hosted. Each one gets a `CefBrowserClient` that owns its handler
structs. Browsers that Chromium creates itself (popups, DevTools, tabs opened
from Chrome's UI) share their opener's client or the runtime's default
client, so every callback looks up its `CefBrowser` by Chromium's browser
identifier in `CefRuntime`'s registry. Such browsers are wrapped as they
appear: a popup inherits its opener's delegate, which hears about it through
`browser(_:didOpen:)`. A browser in one of Chromium's own tabbed windows
arrives on the default client (`get_default_client`) without a browser
view, so CEF cannot move it into a `CefBrowserWindow`; it goes to
`CefRuntime.onOpenBrowser` when that is set, with its window kept off
screen until the handler answers. Its opener is the browser whose
`on_open_urlfrom_tab` (⌘- and ⇧-clicks) or `on_before_popup` CefKit left
to Chromium just before, which CEF does not report itself. The rest are passed to `CefRuntime.onBrowserCreated`.

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
kept transparent, since Chromium reuses their windows. Chromium fades some
widgets in by setting their window's alpha, the status bubble on every
hover, so an override of `-setAlphaValue:` in `NativeWidgetMacNSWindow`
keeps a hidden surface's window at 0.

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
find bar drives CEF's `find`/`stop_finding` and reads `on_find_result`. A
new search only highlights its matches (Chromium reports an active ordinal
of 0 and an empty selection), so once its count is final `CefFindSession`
repeats the request, which selects the first match, as Chrome's find bar
does; the
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

## Frame timing

Offscreen browsers are created without external begin frames, so
Chromium's compositor times frames from its own timer at the browser's
frame rate (`windowless_frame_rate`), and each frame arrives through
`on_accelerated_paint` as an `IOSurface`.

Driving frames from the view's display link instead
(`external_begin_frame_enabled` and `send_external_begin_frame` on every
refresh) was measured on a 60 Hz display; the Mac had no 120 Hz display.
CEF keeps one external begin frame in flight and ignores a request until
the last one is acknowledged, and a frame's deadline is the frame
interval the frame rate gives. At a frame rate of 30, CEF's default, the
acknowledgement comes after the next refresh, so every other request is
dropped: pages run 60 animation frames a second but 30 reach the screen.
At a frame rate of 60 or more, every refresh paints. A second request
4 ms after each refresh runs animation frames twice per refresh. An
offscreen page that animates, and one that follows the mouse, measured
over 3 s, twice each:

| Frame timing | Painted frames a second | Spread of paint intervals | Mouse move to painted frame, median / 90th percentile | CPU |
|---|---|---|---|---|
| Chromium's timer, rate 60 | 59.7 | 1.4–2.0 ms | 12–17 / 17–23 ms | 34–40% |
| Display link, rate 30 | 30 | 5.7–6.4 ms | 20–24 / 35–37 ms | 35–36% |
| Display link, rate 60 | 59.7 | 1.6–2.4 ms | 16–23 / 35–37 ms | 40–42% |
| Display link, rate 120 or 240 | 59.3–59.7 | 1.6–2.4 ms | 17–25 / 29–38 ms | 39–43% |

The display link matches the timer's rate and pacing and adds latency: a
mouse move waits for the next refresh, then for the main thread to send
the request. CefKit keeps Chromium's timer. `Benchmarks.frames()` in
SelfTest (`-benchmark frames`) measures both on another display.

## Offscreen accessibility

Windowed browsers expose Chromium's own `NSAccessibility` objects. For
offscreen browsers Chromium only computes the tree ("tree only" mode) and
hands it to CEF's accessibility handler, which the render handler returns
from `get_accessibility_handler`:

- `set_accessibility_state(STATE_ENABLED)` starts the tree. With
  `CefOffscreenAccessibility.automatic`, `CefOffscreenBrowserView` calls it
  on the first sign of an assistive app: VoiceOver running, the first
  children, hit-test or focus query on the view, or `CefApplication`
  receiving `AXEnhancedUserInterface` or `AXManualAccessibility`, which
  arrive through the informal accessibility protocol.
- `on_accessibility_tree_change` delivers serialized `AXTreeUpdate`s, one
  tree per frame, with node data, child lists, relative bounds, tree data
  (focus, selection, load state) and events.
  `on_accessibility_location_change` delivers moved nodes. Both arrive as
  `cef_value_t` trees. Reading a large page's tree value by value takes
  hundreds of milliseconds, so `cef_write_json` turns each into text in one
  call, a serial background queue parses it into `CefJSON`, and the main
  thread applies the results in the order Chromium sent them.
- `CefAccessibilityTree` applies the updates as Chromium's `AXTree` does
  (clearing, reparenting, removing orphaned subtrees) and joins the frames'
  trees through each `<iframe>` node's `childTreeId`. A tree without a
  parent is the main document; a new one replaces the old one and its
  frames. Frames are resolved on demand: relative bounds plus each offset
  container's origin, less its scroll offset, with transforms applied,
  then offset by the hosting `<iframe>`, and divided by the device scale
  factor, since Chromium reports physical pixels.
- Chromium's scroll updates travel separately from location updates and
  CEF does not forward them, so the document's scroll position, which the
  render handler's `on_scroll_offset_changed` reports, is written into the
  root node.
- `CefOffscreenBrowserView` keeps one `NSAccessibilityElement` per node.
  Elements hold only a node identifier and read the tree on every query;
  the role table follows Chromium's macOS mapping. Ignored nodes are
  skipped, and leaves (text, images, buttons, plain text fields) hide
  their insides. Each change becomes the matching `NSAccessibility`
  notification; layout notifications are coalesced to one per 100 ms.

CEF's C API has no way to perform accessibility actions, so actions go
through input: clicks at the node's centre, arrow keys, and
`Input.insertText`. Focus and scrolling use `DOM.focus` and
`DOM.scrollIntoViewIfNeeded`. Those need a DOM node, which the serialized
tree does not carry; the DevTools `Accessibility` domain shares Chromium's
node identifiers with it, so `Accessibility.getChildAXNodes` on the node's
parent yields the node's `backendDOMNodeId`. Only the main frame's nodes
are looked up this way: a frame in another renderer process numbers its
nodes independently, so a number from it could name a different node in
the main frame's process. Nodes in frames are clicked instead.

When the browser closes or the tree is turned off, the tree is emptied
and the view posts `AXUIElementDestroyed` for every element it handed out.

## Page-facing features

A page can tell a browser apart from a stock one by what it can observe:
globals it did not define, scripts it did not load, a debugger that stops
it, or a DevTools session that changes how `console` behaves. So features
that reach into pages run in the renderer, through the helper's own code,
and the DevTools Protocol is used only for what nothing else offers.

**The renderer side.** The helper executable is Swift
(`Sources/CefHelper`, `Sources/CefRenderer`). It gives `cef_execute_process`
an app whose render process handler drives a list of
`CefRendererExtension`s, each with hooks for a browser's arrival in the
process (with the `extra_info` it was created with), each JavaScript
context created and released, and process messages whose names start with
its prefix. Everything runs on the renderer's main thread, which on macOS
is the process's main thread, so extensions are `@MainActor` and CEF's
callbacks enter it with `MainActor.assumeIsolated`. `V8Value`, `V8Context`
and `V8Exception` wrap the V8 C API; `CefProcessMessage` (in `CefBase`,
shared with the browser process) is a message's name and plain arguments.
A later renderer-side feature is one more extension type.

`PageScripting` is the extension behind bridges, user scripts and
`evaluateJavaScript`:

- A browser's bridges and user scripts travel as JSON in the `extra_info`
  of its creation (`cef_browser_host_create_browser`,
  `cef_browser_view_create`, and `on_before_popup` for popups). CEF hands
  `extra_info` to every renderer process that shows a frame of the
  browser, before that frame's first document starts, so nothing waits on
  a message and no first document runs on `about:blank`.
- When a context is created in a frame's main world, the user scripts that
  match run with `cef_v8_context_t.eval`, as scripts without a URL; scripts
  for document end run from a `DOMContentLoaded` listener added first.
- A bridge is a global object whose named-property interceptor answers
  `invoke`, `on`, `off` and any other name with a native function. A call
  creates a promise, sends `cefswift.page.call` with the arguments as JSON
  and the document's origin, and the reply resolves or rejects it. V8 values
  are converted to JSON through the V8 API, so no page script, `JSON`
  object or prototype takes part. The browser process checks the caller's
  frame and origin against `access`, and the origin against the frame's
  address, before a handler runs. Cross-site frames run in other renderer
  processes, which get the configuration with the browser, so `access`
  decides for them as for any frame.
- `evaluateJavaScript` sends `cefswift.page.evaluate` to the main frame,
  whose renderer runs the script in the main world and sends the value
  back as JSON. A returned promise is awaited through its `then`.
- Changes after creation (`addUserScript`, `CefBridge.access`) go as a
  `cefswift.page.configure` message to every frame of the browser. A
  renderer process reports its configuration generation the first time it
  sees one of the browser's documents, and gets the current one if it is
  older.

Two CEF 156 behaviors shape this code. A message from the browser process
is handled inside a scope that defers promise jobs, and Blink does not run
them at the end of that task, so after settling a promise the renderer
enters the context again from a task of its own, whose exit runs them. And
a native function created outside a V8 callback, as in a message handler,
never reaches its Swift side when called; such functions are looked up
through an interceptor on each call (`V8Context.durableFunction`).

**What still uses the DevTools Protocol.** `CefDevTools` attaches a DevTools
message observer to the browser and speaks the protocol in-process. CEF
attaches the session on the first message and keeps it until the browser
closes. An attached session with no domain enabled changes nothing a page
can measure; enabled domains do (see the guide's "Compatibility with bot
protection"). These use it:

| Feature | Protocol use |
|---|---|
| `browser.devTools` | Whatever the app sends. |
| `evaluateJavaScript(_:userGesture: true)` | `Runtime.evaluate` with `userGesture`, the only way to grant a user activation. |
| `snapshot()` | `Page.captureScreenshot`. |
| `CefPasskeyMode.app` and `.disabled` | `WebAuthn`, `Debugger`, `Page` and `Runtime` enabled for the browser's lifetime; see [Passkeys](#passkeys). |
| `discard()` | `Runtime.evaluate` and `DOMDebugger.getEventListeners` on the page's window, to find a `beforeunload` listener, which JavaScript cannot list. |
| Offscreen accessibility actions | `Accessibility.enable` for the length of one lookup, then `DOM.focus`, `DOM.scrollIntoViewIfNeeded`, `Input.insertText`. |
| Internal-page services | Service hosts only, which show Chromium's own pages, never yours. |

A browser created again after a discard enables the domains its session
had enabled before, before its page loads; a session that was never used
stays unattached.

## Internal-page services

CEF has no API for bookmarks, history, most-visited sites, omnibox
suggestions or tab discarding, but Chromium's own WebUI pages reach those
services. `CefInternalServices`, one per profile, calls them from hidden
Chrome-style browsers it calls service hosts.

`CefHistory.mostVisited()` binds a new most-visited page handler for each
call. Chromium's `TopSites` reads the list from history once, shortly after
it loads, and then hourly, and a handler's `updateMostVisitedInfo` returns
that cached list; creating a handler is what makes `TopSites` read history
again. The handler reports the cached tiles first and the fresh ones when
they differ, so the call waits a moment for a second report.

**What binds where.** The browser process binds a WebUI page's Mojo
interfaces, and grants its extension APIs, by the page's host, whatever
its path. A renderer that asks for an interface its host does not bind is
killed (`WebUIController binder missing for: …`, bad IPC message 221). So
each interface has one host, and the hosts cannot share a renderer:
Chromium locks a WebUI renderer to its host, and neither
`--process-per-site` nor `--renderer-process-limit=1` changes that.

| Host | Reaches | Used for |
|---|---|---|
| `chrome://bookmarks` | `chrome.bookmarks`, `chrome.tabs`, `chrome://favicon2` | `CefBookmarks`, `CefHistory.favicon` |
| `chrome://history` | `history.mojom.PageHandler`, `chrome://favicon2` | `CefHistory.search`, `remove` |
| `chrome://new-tab-page-third-party` | `most_visited.mojom.MostVisitedPageHandlerFactory` | `CefHistory.mostVisited` |
| `chrome://omnibox` | `mojom.OmniboxPageHandler` | `CefAutocomplete` |
| `chrome://discards` | `discards.mojom.DetailsProvider` | Discarding |

`chrome://new-tab-page` binds most-visited and the search box's
`searchbox.mojom.PageHandlerFactory` too, and the search box answers
queries with Chromium's autocomplete. It ranks for the new tab page,
though: a web search first even when a bookmark matches the typed
address, no match on bookmark titles, and no relevance or bookmarked flag
in its results. CefKit keeps `chrome://omnibox`, whose controller is the
address bar's.

**The smallest document.** A service host loads the host's
`strings.m.js`, a few kilobytes of JavaScript that Chromium shows as text,
instead of the page's app, and each service imports only the generated
`*.mojom-webui.js` module it needs, from `chrome://resources` where
Chromium serves it there. Its renderer has the host's bindings and none of
the app's scripts, styles or elements. A host starts in about a tenth of a
second.

**Services as modules.** A `CefServiceModule` names the hosts that can
serve it and a JavaScript `setup` that builds a service object once per
document — a bound Mojo remote, or an extension API with listeners. A
call evaluates a function against that object through the DevTools
Protocol and returns its JSON result; a module that serves from several
hosts (favicons) uses whichever of them runs. A module reports events
through one DevTools binding per host, and subscribers hear them while the
host runs. Adding a service is declaring a module and calling it.

**Lifetime.** A host starts on the first call that needs it and closes 30
seconds after its last one, when macOS reports memory pressure, when its
profile's last browser closes (except the default profile's), and when
the app quits. A call that times out, or a renderer that dies, closes the
host; the call throws and the next one starts the host again. Service
browsers are left out of `CefRuntime.browsers` and
`CefBrowserWindow.all`. Their windows are 1 × 1 point, since a hidden
window's compositor keeps buffers the size of the window, about 11 MB of
GPU memory for a default-sized one, and they are transparent, ignore the
mouse and are ordered out whenever Chromium shows them, as it does when it
brings its windows forward. Chromium saves every Chrome-style window in
its session, these included, and reopens them after a crash; their
addresses carry a marker fragment, so `CefRuntime` recognizes and closes
them. Alloy-style and offscreen browsers do not get WebUI bindings for
these hosts, so a service host has to be a Chrome-style window.

**Reads without a renderer.** Chromium saves a profile's bookmarks to the
JSON file `Bookmarks` about 2.5 seconds after each change, replacing it
atomically. While the bookmarks host is not running, and nothing was
changed through it in the last 5 seconds, `CefBookmarks` reads the tree,
a folder's contents, a bookmark and the recent bookmarks from that file,
and `changes` watches it with a `DispatchSource`. A file in another
format version, or a profile with managed or account bookmarks, which the
file does not hold, falls back to the host. Searches and lookups by
address, whose matching is Chromium's, and every change go through the
host. History, favicons and top sites live in SQLite databases that
Chromium opens with exclusive locking: a read-only open fails with
`SQLITE_BUSY` once Chromium has written, and an `immutable` open reads
pages Chromium may be writing, so CefKit reads them only through the
hosts. The DevTools Protocol of Chromium 156 has no domain for any of
these services.

`chrome://history` cannot open in an incognito profile, and an incognito
profile keeps no history, so `CefHistory` throws there instead of starting
a host. An incognito profile's bookmarks are the default profile's
`CefBookmarks`, since Chromium shares the original profile's bookmarks
with its incognito profile.

## Passkeys

With `CefBrowserOptions.passkeys` set to `.app` or `.disabled`,
`CefPasskeyAuthenticator` takes a browser's WebAuthn calls over through
its DevTools connection, before the browser loads its first page:

- `WebAuthn.enable`, without Chromium's UI, puts the browser's pages in a
  virtual authenticator environment. Chromium's dialog and its real
  authenticators (security keys, iCloud Keychain, phones) are not used
  there, and a call waits for an authenticator until its timeout.
- Each document's main-world context gets a function-call breakpoint
  (`Debugger.setBreakpointOnFunctionCall`) on its
  `CredentialsContainer.prototype.create` and `.get` before any of its
  scripts runs. `Page.addScriptToEvaluateOnNewDocument` runs a script of
  one statement, `debugger`, at the start of every document in an
  isolated world named `cefswift-passkeys`, which the page cannot see or
  reach. The renderer stops there. The document's main-world context has
  been reported by then, and `Runtime.evaluate` in that context works
  while the renderer is stopped, so the breakpoints are set before the
  page's first script. (Setting them when `Runtime.executionContextCreated`
  arrives, without the stop, loses to a script that calls at once.)
- A call stops the page before the call runs, in the caller's frame; the
  frame's script gives the execution context, which gives the origin and
  frame. `navigator.userActivation.isActive` is read in that frame with
  `throwOnSideEffect`, so the read cannot change the page. Nothing in the
  page is changed. Any other pause, such as a `debugger` statement in the
  page, is resumed at once.
- While the page is stopped, the delegate decides, and CefKit adds a
  virtual authenticator (CTAP 2.1, internal transport, resident keys,
  user verification) for that one call: empty for a registration, holding
  only the chosen passkey (its PKCS #8 key from the store) for an
  assertion, or with failing user verification for a refusal, which
  rejects the call at once. The page then resumes and makes its call.
  `WebAuthn.credentialAdded` or `credentialAsserted` reports the result,
  which goes to the store, and the authenticator is removed. An
  authenticator left over from an earlier call is removed before the next
  decision, so no call is answered unasked.

An Alloy browser discarded by closing it gets a new DevTools session when
it is created again, so the environment and the breakpoints are set up
again then; a Chrome-style tab discarded in place keeps them.

The private key of a passkey lives in the store, and in Chromium's browser
process only while an authenticator answers one call. A page learns only
what WebAuthn gives it: the credential ID, the public key, the user handle
and signatures.

Chromium's own WebAuthn dialog (`.chromium`) is a views widget: a child
window of a `CefBrowserWindow`, or a free-standing window for a browser in
a view. CefKit leaves it alone; closing it from AppKit crashes Chromium.
The iCloud Keychain authenticator in Chromium (`device/fido/mac`) calls
AuthenticationServices itself and checks for the
`com.apple.developer.web-browser.public-key-credential` entitlement;
without it, Chromium does not offer it.

## Discarding

`CefBrowser.discard()` frees a hidden browser's page and keeps the
`CefBrowser`. How depends on the runtime style.

A Chrome-style browser is a tab in a Chromium tab strip, so Chromium
discards it. CefKit starts Chromium with the `WebContentsDiscard` feature,
which discards a tab in place: the frame tree is torn down and the renderer
process exits once no other frame uses it, while the `WebContents` and its
navigation entries stay, marked to load again. Without the feature Chromium
replaces the `WebContents` with a new one, which CEF reports as the browser
closing and another opening.

Chromium's own policies (Memory Saver, urgent discarding under memory
pressure) never pick a CefKit tab. Each Chrome-style browser is the only,
and so the active, tab of its own Chromium window, and the discard
eligibility policy protects the active tab of every window, as it does a
tab with DevTools attached, which CefKit's DevTools connection counts as.
The `EXTERNAL` discard reason, which `chrome.tabs.discard()` uses, skips
those protections. CefKit calls `DiscardById` with it on the
`discards.mojom.DetailsProvider` of the default profile's
`chrome://discards` service host, after its own checks. It reads Chromium's other
protections (audio, media capture, form interaction, connected devices)
from `GetTabDiscardsInfo` as blockers, leaving out the ones it overrides.
That interface numbers tabs afresh on every query and describes them only
by address and title, so each discard looks its tab up again. CEF's frame
count for a browser drops to zero when Chromium discards its tab; when two
hidden tabs share an address and title, that tells which one went, and a
discard that reached the other tab reloads it and tries the next.
`chrome.tabs`, which the bookmarks host also has, numbers tabs stably and
discards with the same reason, but reports none of the protections other
than audio, so discarding stays on `chrome://discards`.

When the window is shown again, Chromium loads the tab
(`NavigationController::SetActive`), with its scroll position from the
saved page state. A command sent to a hidden discarded tab reloads it. The
DevTools session survives the discard, so bridges, user scripts and event
streams carry on unchanged.

An Alloy browser is not a tab, and Chromium has no lifecycle unit for it.
CefKit closes the Chromium browser and keeps the `CefBrowser` in
`CefRuntime.browsers` without an identifier. When its view is shown again,
or the browser is used, a new Chromium browser is created in the same view.
It always starts on `about:blank` and is set up before it navigates to the
saved address: `CefDevTools` enables again the domains enabled before, so
event streams keep delivering; the accessibility state is applied; then
passkeys, user scripts (scripts added with `addUserScript` included) and
bridges are installed, as for a new browser. Calls that wait for the
restore resume when that page starts loading, and
`browserDidRestore(_:)` follows. Its back/forward list starts from that
page. Closing a browser
never ends a renderer process another browser shares; Chromium keeps the
process until its last frame goes.

`CefRuntime.memorySaver` is applied by a monitor that polls which browsers
are off screen, at a quarter of the policy's interval and at most every 30
seconds, and listens for memory pressure through
`DispatchSource.makeMemoryPressureSource`. The lifecycle coordinator tells
it of every change of what is on screen, which restores browsers
discarded by closing when their view comes back.

## Lifecycle

`CefLifecycleCoordinator` turns window, app and system signals into what
Chromium is told, and publishes `CefBrowser.lifecycle`. It listens for
window occlusion, miniaturizing, key-window and first-responder changes
(`firstResponder` is key-value observable), app hiding and activation,
screen changes, screen sleep, thermal state and Low Power Mode, and
updates every browser once per run-loop turn.

What Chromium does by itself decides what is left to do. Measured with an
animated page and `document.visibilityState`:

| Host | Window covered | Minimized | Ordered out, or a tab not selected | App hidden |
|---|---|---|---|---|
| Alloy, in an app's view | Hidden by Chromium | Stays visible | Stays visible | Stays visible, 60 frames a second |
| Chrome style (`CefBrowserWindow`) | Hidden by Chromium | Hidden by Chromium | Hidden by Chromium | Hidden by Chromium |
| Offscreen | Hidden by the view (`was_hidden`) | Same | Same | Same |

`was_hidden` does nothing for windowed browsers in CEF 156. For an Alloy
browser in an app's view, the coordinator hides Chromium's `NSView`
whenever its window cannot be seen (its occlusion state is not visible,
or it is minimized or ordered out, or the app is hidden), which
Chromium's `WebContentsViewCocoa` reports as hidden. Covered windows are
included: Chromium notices a window of the same session covering it, but
not a full-screen app on another space, and it reports the page visible
again whenever its view moves or shows. The coordinator gives focus back
to the responder that had it when it shows the view again, and shows it
on `willUnhide`, before the windows return. With the app hidden, an
animated page then takes 2% of a CPU core instead of 23%.

An offscreen view that could not be seen when it asked for its browser
told nobody, since the browser did not exist yet, and Chromium creates
offscreen browsers visible; a new browser starts hidden when its host
last reported so.

The lifecycle is derived the way Chromium decides visibility: hidden
unless the window is visible, unminimized and not covered (occlusion
state), the host view is in it and not hidden, and Chromium's view is in
a window; active when, in addition, the app is active, the window is key
and the first responder is the browser's view or inside it.

Chromium handles the rest itself. It listens for memory pressure and
system sleep in every process, and sets `NSAppSleepDisabled`, which keeps
App Nap off for the app: with the app hidden, a 50 ms main-thread timer
fires within 12 ms of its time over 25 s, with or without a page playing
audio. CefKit holds no activity assertion. `Page.setWebLifecycleState`
with `frozen` fires the page's `freeze` event and stops timers set before
it, but a timer added later kept running, and a hidden page with busy
timers took more CPU frozen than not; CefKit offers no freezing.

**Energy.** While Low Power Mode is on or the thermal state is serious or
critical, `CefRuntime.energySaver` caps offscreen browsers' frame rate
(`set_windowless_frame_rate`) at 30. An animated offscreen page takes
about 30% of a core at 30 frames a second and 50% at 60. A rate below the
one a browser was created with does not hold by itself: every few
seconds Chromium paints at the creation rate again while
`get_windowless_frame_rate` still reports the lower one, so the
coordinator sets the reduced rate again twice a second while it applies. Windowed and
Chrome-style browsers draw at the display's rate, which CEF cannot change.

## Quitting

`CefApplication.terminate(_:)` asks `CefRuntime` first. The runtime closes
every browser, so pages can run `beforeunload`, and declines the request. As
the last browser and the last Chromium window are destroyed, it calls
`terminate(_:)` again from the run loop, then calls `cef_shutdown()`. Calling
`cef_shutdown()` earlier, or from inside a CEF callback, crashes. A page that
asks to stay cancels the quit. A browser discarded by closing has no
Chromium browser left and is marked closed at once.

Logging out, restarting and shutting down send the app a quit Apple Event,
which AppKit handles with `terminate(_:)`. While the browsers close, the
runtime suspends that event (`NSAppleEventManager.suspendCurrentAppleEvent`),
as `NSApplication.TerminateReply.terminateLater` does, and resumes it when
they are gone, or with `userCanceledErr` when a page asks to stay, which
stops the logout as an app that cancels it does.

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
run from the helper apps inside the bundle, all the same executable,
CefSwift's `cefswift-helper` product, which `cef bundle` builds with the
app. It finds the framework dyld loaded with it, checks the API hash,
registers the custom URL schemes it receives on its command line
(`--cefswift-schemes`), so every process registers the same list, and
calls `cef_execute_process`; in renderers, with the render process handler
described in [Page-facing features](#page-facing-features). With the
sandbox on, each helper seals itself before any framework code runs
([sandbox](sandbox.md)).

### Loading the framework at launch

The helper links two libraries, in this order:

1. `Contents/Frameworks/libcefswift_helper_startup.dylib`, CefSwift's
   `cefswift_helper_startup` product (`Sources/CefHelperStartup`, a few
   lines of C). Its initializer opens CEF's `libcef_sandbox.dylib` and
   calls `cef_sandbox_initialize` unless the helper was started with
   `--no-sandbox`. dyld runs a library's initializers before those of the
   libraries listed after it, so the sandbox is sealed before the
   framework's static initializers run. This part stays C: it must run
   before the framework's initializers, which run before any of the
   executable's own code, and must not load the Swift runtime.
2. The CEF framework.

The plugin links the helper with `-needed_library` and `-needed_framework`
for these two, in that order, and `-dead_strip_dylibs`, which drops
libraries the helper does not use, such as Foundation, which SwiftPM's
build system links into executables by default. The helper uses the Swift
standard library and the C API, not Foundation.

A library that dyld loads at launch is fixed up by the kernel as its pages
are read in (page-in linking), so the framework's `__DATA_CONST` segment,
about 12 MB of pointers, stays clean memory that every process shares. A
library loaded with `dlopen` has the same segment fixed up in the process,
which makes all of it private, dirty memory. The app executable gets the
same benefit from its weak link. Across the six processes of the Minimal
example this takes the idle footprint from 185 MB to 101 MB
([guide](guide.md#footprint-and-launch-time)).

Chrome 157 does the same with its "Aperitif" helpers: separate helper apps
(`Google Chrome Helper (Aperitif).app` and so on) that link
`libaperitif.dylib`, which registers PartitionAlloc's malloc zone and seals
the sandbox in an initializer, and then the framework
(`content/public/app/aperitif_mac.h`). Chromium chooses those helper names
when its `AperitifHelpers` feature is on. CEF 156 does not ship
`libaperitif.dylib` or Aperitif helpers and leaves the feature off; turning
it on with `--enable-features=AperitifHelpers` makes Chromium launch helper
apps that the bundle does not contain. CefSwift's helper keeps CEF's
classic helper names and gets the memory saving without the feature.


## Swift and C++

CEF's binary distribution exports its C API from the framework: about 240
`cef_*` functions, which return the structs of function pointers the rest
of the API is made of (`nm -gU` on the framework lists 2,548 symbols; the
others are V8's debugger helpers (`_As_*`), Chrome's app-mode entry points
and allocator shims). CEF's C++ API (`CefRefPtr`, `CefV8Value` and the
rest) is a set of headers and the `libcef_dll_wrapper` static library,
which wraps that same C API. Chromium's own C++ (`content/`, `chrome/`,
Blink, V8's API) is neither exported nor shipped as headers. So Swift's
C++ interoperability would reach nothing that importing the C API does not,
and would add the wrapper's build; CefSwift imports the C API directly.

What reaches further into Chromium is, in the renderer, the V8 and DOM
APIs (`cef_v8*`, `cef_domdocument_t`, `cef_frame_t`) through the helper's
render process handler; in the browser process, Chromium's Objective-C
classes ([Chromium's AppKit classes](#chromiums-appkit-classes)), the Mojo
interfaces of its WebUI pages ([Internal-page services](#internal-page-services)),
the DevTools Protocol, and preferences and command-line switches.

The renderer side makes these possible without the DevTools Protocol, each
as a `CefRendererExtension`: native bridges in every frame, cross-site ones
included; JavaScript functions that call Swift synchronously; reading a
document through `cef_domdocument_t` visitors without running script; a
context's V8 heap statistics; and per-frame features that start before a
document's first script.
