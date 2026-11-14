# Architecture

How CefSwift works inside, and why. For how to use it, see the
[guide](guide.md).

CefSwift is a library for embedding CEF in a macOS app. The core, `CefKit`,
wraps CEF's C API and the Chromium behavior an embedder has to work with or
around: the runtime and its processes, browsers and their handlers,
profiles, AppKit host views, CEF Views windows, offscreen rendering and its
accessibility, discarding. `CefSwiftUI` adds SwiftUI. `CefPasskeys` and
`CefChromium` are optional modules that reach Chromium internals some apps
want. Browser-product decisions (UI, defaults, heuristics) live in the
examples.

| Where | What | Examples |
|---|---|---|
| `CefKit` (core) | What any app embedding CEF needs and could not write itself: the runtime, browsers, profiles, the AppKit host views, CEF Views windows (`CefWindow`), handlers and delegates, offscreen rendering and its accessibility, discarding | `CefRuntime`, `CefBrowser`, `CefProfile`, `CefOffscreenBrowserView`, `CefWindow` |
| `CefSwiftUI` | SwiftUI on top of `CefKit`, nothing else | `CefSwiftApp`, `CefWebView`, `setToolbar`, `setPageOverlay` |
| `CefPasskeys`, `CefChromium` (optional) | Capabilities on Chromium internals some apps want: passkeys the app answers; Chromium's bookmark, history and suggestion stores and its bubbles | `CefPasskeyController`, `CefBookmarks`, `CefChromiumSurface` |
| `Examples` | Product decisions written against the public API: UI, defaults, heuristics for when to use a capability | the Browser's toolbar, swipe indicator, Memory Saver, permission names |

The rule: the library holds what an app cannot write against its public
API, because it calls the CEF C API, hooks Chromium or works around a CEF
or Chromium limit, plus the defaults an embedder cannot ship without: the
built-in sheets and presenters that answer a delegate method nobody
implemented, each replaceable. Everything else belongs to the app.

## Modules

```
CefSwiftUI   CefSwiftApp, CefWebView (over CefKit's host views), SwiftUI modifiers,
    │        CefWindow.setToolbar, setTabAccessory and setPageOverlay
    │  CefPasskeys  optional: CefPasskeyController (a CefBrowserAttachment), passkey
    │     │         stores and the passkey sheet
    │     │  CefChromium  optional, bound to the pinned CEF: CefBookmarks, CefHistory,
    │     │     │         CefAutocomplete (on CefKit's service hosts); CefChromiumSurface,
    │     │     │         chromiumSurfacePolicy and their SwiftUI glue (on Chromium's AppKit classes)
CefKit       CefRuntime, CefBrowser, CefWindow, CefBrowserDelegate, CefBridge,
    │        CefDevTools, CefProfile, CefBrowserAttachment, configuration and policy types; the AppKit
    │        host views CefWindowedBrowserView and CefOffscreenBrowserView
    │        (with its compositor and accessibility elements), the internal
    │        service hosts and tab discarding, no SwiftUI
CCef         vendored CEF C headers, the generated bridge, the runtime loader (C)

CefBase      reference counting, strings and process messages, shared by
             CefKit and the helper (no Foundation, no AppKit)
CefRenderer  renderer-side features on the V8 API, run by the helper
CefHelper    the helper-process executable (cefswift-helper)

CefPlugin    swift package cef download | bundle | info | clean; builds the
             helper products and assembles the app
```

### Extension points

CefKit names no optional feature. An optional module, such as
CefPasskeys or CefChromium, plugs into it at these points:

- `CefBrowserAttachment` (public), through `CefProfile.attachments` (every
  page of a profile, Chromium's own included) and
  `CefBrowser.Configuration.attachments`: told when Chromium has created a
  browser (`browserDidCreate(_:)`), when a discarded one is created anew
  (`browserDidRestore(_:)`) and when it closes (`browserDidClose(_:)`). An
  attachment whose `preparesBeforeFirstDocument` is `true` holds the first
  page: the browser starts on `about:blank`, `CefBrowser.bootstrap()`
  awaits every attachment with the task-local `settingUp` set (so their
  DevTools calls do not wait for `ready()`), and only then loads the page.
  Without such an attachment nothing is held: `adopt(_:)` completes
  `ready()` and then tells the attachments, in a task, so that one
  attachment cannot delay every browser.
  Such a browser's native popups are opened in a browser CefKit creates
  (`openPopupInNewBrowser`), since Chromium runs a native popup's first
  document before anything can attach to it.
- `CefProfile.moduleState(_:make:)` (package): one object per type that a
  module keeps for a profile, made on first use.
- `CefWindow.moduleState(_:make:)` and `existingModuleState(_:)`
  (package): the same for a `CefWindow`. A state object that is a
  `CefWindowParticipant` is told when the window is destroyed
  (`windowDidClose(_:)`).
- `CefWindow.addChromeCommandInterceptor(_:)` (package): decides
  Chrome commands in every `CefWindow`, from Chrome's UI and from
  `CefBrowser.execute(_:disposition:)`, after the browser's delegate and
  before Chromium runs them.
- `CefWindow.Configuration.moduleValues` (package): values a module
  keeps in a window configuration, by type, dropped for the window's
  popups; `showsChromiumStatusBubble` and `showsChromiumZoomBubble`
  (package) set the browser's `chrome_status_bubble` and
  `chrome_zoom_bubble`. CefChromium's status bubble uses the public
  `pageOverlay`.
- The internal service hosts (package): `CefServiceHosts`
  (`CefProfile.serviceHosts`), `CefServiceHost` and `CefServiceHost.Module`. A module
  declares its own hosts and modules and calls them
  ([Internal-page services](#internal-page-services)).

Inside CefKit, an object holding CEF references outside any browser is a
`CefShutdownParticipant`: it adds itself with
`CefRuntime.addShutdownParticipant(_:)`, held weakly, and is told to
release them after the last browser and window and before the profiles'
request contexts and `cef_shutdown()`. The service hosts (a module's
included) and the media router are participants.

A module also uses a few `package` members of CefKit that are not public
API: `CefDevTools.addListener(for:_:)`, `removeListener(_:for:)` and
`leaseCount(_:)` (synchronous, ordered event listeners and domain leases),
`CefBrowser.decision(_:_:)` with `CefBrowser.DecisionScope` (a question
cancelled when its page or browser goes), `CefDialogPresenter.run(_:in:)`
(an alert that dismisses itself on cancellation), `CefLog`,
`CefWindow.owning(_:)`, `CefProfile.storageDirectory` (now public), and `CefObjCHook`
for overrides of Chromium's AppKit classes.

**CefChromium** wraps Chromium's own browser features, which are bound to
Chromium-private interfaces of the pinned CEF: its stores
(`profile.bookmarks`, `history` and `autocomplete`, kept weakly in the
profile's module state) and the surfaces of Chrome-style windows
(`window.chromiumSurfacePolicy`, kept in the window's module state). It depends on
CefKit and on CCef and CefBase for Chromium's command and string
identifiers. Its surface handling starts on the first use of its window
API: that installs the AppKit overrides and the command interceptor once,
for every window, and a window's state, made on first use or when
Chromium first attaches a child window to it, takes up the surfaces
already attached. Until then Chromium's interface shows natively, as
without the module.

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
- `ccef_net_error.c` names Chromium's network errors from the vendored
  `cef_net_error_list.h` (`ccef_net_error_name(-105)` is
  `"NAME_NOT_RESOLVED"`), without the framework.

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
- An in-out object parameter, such as `cef_client_t** client` in
  `on_before_popup`, also arrives with a reference for the callback. CEF
  takes a reference back only for an object the callback puts in its
  place, so the callback releases the one it received either way. Missing
  this kept the opener's client alive after every popup Chromium opened.
- A callback that keeps such a reference across early returns holds it in
  a `CefOwned`, a non-copyable struct that releases it at the end of the
  scope unless a consuming method passed it to CEF, adopted it into a
  `CefRef` or released it. It costs no allocation.
- `CefCensus` counts live `CefRef`s by CEF type, implemented structs by
  owner type, received payloads and their shared memory mappings, and
  pending operations. It is off unless enabled (`CefDiagnostics`, SPI);
  SelfTest enables it and prints it after each group of checks.

## Threads

Chromium's UI thread is the app's main thread. CEF runs with an external
message pump driven from the main run loop (`CefMessagePump`), so SwiftUI and
Chromium share one thread, and the public API is `@MainActor`.

CEF calls a few handlers on other threads. Where each arrives in CEF 156,
from the C API's comments and checked with `cef_currently_on` and thread
names at run time:

| Callback | Thread | CefKit |
|---|---|---|
| `cef_request_handler_t.get_resource_request_handler`, `cef_request_context_handler_t.get_resource_request_handler`, `cef_resource_request_handler_t.on_before_resource_load`, `cef_cookie_access_filter_t` | IO (`Chrome_IOThread`) | The filter's declarative match runs in C in `get_resource_request_handler`; the filter itself runs in `on_before_resource_load`, isolated to `CefIOActor`. |
| `cef_scheme_handler_factory_t.create` | IO | Creates the resource handler. |
| `cef_resource_handler_t.get_response_headers`, `cancel` | IO | Read and change the handler's locked state. |
| `cef_resource_handler_t.open`, `skip`, `read` | Chromium's thread pool (`ThreadPoolForegroundWorker`), in sequence | `open` starts the `CefSchemeHandler` in a task; `read` reads a file, copies buffered bytes or waits for them. |
| `cef_request_handler_t.get_auth_credentials` | IO | Hops to the main actor for the delegate. CEF calls it only with `--disable-chrome-login-prompt` (`CefRuntime.AuthenticationPromptPolicy.delegate`, the default); without the switch Chromium shows its own dialog. |
| `cef_urlrequest_create`; `cef_urlrequest_client_t.on_request_complete`, `on_upload_progress`, `on_download_progress`, `on_download_data`; `cef_urlrequest_t.cancel` | The thread that created the request; CefKit creates it on IO (`Chrome_IOThread`, checked by thread name) | `cef_urlrequest_create` needs a thread with a Chromium task runner and calls back on that thread, which alone may call `cancel`. `URLRequestLoader` is isolated to `CefIOActor` and creates requests there; callbacks enter it with `CefIOActor.assumeIsolated`. Progress closures run there. |
| `cef_urlrequest_client_t.get_auth_credentials` | IO, whatever thread created the request | Hops to the concurrent executor for `RequestConfiguration.credential`. |
| `cef_cookie_visitor_t.visit`, `cef_download_handler_t` | UI | No hop needed. |
| `cef_browser_process_handler_t.on_before_child_process_launch` | UI for a renderer, IO for the GPU process (per its header) | Reads only the app context's immutable scheme list and appends to the command line; touches no actor-isolated state. |
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
running goes to the queue the same way. Each job is routed, and each
phase change made, under one lock, so a job always goes where the phase
at its submission sends it; the path that takes back a job Chromium
rejects inside `cef_post_task` never takes that lock. So no job is lost
or runs at the same time as another, and quitting waits for nothing.

**Scheme handlers.** A `CefSchemeHandler` runs with its own isolation:
nonisolated on Swift's concurrent executor, or on `CefIOActor` or the
main actor if its type is isolated to one. Its body is data, a file or an
async sequence of `Data`. `read` reads a file with `pread(2)` straight
into the buffer CEF passes it, on the thread pool where CEF calls it and
where Chromium reads its own files. A sequence is iterated in a task, at
most 1 MB ahead of the page: a write waits until `read` drains the
buffer. `read` copies what is buffered, once, or, with nothing buffered,
keeps CEF's buffer and callback until the next chunk arrives. A data
body is copied from the `Data` into CEF's buffer, once per read. Chromium skips to the
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
view, so CEF cannot move it into a `CefWindow`; it goes to
`CefRuntime.onChromeTab` when that is set, with its window kept off
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

### Profile policy

A profile holds the defaults for every page in it, and CEF scopes what it
can per request context, so CefKit scopes it there too:

- **Requests.** Every request context a profile has, its own and the
  shared one of the default profile, carries a `cef_request_context_handler_t`
  (`CefProfileContextHandler`) whose `get_resource_request_handler`
  applies the profile's `requestFilter`. CEF asks it only when the page's
  client returns no handler for the request, which a page's client does
  unless the page has a filter of its own (`CefRequestFiltering.page`) or
  is one of CefKit's service pages (`.unfiltered`, a handler that only
  checks external protocols). Requests without a page, a service
  worker's or a shared worker's, reach only a context handler: CEF picks
  one of the handlers of the contexts that share the storage, which for a
  profile are all the same. A context Chromium creates itself, for a
  window it opens from its own UI, gets one from
  `get_default_request_context_handler`, which finds its profile from
  `on_request_context_initialized`. CEF does not hand the app's own
  `cef_urlrequest_t`s to these handlers.
- **Matching.** A `CefRequestFilter`'s hosts, patterns and resource types
  are compiled into a C matcher (`ccef_request_match`). Each request is
  tested on its `cef_resource_type_t` first, then on its UTF-16 address
  as CEF hands it over, in `get_resource_request_handler`; a request the
  filter does not want gets no handler, so it never reaches Swift values
  or the filter. A request it wants gets a handler of its own whose
  `on_before_resource_load` builds the `CefResourceRequest` (the
  initiator comes from `get_resource_request_handler`), runs the filter,
  and whose `get_cookie_access_filter` applies `.restrictCookies(to:)`.
- **Scheme handlers.** `register_scheme_handler_factory` registers on the
  browser context, so every context of a profile shares a registration.
  A runtime registration goes to the global context
  (`cef_register_scheme_handler_factory`) and to every other profile's
  context as it is made; a profile's own goes to its context and wins
  there. Removing one registers a `NULL` factory, or the runtime's again.
- **Pages.** A page's effective user scripts, bridges and attachments are
  its profile's followed by its configuration's (a page bridge replaces a
  profile bridge of the same name). Permission and download decisions go
  to the page's delegate, whose default implementation asks the profile's
  `CefProfileDelegate`. A popup takes its opener's configuration; a tab
  Chromium opens inside a CefKit window takes that window's first
  browser's, since CEF gives it that browser's client, settings and
  `extra_info`; one in a window Chromium opens itself has the default
  client and no `extra_info`, so only its profile's policy applies.
- **Settings.** `CefProfile.Configuration` maps onto the profile's
  preferences; a profile applies `CefRuntime.Configuration.profiles`, or
  its own, as it loads and again when it changes, resetting what an
  earlier value set. The proxy is the context's `proxy` preference.

The request filter's cost was measured with `-benchmark filters`: see
[design notes](design-notes.md#request-filter-matching).

### Profiles and their request contexts

`CefProfile.default` is Chromium's `Default` profile under
`root_cache_path`, loaded as Chromium starts. Its pages use a context that
shares the global context's storage (`cef_create_context_shared`), because
the global context has no handler and the profile's needs one (see
[Profile policy](#profile-policy)). Every other profile creates its own
context on first use with
`cef_request_context_create_context`: an empty `cache_path` for an
incognito profile, `<root>/Profile-<id>` for a persistent one, the root
taken with its symbolic links resolved (`realpath`), because Chromium's
profile manager makes a profile only in a direct child of its user data
directory, compared that way. Anything else gets an in-memory profile,
which CEF reports as an initialized context like any other.

A context created that way reports `on_request_context_initialized`
once Chromium has loaded the profile, asynchronously for a disk profile
(an incognito context is usable as soon as `create_context` returns, so
CefKit counts it ready then). `CefProfile.readiness` follows it, `.pending`, `.loading`, then
`.ready` or `.failed(reason)`: the callback checks that the context's
`get_cache_path` is the directory asked for and that the directory now
exists, which is how Chromium's silent fall-back to memory is caught. A
failed profile drops its context, and every call on it fails or does
nothing.

Browser creation goes through `CefBrowser.profileAllowsCreation(for:_:)`
first, in every path: windowed, offscreen, Chrome's own window and
`CefWindow`'s browser view. `cef_browser_host_create_browser_sync` and
`cef_browser_view_create` fail on a context that is not initialized
yet, and the asynchronous `cef_browser_host_create_browser` would go
ahead on the in-memory fallback, so a browser on a profile still loading
stays `.pending` and the creation runs again once the profile reports;
the last host asked for wins. The deferred creation is a token,
`creationAwaitingProfile`, checked when the profile reports: a host view
given another browser or none (`hostDidRelease(_:)`) or leaving its
window, a close, or a quit clears it, and nothing is created. Such
browsers are in no browser list, so `CefRuntime` tracks them
(`browsersAwaitingProfiles`) and quitting closes them first, which ends
their `ready()` with `CefError.browserClosed`. A `CefWindow` creates its window at once
and adds the browser view when the profile is ready. Popups need nothing:
they share their opener's context, which is loaded. The default profile
and loaded profiles take the direct path, with no wait. A browser on a
failed profile closes as it would on a failed creation, and its
`ready()` throws `CefError.profileUnavailable`.

## Hosting

| Host | Style | How it draws |
|---|---|---|
| `CefWebView`, `.windowed` | Alloy | Chromium's native `NSView` as a subview of `CefWindowedBrowserView` |
| `CefWebView`, `.offscreen` | Alloy | Frames in a shared `IOSurface`, copied into a surface of its own and set as layer contents by `CefOffscreenBrowserView`, which forwards input |
| `CefWindow` | Chrome | A CEF Views window; your toolbar is an `NSToolbar` and your accessory a title-bar accessory view |
| `CefRuntime.openChromeWindow` | Chrome | Chrome's own window and UI |
| `CefChromeWindow` (CefChromium) | Chrome | Chrome's own window, with the app's views laid over Chrome's tab strip and toolbar |

macOS provides Chrome style only in windows Chromium creates, which is why
the Chrome-style hosts own their `NSWindow`. A `CefWindow` draws the
whole content area in one layer, so `contentInsets` and
`contentCornerRadius` are drawn by a native view laid over the page that
paints everything except the page's rectangle and passes events through.

### Windows, tabs and views

Three things are kept apart, each usable alone:

- **Content**: `CefBrowser`, one page's model, whatever shows it.
- **View**: where content shows. `CefWebView` (`CefWindowedBrowserView`,
  `CefOffscreenBrowserView`) puts a page anywhere in the app's own view
  tree, Alloy style: such pages are not Chromium tabs. A Chrome-style
  window's content area shows its active tab's page.
- **Window and tab**: Chromium's model of tabs. A `CefWindow` is a CEF Views
  window (`cef_window_t`) holding one `cef_browser_view_t`; Chromium makes
  it a `Browser` of type `popup` with one tab, and CEF refuses a second
  Chrome-style browser view in it. Tabbed windows are the windows Chromium
  draws itself (`cef_browser_host_create_browser` with Chrome style and no
  CEF Views): CefChromium's `CefChromeWindow`, with its `CefTab`s and
  `CefTabGroup`s, all listed by the profile's `CefTabStrip`.

`CefWindow` and `CefChromeWindow` stay two types because they are two
different things in CEF: the first is a CEF Views object CefKit creates and
lays out (toolbar, insets, popups through `onPopup`, Chromium's surfaces
recognised per window); the second has no CEF object at all, only the
`NSWindow` Chromium made and the tab model Chromium keeps, reached through
Chromium's WebUI hosts (`chrome://bookmarks`' `chrome.tabs`,
`tab_strip_internals.mojom`, `tab_search.mojom`). `CefTabStrip` follows
the events CEF and AppKit deliver for every browser and window, and asks a
host only when they report a change to the tab model's structure; hosts
close seconds after their last call. Chromium's surfaces are one
controller for both window kinds (`ChromiumSurfaceHost`: the window's
`NSWindow` and the browser it shows, a `CefChromeWindow`'s active tab's).
A one-tab `CefChromeWindow` is a different
Chromium window from a `CefWindow`: a `normal` one, with a toolbar for
extensions' action popups and a tab strip extensions can group and move
tabs in.

`CefChromeWindow` covers Chrome's tab strip and toolbar with a view in the
window's frame view, above Chromium's `BridgedContentView` (which answers
every hit test inside itself) and below the title bar's window buttons. No
preference, command-line switch or CEF callback takes them out of a normal
window. Under the cover, Chrome's controls are kept out of the way through
AppKit: `AXPlatformNodeCocoa`'s `accessibilityChildren` leaves out elements
lying wholly under the cover (only in covered windows; the method is
replaced only if the class defines it), and keyboard focus Chromium moves
to them (Tab past the page, ⌘L, F6) moves on to the app's views. The page
is the visible `WebContentsViewCocoa`, whose frame the window follows.

## Chromium's AppKit classes

The framework exports only CEF's C API, but Chromium's macOS UI is AppKit,
and its Objective-C classes are visible to the Objective-C runtime.
`CefObjCHook` overrides a few of their methods, a feature at a time:
CefChromium's surface tracking (`CefNSWindow` and
`BrowserNativeWidgetWindow` child windows, `NativeWidgetMacNSWindow`
alpha), swipe gating (`ChromeRenderWidgetHostViewMacDelegate`) and the
swipe indicator (`HistoryOverlayController`). Every method a feature
overrides or calls is looked up first by class name, selector and type
encoding, and the feature's overrides go in only when all of them are
there; one missing method leaves the whole feature out, logged and listed
per feature by SelfTest's "runtime hooks" check, and the feature falls
back to Chromium's own behavior instead of running partly hooked. An
override added to a class that inherits the method stays on that class
alone.

**Surfaces.** Chromium's bubbles, dialogs, find bar and status bubble are
Views widgets, each in a `NativeWidgetMacNSWindow` that Chromium attaches to
the `CefWindow` as a child window. Every CEF Views window is a
`CefNSWindow`, a subclass; `CefSurfaceTracker` overrides its
`-addChildWindow:ordered:` and `-removeChildWindow:`. As Chromium attaches a
widget, the window's surface controller makes it transparent; once attached, it reads
what the widget shows and applies the kind's presentation: it restores the
widget and moves it under its anchor with `setFrameOrigin(_:)` (and again
when the widget or the window moves or resizes), or keeps it transparent,
ignoring the mouse, and closes it as Esc would, or for the find bar with
`IDC_CLOSE_FIND_OR_STOP`. Status bubbles and fullscreen notices are only
kept transparent, since Chromium reuses their windows. Chromium fades some
widgets in by setting their window's alpha, the status bubble on every
hover, so an override of `-setAlphaValue:` in `NativeWidgetMacNSWindow`
keeps a hidden surface's window at 0, and keeps the alpha Chromium asked
for, which a reused window gets back when it is shown again.

Two state machines, in `ChromiumSurfaceController`, replace what was
implicit ordering. Each of Chromium's windows is in a `WidgetPhase`:
`attaching` (transparent, between `-addChildWindow:` and its return),
`recognizing` (attached without a view tree yet: transparent, looked at
again every 50 ms, six times, then shown as `.other("")`), `shown` (a
native surface, placed and followed) or `suppressed` (hidden or replaced,
closed natively); it leaves the table when Chromium detaches or closes it,
and a suppressed window Chromium attaches again is decided afresh. Each
`CefChromiumSurface` is `presented` until `end(_:_:)` makes it
`dismissed(reason)`, the one transition out, which also stops its
observers and, for a custom find bar, the find session. A policy change
moves each presented surface to its kind's new presentation through the
same two paths. Custom surfaces end with what they show: the find bar
with `CefFindSession.isActive`, the status bubble with `statusText`,
the others with a main-frame navigation to another document (observed on
`CefBrowser.url`), as Chromium's bubbles close. Closing the window ends
every surface (`.window`) and drops the app's presenters and callbacks.
A zoom command the window replaces is passed on to Chromium, which runs
the interceptor again through `on_chrome_command` in the same turn; that
second call is recognized and let through. Print preview takes Esc only
in its page, so it is closed by focusing its `RenderWidgetHostViewCocoa`
and pressing Esc until it goes: `-[NSWindow close]` on it, as on bubbles,
ends the browser process.

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
`on_chrome_command` hand them to CefChromium's command interceptor first. The custom
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
`CEF_CTT_LOCATION` do not change where they appear in a `CefWindow`,
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
Chrome's overlay unless `showsChromiumNavigationGestureIndicator` is on. Alloy-style browsers have no
such delegate; views track swipes themselves with
`NSEvent.trackSwipeEvent`, the offscreen view from its own scroll events
and the windowed view from a local event monitor, since Chromium's view
receives the events. CefKit draws no indicator of its own; apps draw one
from `navigationGestureProgress`, over a `CefWindow`'s page in its
`pageOverlay`, which is a view laid over the content view, clipped to the
page and passing every event through.

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

## Frame ownership

CEF's header says an accelerated frame's `IOSurface` may only be used
during `on_accelerated_paint` and must be copied into a texture the client
owns. The Chromium 156.0.8078.88 source, with CEF 156.0.28 (`57389f0`),
shows that nothing the browser process can do keeps Chromium from
rendering into a delivered surface:

- CEF's video consumer (`libcef/browser/osr/video_consumer_osr.cc`,
  `OnFrameCaptured`) holds the capturer's callbacks in a
  `ScopedVideoFrameDone`, whose destructor calls `Done()`, and calls
  `OnAcceleratedPaint` synchronously in between. `Done()` goes out as the
  callback returns; the C API exposes no way to delay it.
- viz's `FrameSinkVideoCapturerImpl` returns the frame to its pool on
  `Done()` (`NotifyFrameReleased`) and keeps only the latest frame
  (`marked_frame_`) for resurrection. The pool for ARGB frames on macOS is
  `MappableSharedImageVideoFramePool`, over
  `media::RenderableMappableSharedImageVideoFramePool`: its
  `OnVideoFrameDestroyed` keeps at most two idle buffers
  (`kMaxAvailableFrames = 2`) and `MaybeCreateVideoFrame` hands out the
  oldest first (`front()`, `pop_front()`), checking only size and colour
  space.
- No code on that path reads `IOSurfaceIsInUse` or a use count. The one
  reader, the shared-image overlay check
  (`IOSurfaceImageBacking::OverlayRepresentation::IsInUseByWindowServer`
  in `iosurface_image_backing.mm`), returns false for images with
  `SHARED_IMAGE_USAGE_MACOS_VIDEO_TOOLBOX`, which the capture pool sets
  on every image. Holding the `IOSurfaceRef`, `IOSurfaceIncrementUseCount`
  or showing it as a layer's contents keeps the kernel object alive but
  not out of the pool.
- The browser's `IOSurfaceRef` is the GPU process's surface
  (`IOSurfaceLookupFromMachPort` on the receiving side of the mojo
  handle), and `DidCopyFrame` blits each capture straight into the pooled
  image. A delivered surface is rendered into again by the capture two or
  three frames later, or the next one when the frame was not marked:
  8 to 25 ms at 120 frames a second. `Stop()`, which runs whenever the
  browser is hidden, and `Start()` replace the pool.

So the surface is copied, and the copy is limited to what changed.
`CefOffscreenBrowserView` copies each frame on the GPU with a Metal blit
into an `IOSurface` of its own (`CefOffscreenCompositor`) and waits for
the copy before the callback returns. That surface becomes the layer's
contents. A surface is written again only when it is not the layer's
contents and `IOSurfaceIsInUse` is false: the window server holds a
replaced surface until it has composited the next refresh, about 11 ms on
a 60 Hz display, as long as the contents change has no implicit
animation.

Each frame comes with its damage, viz's `capture_update_rect`
accumulated since the previous capture, which CEF passes as the one
dirty rectangle, and `capture_counter`, its number. Each owned surface
keeps the part of it that is out of date: the union of the damage of
every frame since the surface was written. The blit copies only that.
A gap in the frame numbers, a new size or a first frame copies the whole
surface. The pool holds up to four surfaces of the frame's size, and
three when a surface is larger than 32 MB (a 5120×3200 frame is 64 MB).
A frame that finds none free is dropped, and the view asks Chromium for a
new one a refresh later. When the view stops being seen, only the surface
on screen stays. A pixel format Metal cannot wrap is copied on the CPU
under the surfaces' locks.

`SelfTest`'s `compositor` checks read the frame number a page paints into
its background from each surface as it becomes the layer's contents, and
again every 2 ms while it stays there. Presenting Chromium's surfaces
directly, one surface changed while it was the layer's contents in a
2-second resize run (1 of 237 frames); with the copies, none did in any
run. A second page changes one block of a 4×4 grid per frame, block
`f % 16` showing `f % 64`, so a presented surface is whole only if its
blocks hold 16 consecutive frame numbers; the checks read every block of
each surface the same way, at 1× and 2× and while resizing, and found no
surface that was not whole with damage-limited copies. The table below
measures whole-frame copies; [design notes](design-notes.md#offscreen-frames-copied-and-only-where-they-changed)
compare them with damage-limited ones. `-benchmark compositor` measures
the cost on an M3 MacBook Air
(60 Hz display, offscreen frame rate 120, 3 s of animation, at least two
runs each). Surfaces of 1280×800 pixels are a 1280×800 view at 1× (a
640×400 view on this 2× display); 2560×1600 pixels are a 1280×800 view at
2× or a 2560×1600 view at 1×; 5120×3200 pixels are a 2560×1600 view at
2×:

| Surface | Presenting | Frames presented a second | App CPU | Mouse move to presented frame, median / 90th percentile | App memory while animating |
|---|---|---|---|---|---|
| 1280×800 | Chromium's surface | 119.4–119.7 | 8–19% | 15–18 / 22–24 ms | +1–6 MB |
| 1280×800 | Copy | 57–120 | 12–25% | 17–26 / 26–31 ms | +13–64 MB |
| 2560×1600 | Chromium's surface | 119.4–119.9 | 7–20% | 12–15 / 24–36 ms | +0–1 MB |
| 2560×1600 | Copy | 58–102 | 13–16% | 20–28 / 31–41 ms | +49–89 MB |
| 5120×3200 | Chromium's surface | 119.7–120.0 | 6–17% | 15–20 / 20–26 ms | +0 MB |
| 5120×3200 | Copy | 31–93 | 12–18% | 15–29 / 24–41 ms | +220–297 MB |

The display shows at most 60 of those frames a second. A 5120×3200 copy
takes 1.5–2.4 ms of GPU time and holds the main thread for 2.6–4.2 ms;
smaller copies hold it for 1.6–3.4 ms, mostly waiting for completion.
That wait slows CEF's message loop, so Chromium delivers fewer frames.
Chromium's surfaces count toward the GPU process, the copies toward the
app.

## Offscreen accessibility

Windowed browsers expose Chromium's own `NSAccessibility` objects. For
offscreen browsers Chromium only computes the tree ("tree only" mode) and
hands it to CEF's accessibility handler, which the render handler returns
from `get_accessibility_handler`:

- `set_accessibility_state(STATE_ENABLED)` starts the tree. With
  `CefBrowser.AccessibilityPolicy.automatic`, `CefOffscreenBrowserView` calls it
  on the first sign of an assistive app: VoiceOver running, the first
  children, hit-test or focus query on the view, or `CefApplication`
  receiving `AXEnhancedUserInterface` or `AXManualAccessibility`, which
  arrive through the informal accessibility protocol.
- `on_accessibility_tree_change` delivers serialized `AXTreeUpdate`s, one
  tree per frame, with node data, child lists, relative bounds, tree data
  (focus, selection, load state) and events.
  `on_accessibility_location_change` delivers moved nodes. Both arrive as
  `cef_value_t` trees, which CEF lets any thread use. Reading a large
  page's tree value by value takes hundreds of milliseconds, so the main
  thread only copies it (`cef_value_t.copy`, one call), a serial
  background queue reads the copy into `CefJSON`, and the main thread
  applies the results in the order Chromium sent them. The copy takes
  about a quarter of the main thread's time that writing the tree as JSON
  text and decoding the text took
  ([design notes](design-notes.md#offscreen-accessibility-updates)).
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
through input: clicks at the node's centre, arrow keys, and text committed
as an input method commits it (`ime_commit_text`, replacing the field's
whole value), with `Input.insertText` only for a field that takes no
input-method text. Focus and scrolling use `DOM.focus` and
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

- A browser's bridges and user scripts, its profile's and its own, travel
  as JSON in the `extra_info` of its creation
  (`cef_browser_host_create_browser`, `cef_browser_view_create`, and
  `on_before_popup` for popups). CEF hands `extra_info` to every renderer
  process that shows a frame of the browser, before that frame's first
  document starts, so nothing waits on a message and no first document
  runs on `about:blank`. A browser Chromium creates in a window of its own
  has no `extra_info`; its configuration reaches each renderer as the
  browser's frames attach (`on_frame_attached`), which CEF reports once a
  frame's first document has committed, so that document goes without.
- When a context is created in a frame's main world, the user scripts that
  match run with `cef_v8_context_t.eval`, as scripts without a URL; scripts
  for document end run from a `DOMContentLoaded` listener added first.
- A bridge is a global object whose named-property interceptor answers
  `invoke`, `on`, `off` and any other name with a native function. A call
  creates a promise, sends `cefswift.page.call` with the argument and the
  document's origin (`self.origin`, read as the context is created), and
  the reply resolves or rejects it. V8 values are read and made through
  the V8 API, straight into and out of the message
  ([Data paths](#data-paths)), with no `JSON` object or injected script;
  the page's getters, `Proxy` traps and `Object.keys` run as they would
  for `JSON.stringify`. Cross-site frames run in other renderer
  processes, which get the configuration with the browser, so `access`
  decides for them as for any frame.
- The browser process does not take the renderer's word for the origin.
  It establishes the caller's origin from its own record of the frame's
  committed address (`cef_frame_t.get_url` in the browser process) and
  checks the caller's frame and that origin against `access` before a
  handler runs (`CefBridge.establishedOrigin`):

  | Frame's address | Established origin |
  |---|---|
  | Scheme, host and port (`https:`, `http:`, a standard custom scheme) | The address's origin, if the renderer reports it; `"null"` if the renderer reports `"null"` (a sandboxed document); anything else rejects the call |
  | `blob:https://host/…`, `filesystem:https://host/…` | The origin they name, checked the same way; `blob:null/…` is opaque |
  | `file:`, or a custom scheme registered with `.local`, in the main frame | `file://` (or `myapp://host`), checked the same way |
  | `file:` or `.local` in a subframe | Opaque |
  | `about:blank`, `about:srcdoc` in a subframe | The nearest ancestor's established origin, checked the same way; opaque under a `file:` or `.local` document |
  | `about:blank` at the top (a popup's first document) | Opaque: CEF does not expose the frame that opened it |
  | `data:`, `javascript:`, other `about:` pages, any other address without a host (a custom scheme without `.standard`), an unparseable or missing one | Opaque |

  An opaque origin is reported to handlers as `"null"` and never matches
  `.origins(...)`, even when `"null"` is listed; `.mainFrame` and
  `.anyFrame` do not look at origins.

  The renderer reports `self.origin`, the document's own origin, not
  `location.origin`, the address's: they differ for `about:blank` and
  `srcdoc`, which have their parent's origin but an opaque address. For
  `file:` and `.local` schemes it is the other way round: Chromium 156
  gives every such document an opaque `self.origin` (`"null"`) while
  `location.origin` is `file://` (or the address's). The renderer then
  reports `location.origin` for a main frame only. A main frame cannot be
  sandboxed by an embedding page, but a subframe can, and neither CEF in
  the browser process nor `self.origin` in the renderer tells a
  sandboxed `file:` subframe from another, so `file:` and `.local`
  subframes, and their `srcdoc` and `about:blank` children, are opaque.
  A `.local` scheme's own handler could still sandbox a main frame with a
  `Content-Security-Policy: sandbox` header, which this does not detect;
  `file:` documents have no headers.

  The renderer installs an `.origins` bridge by the same rules where it
  can (it leaves out a top-level `about:` document), so a document
  refused in the browser process normally has no global at all.
- `evaluateJavaScript` sends `cefswift.page.evaluate` to the main frame,
  whose renderer runs the script in the main world and sends the value
  back the same way. A returned promise is awaited through its `then`.
- Changes after creation (`addUserScript`, `removeUserScript`, a
  profile's `userScripts` or `bridges`, `CefBridge.access`) go as a
  `cefswift.page.configure` message to every frame of the browser, and to
  each frame that attaches later. A renderer process reports its
  configuration generation (-1 for none) the first time it sees one of the
  browser's documents, and gets the current one if it differs.
  Generations come from one counter for every browser, so a configuration
  made later is always newer than any a renderer has.

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
| `snapshot()` | `Page.captureScreenshot`, for windowed browsers; an offscreen browser's snapshot is the frame its view shows. |
| CefPasskeys' `CefPasskeyController` | `WebAuthn`, `Debugger`, `Page` and `Runtime` enabled for the browser's lifetime; see [Passkeys](#passkeys). |
| `discard()`, `discardBlockers()` | `DOMDebugger.getEventListeners` on every frame's window, to find a `beforeunload` listener, which JavaScript cannot list: the main frame's window from `Runtime.evaluate`, a same-process subframe's from `Page.getFrameTree`, `DOM.getFrameOwner`, `DOM.describeNode`, `DOM.resolveNode` and `Runtime.callFunctionOn` (`defaultView`), a cross-site frame's the same way in a session of its own (`Target.getTargets`, `Target.attachToTarget` with `flatten`, `Target.detachFromTarget`). No domain is enabled. |
| Offscreen accessibility actions | `Accessibility.enable` for the length of one lookup, then `DOM.focus`, `DOM.scrollIntoViewIfNeeded`; `Input.insertText` only for a field that takes no input-method text. |

A browser created again after a discard enables the domains its session
had enabled before, before its page loads; a session that was never used
stays unattached.

## Data paths

What crosses between Chromium and Swift, and what is copied on the way.
Fixed-size values pass as raw values or as structs both sides read in
place; only strings and collections are encoded.

**Strings.** CEF's strings are UTF-16, Swift's UTF-8, so each crossing
transcodes once. A string going into CEF is transcoded into a stack
buffer (up to 1 KB, else one allocation) that CEF reads for the call;
CEF copies what it keeps. A string coming out is decoded straight from
CEF's buffer. Names CefSwift sends again and again, such as process
message names, are `CefStaticString`s, transcoded once for the process,
and received message names are compared with them without making Swift
strings.

**Page-scripting messages.** Bridge calls, replies, events and
evaluations carry one payload each: a `cef_binary_value_t` as the
message's first argument, or, above 64 KB, a shared memory region
(`cef_shared_process_message_builder_t`). The payload starts with a
24-byte header of six `Int32`s that both processes read in place
(`CefWireHeader`: the target document or request, the call, whether it
succeeded, a line and a column), followed by values:

| Tag | Value | Body |
|---|---|---|
| 0, 1, 2 | `null`, `false`, `true` | none |
| 3 | integer | `Int32` |
| 4 | number | `Float64` |
| 5 | string | `UInt32` length, UTF-8 |
| 6 | array | `UInt32` byte length, `UInt32` count, values |
| 7 | object | `UInt32` byte length, `UInt32` count, then `UInt32` key length, UTF-8 key and value for each member |
| 8 | bytes | `UInt32` length, bytes |

Numbers are little-endian. A container's byte length counts what follows
its own nine bytes, so a reader skips any value without reading it.

**Malformed payloads.** A renderer may be compromised, so the browser
process treats every payload as untrusted, and the renderer does the same
for the browser's as a matter of robustness. Before building anything from
a value, a reader checks its whole structure
(`CefWireReader.validateValue()`, which recurses no deeper than the depth limit):
every tag known; every run, key and element inside the payload and inside
its container; each container's count at most its byte length divided by
the smallest element (1 byte; 5 for an object member), and its elements
exactly filling its byte length. `readContainer()` refuses a count larger
than the byte length even unchecked, so no reader reserves room for more
elements than the payload holds. A malformed value is a thrown error: a
`DecodingError` for a handler's argument (the call is rejected) or an
evaluation's value (`evaluateJavaScript` throws), and `null` in the
renderer.

Both processes keep to the same limits (`CefWireLimits`), which writers
enforce and readers check, so every value one side writes, the other
reads:

| Limit | Value | Writer beyond it | Reader beyond it |
|---|---|---|---|
| Nesting of arrays and objects | 64 | The renderer writes `null`, as for a cycle; `CefWireEncoder` throws `EncodingError` | Error |
| Payload size, header included | 1 GiB | The renderer rejects the call or fails the evaluation; `CefWireEncoder` throws | Error, before reading |
| Values in a payload (containers, elements, members) | 16 Mi | Same | Error |

The value limit bounds what decoding allocates: a value on the wire takes
at least a byte, and decoded at most a few dozen (a `CefJSON` case, a
dictionary slot), so a reader allocates at most a few hundred MB for a
payload at the limits, never the gigabytes a forged count asks for.

Process messages without a wire payload (`configure`, `sync`) are read
through `CefProcessMessage`, whose accessors return `nil` for a missing
argument, another type, or a `.double` that is not exactly an integer.
Each handler checks the arity and types it expects and drops anything
else: a `sync` must be exactly one `.int`.

| Message | Header | Values |
|---|---|---|
| `cefswift.page.call` | document, call | bridge, method, origin, argument (the calling frame is the message's frame) |
| `cefswift.page.reply` | document, call, succeeded | bridge, result or error message |
| `cefswift.page.emit` | none | bridge, event, payload |
| `cefswift.page.evaluate` | request | script |
| `cefswift.page.evaluated` | request, succeeded, line, column | value or error message |

The renderer writes a V8 value into a payload through the V8 C API as it
walks it (`V8Wire`), transcoding strings from V8's UTF-16 into the
payload, and builds V8 values straight from one. The browser process
decodes a call's argument into the handler's `Decodable` type in place
(`CefWireDecoder`) and encodes the result straight into the reply
(`CefWireEncoder`); `evaluateJavaScript(_:as:)` decodes into `T` the
same way, and `evaluateJavaScript(_:)` builds its `CefJSON` from the
payload. Primitives cost no allocation; `Codable` costs one container
per struct, array or dictionary.

What the renderer writes is what `JSON.stringify` would: an object's own
enumerable string-keyed properties, listed by the document's
`Object.keys` (CEF's `get_keys` also lists enumerable properties of the
prototype chain, and aborts the renderer when a `Proxy` trap throws, so it
is not used); `undefined` and functions left out of objects and `null` in
arrays; Dates as ISO strings; `null` for a cycle or past the depth limit;
an `ArrayBuffer` as bytes. Reading a property can run page code (getters,
`Proxy` traps, a replaced `Object.keys`), and when that code throws, or
CEF reports an exception (`has_exception`) or a value it cannot read,
the whole value fails: a bridge call's promise rejects with the
exception's message and an evaluation throws `CefJavaScriptError`, rather
than sending what was read so far.

Bytes (`ArrayBuffer` in the page, `Data` in Swift) are copied as few
times as the processes allow:

| Direction | Copies |
|---|---|
| `ArrayBuffer` argument → Swift `Data` | One when nothing is read after it: from the `ArrayBuffer` into shared memory as the message is built. The handler's `Data` is the mapping itself. Two otherwise (see below). |
| Swift `Data` result → page `ArrayBuffer` | Two: into shared memory as the reply is built, then into a V8 backing store the `ArrayBuffer` owns. |

CEF's pointer to an `ArrayBuffer`'s bytes is valid while its
`cef_v8_value_t` lives, and page code can detach the buffer (`transfer`,
`postMessage` with a transfer list) and free the memory. So a deferred run
holds a reference to the value, and before the walk next reads a property
or an element, anything that can run page code, it copies every deferred
run into the payload buffer (`CefWireBuffer.materializeDeferred()`). The
single copy holds for an `ArrayBuffer` that is the argument, or the last
thing read (`{ data: buffer }`, `[x, buffer]`); one followed by any
other property or element (`{ data: buffer, name: "x" }`) costs a second
copy.

V8 cannot use the shared memory itself: Chromium enables V8's sandbox,
under which an `ArrayBuffer` must live in the sandbox's memory
(`cef_v8_value_create_array_buffer` over other memory returns NULL).
Bytes under 64 KB are copied into the payload and travel with it.

**Who unmaps shared memory.** A received payload (`CefWirePayload`)
holds the region, or the binary value and the message that own its
bytes, and releases them when its last reference goes. In the browser
process, a call's payload lives until its argument is decoded, unless a
`Data` of at least 64 KB was decoded from it: that `Data` holds the
payload, and the region is unmapped when the `Data` and its copies are
gone, on whatever thread that happens. In the renderer, a reply's payload
lives until the promise is settled, inside the message handler; if the
document went away first, no value is made and the region is unmapped
as the handler returns. A sending process unmaps its side once CEF has
sent the message.

**Scheme handler bodies.** A `.data` body is copied from the `Data` into
CEF's buffer, once per `read`. A `.file` body is read with `pread(2)`
into CEF's buffer, with no copy in between. A `.stream` body's chunks
are copied into CEF's buffer once, and the producer waits while more
than 1 MB is buffered.

**The app's requests.** `CefProfile.data(for:)` and `bytes(for:)` turn
a `URLRequest` into a `cef_request_t` (`URLRequestPlan`, tested without
Chromium) and start a `cef_urlrequest_t` on the profile's request context
from the IO thread. `on_download_data` hands over a pointer into
Chromium's buffer, valid for the call. For `data(for:)` it is appended to
one `Data`, reserved from `Content-Length`, so each byte is copied once.
For `bytes(for:)` each chunk becomes its own `Data` (one copy) in a
`URLRequestStreamBuffer`, a lock-protected state machine tested without
Chromium. `cef_urlrequest_t` has no way to pause a body, and blocking
the IO thread until the reader catches up is not allowed; real back
pressure would need a `cef_thread_t` per stream to block in
`on_download_data`, and a `cef_thread_t` must be stopped and released on
the thread that created it, which a stream that ends at quit cannot
promise. So the buffer never refuses a chunk for being slow to read:
it keeps up to `streamMemoryLimit` (16 MB) in memory, hands a chunk
straight to a reader that waits, and past the limit queues each chunk,
as it is, for a serial queue that appends the queued chunks to a spill
file in batches of up to 64 (`pwritev`). Once anything has spilled,
later chunks are queued too, until the reader has caught up; the file
is then truncated and chunks stay in memory again, so order holds
whatever the interleaving. The reader takes memory first, then written
bytes in 1 MB reads on the same queue, then a queued chunk directly when
nothing written is left before it, so a reader that keeps up never
waits for the disk. Queued chunks are memory until they are written:
while the network outruns the disk (a local server can deliver 64 MB
in the 30–50 ms the disk needs to take it) they pile up, by as much as
40 MB of a 64 MB body in SelfTest, and are released as the disk catches
up. A `.spillToDisk(limit:)` cap bounds that too. The end of
the body, or the request's error, is the reader's after every byte
before it. The file is opened on the first spill, in the profile's
directory or, for an incognito profile, the temporary directory, and
unlinked at once, so a crash leaves nothing; cancelling, leaving the
loop, dropping the body, a quit and the end of the body close it.
`.spillToDisk(limit:)` caps the file and `.fail` keeps the body off disk;
past either the request fails with `ERR_INSUFFICIENT_RESOURCES`.
`download(for:to:)` does not use the buffer: each chunk goes to a queue
that writes it into the destination. A 64 MB body read off the main
actor arrives in about 800 chunks, usually with under 2.5 MB in memory;
a reader that waits 1 ms per chunk takes all of it through the spill
file, with 1 MB in memory and the footprint a few MB higher once written. The client struct
owns the loader; the loader holds the `cef_urlrequest_t` until the request
completes, which breaks the cycle through CEF's reference to the client.
Each loader is registered from the moment it takes a request-context
reference. Quitting closes the registry, cancels every registered loader
on the IO thread and waits, suspended on the main actor while Chromium's
message loop keeps running, until each has cancelled its
`cef_urlrequest_t` and released its CEF references there, and has
closed its spill file or removed its partial download; only then does
shutdown begin. Their callers get `CefError.shutDown`. A drain that has
not finished after five seconds is abandoned with a log line, and what is
left is cancelled without waiting, so a stuck IO thread cannot stop the
app from quitting.

**DevTools messages.** CEF splits each message into a method and its
parameters as UTF-8. An event's parameters are parsed, without a copy,
only when something listens for the method; a method result is copied
once, for the call waiting on it.

## Internal-page services

CEF has no API for bookmarks, history, most-visited sites, omnibox
suggestions or tab discarding, but Chromium's own WebUI pages reach those
services. `CefServiceHosts`, one per profile, calls them from hidden
Chrome-style browsers it calls service hosts. The engine is CefKit's,
since native tab discarding uses it; the bookmark, history, most-visited
and omnibox hosts and modules are CefChromium's, declared there and
registered with the engine by being called.

`CefHistory.topSites()` binds a new most-visited page handler for each
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
| `chrome://bookmarks` | `chrome.bookmarks`, `chrome.tabs`, `chrome.windows`, `chrome://favicon2` | `CefBookmarks`, `CefHistory.favicon`, `CefTabStrip`'s reads of tabs and windows and its changes (no `chrome.tabs` event listeners: one on this page crashed Chromium later, when an extension was disabled or an incognito window opened) |
| `chrome://tab-strip-internals` | `tab_strip_internals.mojom.PageHandlerFactory` | `CefTabStrip`'s groups (names, colours, collapsing), tab alerts, recently closed, and the updates that wake its reads |
| `chrome://history` | `history.mojom.PageHandler`, `chrome://favicon2` | `CefHistory.search`, `remove` |
| `chrome://new-tab-page-third-party` | `most_visited.mojom.MostVisitedPageHandlerFactory` | `CefHistory.topSites` |
| `chrome://omnibox` | `mojom.OmniboxPageHandler` | `CefAutocomplete` |
| `chrome://discards` | `discards.mojom.DetailsProvider`, `discards.mojom.GraphDump` | Discarding: Chrome-style tabs, and audio and form input of Alloy-style pages |
| `chrome://extensions` | `chrome.developerPrivate`, `chrome.management` | `CefExtensions` (not in incognito: Chromium ends the process when an incognito profile opens it) |

`chrome://new-tab-page` binds most-visited and the search box's
`searchbox.mojom.PageHandlerFactory` too, and the search box answers
queries with Chromium's autocomplete. It ranks for the new tab page,
though: a web search first even when a bookmark matches the typed
address, no match on bookmark titles, and no relevance or bookmarked flag
in its results. CefChromium keeps `chrome://omnibox`, whose controller is
the address bar's.

**The smallest document.** A service host loads the host's
`strings.m.js`, a few kilobytes of JavaScript that Chromium shows as text,
instead of the page's app, and each service imports only the generated
`*.mojom-webui.js` module it needs, from `chrome://resources` where
Chromium serves it there. Its renderer has the host's bindings and none of
the app's scripts, styles or elements. A host starts in about a tenth of a
second.

**Services as modules.** A `CefServiceHost.Module` names the hosts that can
serve it and a JavaScript `setup` that builds a service object once per
document — a bound Mojo remote, or an extension API with listeners. A
call runs a function, `async (service, args, context) => value`, against
that object in the host's renderer and decodes its value into the caller's
type; a module that serves from several hosts (favicons) uses whichever of
them runs. Hosts attach no DevTools session. Adding a service is declaring
a module and calling it.

**Calls.** The first call in a host document installs a small runtime
(`CefServiceHostRuntime`, `window.__cefswiftServices`), and the first call
of each function defines it there, compiled once; every later call is one
line, `__cefswiftServices.invoke(handle, args, call)`, sent as an
`evaluate` message. The runtime encodes the function's value in the wire
format itself, into one `ArrayBuffer`, with JIT-compiled code; walking the
value through the V8 C API (`V8Wire`) costs about a microsecond a value,
which for 5 000 history entries was 98 ms of a 152 ms call (now 31 ms). The reply carries
the buffer as one bytes value. The browser process checks its structure
with the same validator as any renderer payload, and `CefWireDecoder`
decodes the caller's type straight from it: no `CefJSON` tree, no JSON
text. A reply of 64 KB or more is decoded off the main actor.

| Hop | A result under 64 KB | 64 KB or more |
|---|---|---|
| JavaScript value → wire bytes | one pass, into the runtime's scratch buffer, then one copy into an exact-size `ArrayBuffer` | the same |
| `ArrayBuffer` → process message | into the payload buffer, then CEF's `cef_binary_value_t` | once, into shared memory |
| Browser process | read in place; strings copied into the Swift values | the mapping read in place, on a background thread |

**Cancellation.** Each call has an `AbortController` in the host, whose
signal the function gets as `context.signal`. Cancelling the calling task
resumes it at once with `CancellationError` (`CefPendingOperations` and
`withDeadline` complete a waiter synchronously when cancelled on the main
thread), then sends `cancel(call)` as an evaluation the renderer does not
answer (request 0). The signal aborts; the omnibox module stops Chromium's
controller (below), and a Mojo call that cannot be aborted, such as a
history query, runs out with its result dropped. A reply that arrives
after its caller has gone finds no waiter and is released undecoded; the
runtime forgets the call when its promise settles.

**Progress and events.** `context.progress(value)` sends an intermediate
value, encoded the same way, through the host's `CefBridge`
(`__cefswiftServiceEvents.progress({call, data})`). One is in flight per
call at a time: a value produced while the one before is on its way
replaces the one waiting, so a slow consumer bounds memory and sees the
newest, and none is delivered after the call's result. `emit(name,
payload)` coalesces events of one name the same way, which turns a burst
of 10 000 bookmark changes into about 600 deliveries. Autocomplete streams
each response of Chromium's controller as progress, so local matches
arrive before the search engine's.

**Autocomplete.** `mojom.OmniboxPageHandler` drives one controller per
handler, and `chrome://omnibox` binds one handler per page, so a profile
has one query at a time: `CefAutocomplete` lets the latest win, ending the
stream before it, and the module settles a query superseded in the host.
The handler has no stop call; an aborted query starts a query for no
text, since `AutocompleteController::Start` stops every provider (their
network requests included) before it runs, and no provider answers empty
input.

**Host failures.** A call whose host stops before it answers — the
renderer crashed, or the host was closed — throws `"… stopped
responding"`, unless the call is idempotent (reads), which is then made
once more on a new host. A call that times out is not repeated: it closes
the host, and waiting as long again would double the delay.

**Lifetime.** A host starts on the first call that needs it and closes 30
seconds after its last one, when macOS reports memory pressure, when its
profile's last browser closes (except the default profile's), and when
the app quits. A call that times out, or a renderer that dies, closes the
host; the call throws and the next one starts the host again. Service
browsers are left out of `CefRuntime.browsers` and
`CefWindow.all`. Their windows are 1 × 1 point, since a hidden
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
atomically. It holds the save back while the app shows no page in a
visible window (measured with SelfTest's groups run alone: over a minute
with only hidden service hosts open, 2.5 seconds once a window shows a
page), and a new profile has no file until its first save. While the bookmarks host is not running, and
the file has been written since the last change made through it,
`CefBookmarks` reads the tree,
a folder's contents, a bookmark and the recent bookmarks from that file,
and `changes` watches it with a `DispatchSource`. A file in another
format version, or a profile with managed or account bookmarks, which the
file does not hold, falls back to the host. Searches and lookups by
address, whose matching is Chromium's, and every change go through the
host. History, favicons and top sites live in SQLite databases that
Chromium opens with exclusive locking: a read-only open fails with
`SQLITE_BUSY` once Chromium has written, and an `immutable` open reads
pages Chromium may be writing, so CefChromium reads them only through the
hosts. The DevTools Protocol of Chromium 156 has no domain for any of
these services.

`chrome://history` cannot open in an incognito profile, and an incognito
profile keeps no history, so `CefHistory` throws there instead of starting
a host. An incognito profile's bookmarks are the default profile's
`CefBookmarks`, since Chromium shares the original profile's bookmarks
with its incognito profile.

### Extensions

`CefExtensions` reads `developerPrivate.getExtensionsInfo()` (each
extension's state, location, permissions, commands, its icon as a `data:`
URL) and reads what that does not report, the toolbar action and the pages
an extension replaces, from the `manifest.json` in the directory Chromium
runs the extension from. Changes go through `management.setEnabled`,
`developerPrivate.updateExtensionConfiguration` (incognito, site access,
pinning), `reload`, `autoUpdate`, `updateProfileConfiguration` (developer
mode), `packDirectory` and `loadUnpacked`. Two need what a page's user
gives Chrome's own:

- `loadUnpacked` asks for the directory with a file dialog of the calling
  page. CEF routes a Chrome-style browser's file dialogs to its client, so
  the service host's delegate answers it: `CefServiceHosts.fileDialogAnswers`
  holds the answer for the next dialog of a host.
- `management.uninstall` runs only with a user activation and always
  confirms, even with `showConfirmDialog: false` when the caller is not the
  extension itself. `CefServiceHosts.grantUserActivation(to:)` gives the
  host's page one (`Runtime.evaluate` with `userGesture`, the only DevTools
  call a service host makes), and `CefExtensions` presses the accepting
  button of Chromium's "Remove “…”?" bubble through accessibility; the app
  asks the user first.

`developerPrivate.onItemStateChanged` reports changes while the host runs;
otherwise `CefExtensions` watches the profile's `Extensions` directory and
`Preferences` files and reads again, so it starts no host to stay current.

`CefRuntime.Configuration.extensions` is CefKit's: `.unpacked` adds
`--load-extension`, and `.webStore` and `.package` are written to
`<root>/External Extensions/<id>.json` before `cef_initialize`, Chromium's
user-level external extensions directory (`chrome::DIR_USER_EXTERNAL_EXTENSIONS`,
the user data directory's), read at start-up by every regular profile.
CefKit keeps a ledger of the files it wrote and removes its own when the
configuration drops them. Chromium installs these disabled (an external
install, `ExternalInstallManager`); `CefExtensions` enables each configured
one once and records it in the profile's `CefSwift Accepted Extensions`.

CefKit adds Chrome's toolbar to a `CefWindow` that asks for one: CEF
creates it with the browser view (`get_chrome_toolbar_type`) but leaves it
to the window to place (`cef_browser_view_t::get_chrome_toolbar`), hidden.
`CefWindow` adds it above the page once the view is in the window
(`on_window_changed`), shows it, and keeps its height in the box layout.

## Passkeys

A `CefPasskeyController` (CefPasskeys) is an attachment that prepares
before the first document. For each browser it is attached to, a
`CefPasskeySession` takes the WebAuthn calls over through the browser's
DevTools connection, before the browser loads its first page:

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
  page, is resumed at once unless someone else debugs the page: the app,
  holding its own `Debugger.enable` lease on the browser's session, or
  the browser's DevTools window. Those pauses are theirs to resume.
- While the page is stopped, the delegate decides, and the session adds a
  virtual authenticator (CTAP 2.1, internal transport, resident keys,
  user verification) for that one call: empty for a registration, holding
  only the chosen passkey (its PKCS #8 key from the store) for an
  assertion, or with failing user verification for a refusal, which
  rejects the call at once. The page then resumes and makes its call.
  `WebAuthn.credentialAdded` or `credentialAsserted` reports the result,
  which goes to the store, and the authenticator is removed. Chromium
  reports the credential as it answers the page, so the save cannot
  change the page's result; the store is checked before the delegate is
  asked instead (`checkAvailability()` for a registration, the read of
  usable passkeys for an assertion), and a failure there refuses the call. An
  authenticator left over from an earlier call is removed before the next
  decision, so no call is answered unasked.

An Alloy browser discarded by closing it gets a new DevTools session when
it is created again, so the controller sets the environment and the
breakpoints up again in `browserDidRestore(_:)`; a Chrome-style tab
discarded in place keeps them.

The private key of a passkey lives in the store, and in Chromium's browser
process only while an authenticator answers one call. A page learns only
what WebAuthn gives it: the credential ID, the public key, the user handle
and signatures.

Chromium's own WebAuthn dialog (a browser without a controller) is a views widget: a child
window of a `CefWindow`, or a free-standing window for a browser in
a view. CefSwift leaves it alone; closing it from AppKit crashes Chromium.
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
from `GetTabDiscardsInfo` as blockers, leaving out the ones it overrides
(active tab, DevTools attached, recently visible, URL scheme, notification
permission, an earlier discard attempt); a reason it does not know is a
blocker, `.unknown(reason)`, as is a check that fails or times out.

`TabDiscardsInfo` (Chromium 156) carries a tab's last committed URL, its
title and an `id` that `GetTabDiscardsInfo` numbers from 1 on every call;
nothing in it, such as a process or frame identifier, maps to a CEF
browser. CefKit therefore takes a browser's tab to be the one tab with its
address or, when several share it, the one that also has its title, and
treats any other outcome as a blocker. The look-up, the check of that
tab's protections and visibility, and `DiscardById` run in one call on
the service host, so the tab discarded is the tab just checked. CEF's
frame count for a browser drops to zero when Chromium discards its tab;
if another of CefKit's browsers loses its frames instead, the discard
reloads it and fails.

`discard()` records the browser's navigation generation (counted at each
main-frame load start) and address before its checks. After the checks,
and again after `browserWillDiscard(_:)` and the snapshot, immediately
before unloading, it checks the browser is still hidden, idle and on the
same document, and stops otherwise.
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
event streams keep delivering; the accessibility state is applied; the
attachments' `browserDidRestore(_:)` runs (a passkey controller sets
itself up again there); user scripts (scripts added with `addUserScript`
included) and bridges are installed, as for a new browser. Calls that wait for the
restore resume when that page starts loading, and
`browserDidRestore(_:)` follows. Its back/forward list starts from that
page. Closing a browser
never ends a renderer process another browser shares; Chromium keeps the
process until its last frame goes.

An Alloy browser's blockers come from its own state (on screen, loading,
DevTools, downloads, media capture from `on_media_access_change`), the
`beforeunload` listeners the DevTools Protocol reports for every frame
(`CefBeforeUnloadListeners`, as for Chrome-style browsers), and, for audio
and form input, Chromium's performance-manager graph. CEF's API has no
audible state short of an audio handler, which takes the audio over, and
nothing about form input. The performance manager keeps a `PageNode` for
every `WebContents`, Alloy-style ones included, with the facts Chromium's
own discard rules (`DiscardEligibilityPolicy`) use: `IsAudible` (from the
`WebContents`' audio stream monitor, so any frame, media element or Web
Audio, but not a muted element), when audibility last changed, and
`HadFormInteraction` and `HadUserEdits`, which Blink reports per document.
`CefPageGraph` reads them through `discards.mojom.GraphDump`, the
interface behind the Graph view of `chrome://discards`, on the same
service host as tab discarding. Its module subscribes once per host
document (`SubscribeToChanges`) and keeps each frame node's page id and
frame token from the `FrameInfo` descriptions. CEF's frame identifier is
`"<render process id in hexadecimal>-<frame token>"`, so a browser's page is the page of
the frame node whose token is its main frame's, with no address or title
matching. Each check asks for that page's current description
(`RequestNodeDescriptions`) and reads `PageNodeImpl`'s `is_audible`,
`audible_change_time` (sound within the last minute counts, Chromium's
`kTabAudioProtectionTime`), `had_form_interaction` and `had_user_edits`.
A missing node, a missing field or an unreadable time is `.unknown`, so a
Chromium change keeps pages loaded instead of losing them, and SelfTest's
`discard blockers (view)` checks fail. With the host running a check takes
about a millisecond; the first starts the host (0.2 to 1.5 s measured), which
closes after the service hosts' idle timeout as for any call. Picture in
picture, devices and exemptions are not reported for Alloy browsers.

The graph also describes `has_nonempty_beforeunload` on frame and page
nodes, but nothing in Blink sets it: it stayed `false` with listeners in
the main frame and in subframes, in both runtime styles. So
`beforeunload` stays with the DevTools Protocol. `getEventListeners`
lists only the listeners of the context its object belongs to, so each
frame's window is reached in that frame's main world; a cross-site
frame lives in another renderer and is reached in a flat session
attached for the check. CEF's typed DevTools callbacks do not handle
messages carrying a `sessionId`, so `CefDevTools` takes them in
`on_dev_tools_message`: a reply completes its call, an event is dropped
rather than delivered as the browser's own session's.

The library has the capability, not a policy: nothing in CefKit discards a
browser unasked. The lifecycle coordinator restores a discarded browser
when it comes on screen (a new Chromium browser for one discarded by
closing it; a reload, after a moment, for a Chrome-style tab that
Chromium has not loaded by itself). When to discard is the app's:
`CefBrowser.lifecycle` and `lifecycleChangedAt` tell how long a browser
has been hidden, and `DispatchSource.makeMemoryPressureSource` reports
memory pressure. The Browser example's Memory Saver
(`Examples/Sources/Browser/Features/TabDiscarding`) builds the usual policy
from those.

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
| Chrome style (`CefWindow`) | Hidden by Chromium | Hidden by Chromium | Hidden by Chromium | Hidden by Chromium |
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
critical, `CefRuntime.energyPolicy` caps offscreen browsers' frame rate
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
`terminate(_:)` again from the run loop. It then waits for the profile
requests in flight to end on the IO thread (see “The app’s requests”), declining once
more and calling `terminate(_:)` again when they have, and shuts Chromium
down in a fixed order: the shutdown participants (service hosts, the
media router's registrations), lifecycle observers and the discard policy's
timer, the preference and site-setting
observer registrations (`CefObserverRegistration`, whose streams finish)
and the task manager object, every profile's request context,
the message pump, then `cef_shutdown()` with the thread actors' jobs
waiting it out. `CefRuntime.state` is `.stopping` meanwhile and `.stopped`
after; `initialize` then throws `CefError.shutDown`, as Chromium cannot
start twice in a process. Calling `cef_shutdown()` earlier, or from inside
a CEF callback, crashes, so the shutdown is internal to this path. A page that
asks to stay cancels the quit. A browser discarded by closing has no
Chromium browser left and is marked closed at once.

Logging out, restarting and shutting down send the app a quit Apple Event,
which AppKit handles with `terminate(_:)`. While the browsers close, the
runtime suspends that event (`NSAppleEventManager.suspendCurrentAppleEvent`),
as `NSApplication.TerminateReply.terminateLater` does, and resumes it when
they are gone, or with `userCanceledErr` when a page asks to stay, which
stops the logout as an app that cancels it does.

## Settings, tasks and certificates

Preference and site-setting streams each hold a `cef_registration_t`
through `CefObserverRegistration`; the observation ends when the stream's
consumer stops, on the main actor, or at shutdown. Chromium measures CPU
and memory only while a task manager object is alive, so
`CefTaskManager` holds one for two refresh intervals after each read and
lets go when nothing reads; its API names no process, so tasks are grouped
by Chromium's ordering and identical figures, an estimate the public API
says it is. Camera and microphone requests reach
`on_request_media_access_permission` before Chromium reads the content
settings, so the client answers them from the settings and asks the
delegate only about the rest; desktop audio and video capture in the same
callback are `.systemAudioCapture` and `.screenCapture`, which no setting
answers and nothing stores, and a device grant never sets their bits in
the mask. Prompt-based permissions are answered and stored by Chromium
itself. Connection security is read from
the visible navigation entry's `cef_sslstatus_t` on each address and
loading-state change.

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
CefSwift's `cefswift-helper` product, which `cef bundle` or the Xcode
build phase builds with the app ([bundling](bundling.md)), through the
`cefswift` tool both run. It finds the framework dyld loaded with it, checks the API hash,
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

Both tracks link the helper with `-needed_library` and `-needed_framework`
for these two, in that order (`HelperLink.swift`), and `-dead_strip_dylibs`, which drops
libraries the helper does not use, such as Foundation, which SwiftPM's
build system links into executables by default. The helper uses the Swift
standard library and the C API, not Foundation.

A library that dyld loads at launch is fixed up by the kernel as its pages
are read in (page-in linking), so the framework's `__DATA_CONST` segment,
about 12 MB of pointers, stays clean memory that every process shares. A
library loaded with `dlopen` has the same segment fixed up in the process,
which makes all of it private, dirty memory. The app executable gets the
same benefit from the weak link `cef bundle` gives it; an Xcode target's
executable does not link the framework, so its process loads it with
`dlopen` ([bundling](bundling.md#xcode)). Across the six processes of the Minimal
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
