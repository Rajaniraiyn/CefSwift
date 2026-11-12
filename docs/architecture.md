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

CefPlugin    swift package cef download | bundle | info | clean; compiles the
             helper-process executable (C, Plugins/CefPlugin/Helper)
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

`CefHistory.mostVisited()` binds a new most-visited page handler for each
call. Chromium's `TopSites` reads the list from history once, shortly after
it loads, and then hourly, and a handler's `updateMostVisitedInfo` returns
that cached list; creating a handler is what makes `TopSites` read history
again. The handler reports the cached tiles first and the fresh ones when
they differ, so the call waits a moment for a second report.

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
`discards.mojom.DetailsProvider` of a hidden service browser parked on
`chrome://discards`, after its own checks. It reads Chromium's other
protections (audio, media capture, form interaction, connected devices)
from `GetTabDiscardsInfo` as blockers, leaving out the ones it overrides.
That interface numbers tabs afresh on every query and describes them only
by address and title, so each discard looks its tab up again. CEF's frame
count for a browser drops to zero when Chromium discards its tab; when two
hidden tabs share an address and title, that tells which one went, and a
discard that reached the other tab reloads it and tries the next. The
service browser closes after 30 seconds without calls.

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
`DispatchSource.makeMemoryPressureSource`. Window occlusion notifications
restore browsers discarded by closing when their view comes back on
screen.

## Quitting

`CefApplication.terminate(_:)` asks `CefRuntime` first. The runtime closes
every browser, so pages can run `beforeunload`, and declines the request. As
the last browser and the last Chromium window are destroyed, it calls
`terminate(_:)` again from the run loop, then calls `cef_shutdown()`. Calling
`cef_shutdown()` earlier, or from inside a CEF callback, crashes. A page that
asks to stay cancels the quit. A browser discarded by closing has no
Chromium browser left and is marked closed at once.

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
run from the helper apps inside the bundle, all the same executable, which
`cef bundle` compiles from `Plugins/CefPlugin/Helper/helper_main.c`. It
checks the API hash, registers the custom URL schemes it receives on its
command line (`--cefswift-schemes`), so every process registers the same
list, and calls `cef_execute_process`. With the sandbox on, each helper
seals itself before any framework code runs ([sandbox](sandbox.md)).

### Loading the framework at launch

The helper is a small C program that links two libraries, in this order:

1. `Contents/Frameworks/libcefswift_helper_startup.dylib`
   (`helper_startup.c`). Its initializer calls `cef_sandbox_initialize`
   from CEF's `libcef_sandbox.dylib` unless the helper was started with
   `--no-sandbox`. dyld runs a library's initializers before those of the
   libraries listed after it, so the sandbox is sealed before the
   framework's static initializers run.
2. The CEF framework.

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

