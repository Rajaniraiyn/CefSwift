# Design notes

Measurements behind choices CefSwift has made, and mechanisms it measured
and does not use. The [guide](guide.md) describes what CefSwift does; this
page records why. Figures come from the machine and method described in
the guide's [Footprint and launch time](guide.md#footprint-and-launch-time)
section unless a note says otherwise: an Apple M3 MacBook with 16 GB of
memory, macOS 27.2.1, CEF 156.0.28, 2026-11-12.

## Loading the framework at launch

`swift package cef bundle` links the framework into the app executable and
the helpers, so dyld loads it at launch, instead of CefKit loading it with
`dlopen`
([architecture](architecture.md#loading-the-framework-at-launch)). With
`dlopen`, each process holds about 12 MB of the framework's data as private
memory instead of clean, shared memory. The same apps before and after
that change and the presets' process settings (`measure-footprint.py`,
median of five runs); linking at launch accounts for most of the
difference:

| App | Processes | Memory | Launch |
|---|---|---|---|
| `CefWebView` with `.embedded` (the Minimal example), before | 6 | 185 MB | 276 ms |
| The same, after | 5 | 88 MB | 306 ms |
| Browser example, one tab (`.chrome` with its own name and scheme), before | 8 | 371 MB | 559 ms |
| The same, after | 7 | 166 MB | 551 ms |

Launch times vary by about 30 ms from run to run, so neither change
measurably changes them.

## Service hosts: Mojo handlers, not the WebUI apps

`CefBookmarks`, `CefHistory`, `CefAutocomplete` and discarding call the
Mojo handlers of Chromium's internal pages from hidden hosts. An earlier
design opened each page's WebUI app in its host instead. Those hosts cost
38 to 83 MB each, and their first call took as long as with the handlers.
The Browser example, measured with `measure-services.py browser` (median of
three) on a build without the passkey and Chromium-panel code:

| Browser example | Handlers: processes | Memory | WebUI apps: processes | Memory |
|---|---|---|---|---|
| At launch | 6 | 143 MB | 8 | 264 MB |
| After typing in the address field, bookmarking the page and opening the menu bar | 9 | 217 MB | 10 | 305 MB |
| 40 s later, once the hosts have closed | 6 | 157 MB | 10 | 290 MB |

## Service calls, measured

`SelfTest -benchmark services` calls each service on warm hosts and puts
them under load; the numbers below are from 2026-11-14, before and after
the changes described under
[Calls](architecture.md#internal-page-services), on AC power with other
apps open (three runs after; where they differ by more than noise, the
range). Main-thread time and allocations
are the app's main thread, which is also Chromium's UI thread, so they
include Chromium's own work there: an autocomplete query's 2 250
allocations are nearly all its controller's.

| Call (warm host) | Before: p50 / p95 | After: p50 / p95 | Main-thread allocations, before → after |
|---|---|---|---|
| Evaluating `1` in a host (the floor) | 0.13 / 0.16 ms | 0.13 / 0.16 ms | 33 → 33 |
| An empty service call | 0.27 / 0.32 ms | 0.31 / 0.37 ms | 90 → 82 |
| Autocomplete, complete result | 2.8 / 4.9 ms | 2.6–3.3 / 4.5–7.2 ms | 2 365 → 2 249 |
| Autocomplete, first result (streamed) | – | 1.8 / 3.2 ms | |
| History search, 20 entries | 1.07 / 2.53 ms | 0.78 / 1.91 ms | 956 → 883 |
| Favicon | 5.6 / 9.5 ms | 0.50 / 0.67 ms | 356 → 123 |
| 50 favicons, one call | – | 5.5 ms (0.11 ms each) | |
| Bookmark tree (40 nodes), host | 0.72 / 1.22 ms | 0.53 / 0.68 ms | 201 → 100 |
| Bookmark add and remove (two calls) | 1.10 / 1.73 ms | 1.16 / 1.66 ms | 210 → 186 a call |
| A change through the API → `changes` | 3.9 / 35.6 ms | 2.7 / 11.5 ms | |
| 5 000 history entries (synthetic, history host) | 152 / 172 ms; main thread 52 ms | 31 / 39 ms; main thread 3.4 ms | 205 000 → 20 100 |
| Bookmark tree of 10 000, host | 511 / 3 512 ms; main thread 122 ms | 182 / 321 ms; main thread 31 ms | 331 000 → 20 200 |
| Bookmark tree of 10 000, `Bookmarks` file | 36 ms, on the main thread | 0.10 ms until Chromium saves again; then 27 ms, off the main thread | 90 200 → 126 |

Where the large results' time went, per call:

| 5 000 history entries | Before | After |
|---|---|---|
| Building the records and encoding them in the renderer | 1.6 ms building; encoding is the next row's | 19 ms, both |
| Value → wire through the V8 C API (`V8Wire`), and IPC | 98 ms | 8 ms (the `ArrayBuffer` copied once) |
| Decoding in Swift | 45 ms (wire → `CefJSON` → JSON text → `JSONDecoder`), main thread | 6.8 ms, wire → records, off the main thread |

The encoder first wrote every string with `TextEncoder.encodeInto`;
copying short ASCII strings, most keys and values, unit by unit instead
took the renderer's time from 48 to 19 ms for the 5 000 entries and from
254 to 134 ms for the 10 000 bookmarks.

Under load:

| Load | Before | After |
|---|---|---|
| 200 queries 20 ms apart, each cancelling the one before | cancelled queries resumed about 5 ms after their cancel; main thread busy 20% | 0.10–0.25 ms (p50, under 0.4 ms p95); 10–20% |
| The same through `results(following:)` | – | a first result for each text 1.7–4.4 ms after it (p50), complete for the last text 117–154 ms after it; nothing from superseded texts |
| 1 000 concurrent calls across the hosts | 730 ms; favicons p50 484 ms | 194–209 ms; favicons 202 ms |
| 10 000 bookmark adds, 32 in flight | 5.1 s; 9 550 change events delivered | 2.9 s; about 600 |
| 10 000 calls, then the host's JavaScript heap | 36.2 → 37.7 MB | 22.6 → 13.3 MB |
| Pending operations and the census after each load | 0, clean | 0, clean |

A page busy in another browser changes none of these: it has a renderer of
its own.

What changed: functions compiled once per host document and invoked by
handle (messages for an autocomplete query went from 2.4 KB of script to
90 bytes, and the host's heap no longer holds a compiled script per call);
results wire-encoded in the host by JavaScript and decoded in place, off
the main actor from 64 KB; favicons as RGBA pixels instead of a canvas
re-encoded to PNG, base64 and decoded again, and many in one call;
cancellation that completes the waiter synchronously and aborts the call
in the host; progress and events one in flight, newest wins; the
`Bookmarks` file parsed off the main actor and cached until Chromium saves
it again.

Measured and left alone:

- An empty call costs 0.17 ms more than the evaluation floor: the
  deadline's operation task and timer (two main-actor turns) and the
  runtime's bookkeeping. A second deadline mechanism for calls on a live
  host would save part of it, under 10% of any real call.
- Invoking by handle saved less than expected on its own (0.26 → 0.21 ms
  of IPC and compilation on the empty call): V8 compiles a function body
  lazily, so a large `setup` cost little per call. It stays for the
  smaller messages and the steady heap.
- Arguments stay a JSON literal in the one-line script: 40 to 150 bytes,
  encoded in 5 to 30 µs.
- A long-lived channel per module (a Mojo pipe of the host's own, or a
  persistent wire stream) would still reach the browser process through
  CEF process messages, one created per send; CEF has no other channel
  from a renderer, so there is nothing to keep open.
- `chrome.bookmarks.getTree()` and the encoding take 130 ms for 10 000
  bookmarks, most of it Chromium's extension bindings building the tree
  as JavaScript objects. `children(of:)` reads one folder at a time, and
  the `Bookmarks` file serves trees while the host is closed.
- Chromium's autocomplete runs on its UI thread, the app's main thread.
  Debouncing would spare it work, but how long to wait is an app's call;
  the latest-wins API stops every superseded query instead.

### Routes below the WebUI pages

- **Symbols.** The framework exports 2 548 symbols: the 242 functions of
  CEF's C API, V8's debugging helpers, Rust and Crubit thunks, and app-mode
  entry points. Nothing of `HistoryService`, `BookmarkModel`,
  `FaviconService`, `TopSites` or `AutocompleteController` is exported, so
  there is nothing to reach with `dlsym`; the Objective-C runtime has
  Chromium's AppKit views, not its stores.
- **CEF's C API.** `cef_request_context_t` and the preference manager
  cover preferences and content settings. `get_navigation_entries` visits
  one browser's back-forward list, not the profile's history.
  `download_image` could fetch `chrome://favicon2` icons from a service
  host's browser without the canvas, but each image is its own renderer
  round trip (Chromium's image downloader runs in the renderer) with no
  batching, and the generic icon would have to be recognized in Swift.
  With the floor of a round trip at 0.13 ms against 0.50 ms for one icon
  and 0.11 ms each for a list now, it would not be clearly better.
- **Files.** `Bookmarks` is JSON Chromium replaces atomically, so reading
  it is sound and stays the fast path. History and favicons are SQLite
  databases Chromium holds with exclusive locking; a copy of one is
  consistent only between Chromium's transactions, which nothing outside
  Chromium can tell, so a read-only snapshot is not sound either.

## Extensions: Chromium's own, through `chrome://extensions`

Measured with SelfTest's survey (`SELFTEST_ONLY=extensions
SELFTEST_EXTENSIONS_DUMP=1`, `=2` for Chrome's windows, `=3` for a
`CefWindow` with Chrome's toolbar, `SELFTEST_EXTENSIONS_STORE=<id>` for the
store) on CEF 156.0.28.

- **CEF's C API has none.** `cef_extension_t` and the extension handler went
  with the Alloy runtime's extension system; CEF 156's headers keep only
  `cef_browser_t::get_identifier` ("also used as the tabId for extension
  APIs", which in Chrome style it is not: tab ids are Chromium's session
  ids), the `IDC_*EXTENSIONS*` commands and `CEF_TASK_TYPE_EXTENSION`.
  Chrome style runs Chrome's whole extension system, so the route is the
  one Chrome's own `chrome://extensions` uses: `chrome.developerPrivate`
  and `chrome.management`, which Chromium grants that host. Nothing is
  read from pages, and nothing is injected into extensions.
- **Rejected:** the DevTools `Extensions` domain (`loadUnpacked`,
  `uninstall`, `triggerAction`) answers "Method not allowed": it needs
  `--remote-debugging-pipe` and `--enable-unsafe-extension-debugging`,
  which an app should not ship. Policies (`ExtensionInstallForcelist`,
  `ExtensionSettings`) set as recommended values (`defaults write`, what an
  app can write) show in `chrome://policy` as errors: Chromium accepts
  them only as mandatory, from an administrator. `"was_installed_by_default"`
  in an external extension's file does not keep Chromium from installing
  it disabled. `fetch` of `chrome://extension-icon` from the host is
  refused by its CSP; `developerPrivate` gives icons as `data:` URLs anyway.
- **What runs where.** Content scripts, `declarativeNetRequest` and
  `webRequest` apply in every browser of the profile, Alloy-style views
  included; extension pages, popups and Chrome's extension UI need Chrome
  style. CEF makes each `CefWindow` its own Chromium `Browser` of type
  `popup` with one tab (`chrome.windows.getAll()` → `"popup"`), so
  `tabs.group`/`tabs.move` refuse its tabs ("Tabs can only be moved to and
  from normal windows") and `chrome.action.openPopup()` answers "Browser
  window has no toolbar", with or without Chrome's toolbar view; Chrome's
  extensions menu opens in such a window but its actions' popups do not.
  `openChromeWindow` windows are `normal`: there tabs, groups and popups
  are Chrome's. `tabs.create` and `windows.create` from a `CefWindow`'s
  extension page, and `runtime.openOptionsPage()`, open a Chrome window,
  which reaches `onChromeTab`.
- **Per-tab action state** (badge text and colour, title, icon an extension
  sets) lives in the browser process for Chromium's toolbar; no WebUI, Mojo
  interface or C API reads it, and asking the extension
  (`chrome.action.getBadgeText`) would mean running code in the extension's
  service worker through DevTools. `CefExtension.Action` is therefore the
  manifest's declared action.
- **The Web Store** works: its page has `chrome.webstorePrivate`, Add to
  Chrome shows Chromium's `ExtensionInstallDialogView` (a top-level widget
  window, not a child of the `CefWindow`), and accepting it installs. The
  banner "Switch to Chrome to install extensions" follows the brand in
  `navigator.userAgentData` (`Chromium`); no user-agent change is needed,
  so none is made.
- **Installing by identifier.** The external extensions directory is the
  one route that installs from the store without the user: Chromium
  downloads from `external_update_url` at start-up (about a minute in
  SelfTest), and installs an `external_crx` with no download. Both arrive
  disabled until accepted; enabling them once is the app's acceptance.
  An `--load-extension` directory loads in CEF 156 (Chrome's branded builds
  refuse the switch since Chrome 137), with no developer-mode warning in
  SelfTest's windows, in every profile.
- **Incognito.** Opening `chrome://extensions` in a `CefProfile.incognito()`
  ends the browser process, as `chrome://history` does, so the service
  host is the default profile's. An extension allowed in incognito did not
  run its content script in CEF's in-memory profile.
- **Uninstalling** confirms through Chromium's own bubble, whatever
  `showConfirmDialog` says, and wants a user activation; the library gives
  the host page one and accepts the bubble (see architecture.md). Not
  verified: that Chromium uninstalls an external extension whose file
  CefKit removed.

## Tab discarding: the capability, not a policy

CefKit discards a browser only when asked (`CefBrowser.discard()`) and
restores it when it is shown or used. An earlier design also had a
runtime-wide `discardPolicy` with a timer, memory-pressure handling and a
per-browser exemption; how long a tab may stay hidden, what counts as
memory pressure and which tabs are exempt are product decisions, so they
moved to the Browser example (`Features/TabDiscarding`), built from
`lifecycle`, `lifecycleChangedAt`, `discard()` and Dispatch's memory
pressure source.

### Audio and form input for Alloy browsers

Chromium's tab rules on `chrome://discards` were taken to cover only
Chrome-style tabs, so the first version read a `CefWebView` browser's
main frame by script (`<audio>`/`<video>` playing, `<input>`/`<textarea>`
edited). That missed other frames, Web Audio and `contenteditable`, and
read the page; it was removed, and for a while Alloy browsers reported
neither blocker. Page scraping is a last resort, so the native routes
were tried first, each against the official CEF 156.0.28 (Chromium
156.0.8078.88) with SelfTest probes:

- **Performance-manager graph: used, for both facts.** Chromium's
  performance manager (`components/performance_manager`) has a `PageNode`
  for every `WebContents`, and the probe found CEF's Alloy-style ones
  among them (`PageNodeImpl` type `kTab`). A page node carries what
  `DiscardEligibilityPolicy` decides with: `IsAudible()` (from
  `WebContentsObserver::OnAudioStateChanged`, the `AudioStreamMonitor`),
  the time it last changed, and `HadFormInteraction()` and
  `HadUserEdits()`, aggregated over frames from what Blink reports through
  `DocumentCoordinationUnit`. `chrome://discards` exposes the graph as
  `discards.mojom.GraphDump` (`DiscardsGraphDumpImpl`):
  `SubscribeToChanges(GraphChangeStream)` streams `FrameCreated`,
  `PageCreated`, the `…Changed` events and `NodeDeleted`, each with JSON
  from the node data describers (`PageNodeImplDescriber`,
  `FrameNodeImplDescriber`), and `RequestNodeDescriptions(ids)` describes
  nodes as they are now. A `FrameNodeImpl` description has `frame_token`,
  the second half of CEF's frame identifier, whose first half is the
  render process id in hexadecimal (`"6-7BDA0EC0…"` and
  `"7BDA0EC0…"`), so a browser's page is found exactly from its main
  frame. In the probe an audio element, Web Audio and a page muted with
  `set_audio_muted` were all `is_audible: true` (muting the browser does not
  make the page silent, as in Chrome); a playing `<video muted>`, and a page
  whose `play()` was refused for want of a gesture, `false`; a page paused
  a second earlier `false`, with `audible_change_time: "0 hr, 0 min, 1 sec"`;
  a text field typed into with `Input.insertText` had both
  `had_form_interaction` and `had_user_edits`. A description request took
  0.3 to 2 ms in the host's renderer. `CefPageGraph` reads it.
- **`chrome://discards` tab list: works, not used.** `GetTabDiscardsInfo`
  lists Alloy pages too, contrary to what the first version assumed, with
  "Tab is playing audio", "Tab has recently played audio", "Tab has form
  interactions" and "The user has edited the tab's content" where they
  apply. Its entries carry only address, title and a per-call `id`, so two
  views on one page could not be told apart; the graph's frame token tells
  them apart, so the tab list stays for Chrome-style tabs, where its `id`
  is what `DiscardById` takes.
- **`chrome://media-internals`, `chrome://process-internals`: not
  suitable,** and not probed further once the graph worked. Media
  internals reports players and audio streams per render frame through
  WebUI messages (`chrome.send`) rather than Mojo, identifies them only by
  process and frame routing ids, and has nothing on forms. Process internals
  (`process_internals.mojom`) describes frame trees and site isolation;
  the probe could not import its bindings from `strings.m.js` and it was
  not pursued, since it has neither fact.
- **CEF C API and AppKit: no signal.** `cef_browser_host_t` has
  `set_audio_muted`/`is_audio_muted` (the mute switch, not whether sound
  plays); `cef_display_handler_t::on_media_access_change` is capture,
  which `.capturingMedia` already uses; `cef_audio_handler_t` reports
  streams only by taking the audio output over, which a check must not
  do. Nothing in `cef_frame_t`, `cef_browser_t` or the context menu
  parameters reports form state. Chromium's `NSView` does not use
  `NSUndoManager` for web editing (`undoManager.canUndo` stayed `false`
  after typing) and leaves `NSWindow.isDocumentEdited` unset. The
  offscreen accessibility tree has field values but not whether the user
  changed them, and nothing on audio; reading it would be reading the
  page.
- **DevTools Protocol: partial.** `Media.playerPropertiesChanged` reports
  media element players (codec, tracks, frame URL) when `Media.enable`
  precedes playback, but no audible state, nothing for Web Audio (the
  `WebAudio` domain gives a context's state, not its output) and it needs
  a session from page load on. No domain reports form interaction
  without reading the DOM.
- **`CefRenderer`: no route.** CEF's renderer API reaches V8 contexts
  and process messages, not Blink's media or editing state; what it could
  learn it would learn by running in the page, the scraping this avoids.
- **Script scan: not needed.** It stays the last resort should a CEF
  update remove `GraphDump`; until then such a change reports `.unknown`.

The graph is Chromium-private: its JSON is unversioned, and
`chrome://discards` could drop the interface. A missing node or field,
or an unreadable time, is `.unknown(reason)`, never a page safe to
discard, and SelfTest's `discard blockers (view)` checks (a quiet page
reports nothing, an audible one exactly `.playingAudio`) fail on the
first CEF update that changes it. The cost is the `chrome://discards`
host's renderer, shared with tab discarding, while checks are made, the
graph's change stream into it meanwhile, and about a millisecond per
check (0.2 to 1.5 s for the first, which starts the host); the host closes after
the usual idle timeout.

### `beforeunload` stays with the DevTools Protocol

The page graph describes `has_nonempty_beforeunload`, on each frame
node's `document` and on the page node, which looked like a way to drop
the DevTools Protocol from `discardBlockers()`. A SelfTest probe against
CEF 156.0.28 read it for both runtime styles (`CefWebView` and
`CefWindow`) through every case that matters: a listener added after
load and removed again, `window.onbeforeunload` set and cleared, two
listeners with one removed, a listener in a same-site `iframe` and in a
cross-site one (out of process), at load and added after it. The field
was `false` every time, on every frame and on the page, while the
DevTools Protocol saw each listener. Chromium's source fits:
`FrameNodeImpl::SetHasNonEmptyBeforeUnload` is only the receiving end of
`DocumentCoordinationUnit`, and Blink's `DocumentResourceCoordinator`
has the sender, but `LocalDOMWindow`, `LocalFrame` and `Document` do not
call it; `LocalDOMWindow` reports `beforeunload` listeners only as a
sudden-termination disabler to its `RenderFrameHost`, which neither the
graph nor CEF's API exposes.
The CEF C API has nothing either (`try_close_browser` runs the handlers
rather than reporting them), nor has AppKit.

So the blocker stays with the DevTools Protocol, for both styles. The
probe found the old check incomplete: it asked only the main frame's
window, and Chromium runs `beforeunload` in every frame, so a listener
in an `iframe` went unseen. `getEventListeners` reports only listeners of
the context its object belongs to (`InspectorDOMDebuggerAgent`), so a
subframe's window has to be obtained in that frame's main world: from
`Page.getFrameTree`, `DOM.getFrameOwner`, `DOM.describeNode` (the owner's
`contentDocument`), `DOM.resolveNode` and `Runtime.callFunctionOn`
(`defaultView`). The DevTools frame id is the frame's DevTools token,
not CEF's frame token, so CEF's frame list cannot be used for this. A
cross-site frame is not in the main session's frame tree:
`Target.getTargets` lists it as an `iframe` target with a `parentId`,
and `Target.attachToTarget` with `flatten` gives a session in which the
same steps work. CEF delivers that session's messages to
`on_dev_tools_message` but not to its typed callbacks (a reply never
arrived until `CefDevTools` parsed them there), so `CefDevTools` takes
messages with a top-level `sessionId` there, and drops their events so
that listeners never mistake them for the browser's own. A check took
2 to 14 ms measured, subframes included; it enables no domain.

The page node's `PageLiveStateDecorator` data was also read, for
blockers Alloy browsers do not report. It has `IsConnectedToUSBDevice`,
`…BluetoothDevice`, `…HidDevice`, `…SerialPort`, `IsCapturingVideo`,
`…Audio`, `…Window`, `…Display`, `IsBeingMirrored`, `IsAutoDiscardable`,
`IsPinnedTab` and `IsDevToolsOpen` (`true` in the probe, whose DevTools
check had attached a session). None was added:
capture is `.capturingMedia` already, from `on_media_access_change`, for
both styles; mirroring is casting, which CEF does not have; pinning and
auto-discardability are Chrome tab-strip state an Alloy browser does not
have, and its exemptions are the app's policy; and the device flags
could not be checked without a device and a chooser the user answers, so
they are not known to be exact for Alloy browsers. Picture in picture is
not in the graph's descriptions at all.

## Passkeys: a module on an attachment, not a CefKit option

App-answered passkeys used to be `CefBrowser.Configuration.passkeys`, with
passkey members on `CefBrowserDelegate` and a passkey case in CefKit's
popup handling. They do not need CefKit's internals beyond a DevTools
session that is in place before the first document, so they moved to the
optional `CefPasskeys` module, built on `CefBrowserAttachment`. What made
passkeys special in CefKit, holding the first document and refusing to
let Chromium create native popups, became one general property an
attachment declares (`preparesBeforeFirstDocument`): any attachment that
must see every document from its first script needs both. A browser with
no such attachment keeps native popups and starts on its page at once.

## Chromium's own features: a module, not CefKit

Bookmarks, history and autocomplete, and the presentation of Chromium's
bubbles, find bar and status bubble, used to be CefKit API. They drive
interfaces Chromium keeps private: the Mojo handlers and extension APIs of
its WebUI pages, the format of its `Bookmarks` file, the classes of its
AppKit windows and the view names its accessibility reports. Each CEF
update can break them, and a browser product needs them where an app that
embeds pages does not, so they moved to the optional `CefChromium` module,
bound to the pinned CEF. What CefKit had to keep is general: the service
host engine, which native tab discarding needs too, per-window module
state, a Chrome-command interceptor, and an overlay slot over the page.
Without the module, Chromium shows its interface as it draws it.

### What Chromium shows over a Chrome-style window

SelfTest's surface inventory (`SELFTEST_ONLY=nativeUI
SELFTEST_SURFACE_DUMP=<folder>`) triggers about seventy pieces of
Chromium's interface in a `CefWindow`, with and without Chrome's toolbar,
and records each window that appears (class, size, parent, title, Views
classes, kind) and each delegate call CefKit makes instead. On CEF 156:

- **Attached to the window, as Views widgets** (what CefChromium follows):
  find bar, status bubble, zoom bubble, QR code, downloads bubble and its
  start animation, fullscreen notice (also for keyboard lock), HTTP
  sign-in (with `authenticationPrompt = .chromium`), autofill
  suggestions, USB and serial choosers, the payment sheet, print preview,
  and, with Chrome's toolbar, the tab group editor. Before this change
  the last six were `.other` with a title or a class name, or `.other("")`;
  they now have kinds (`.autofillSuggestions`, `.deviceChooser`,
  `.paymentRequest`, `.printPreview`), and what is still unknown (the
  download animation, the tab group editor) stays `.other`, observable and
  hideable.
- **Answered by the delegate, so never Chromium's UI**: every permission
  request (camera and microphone with fake devices, location,
  notifications, clipboard, MIDI, window management, protocol handlers,
  multiple downloads, screen capture), JavaScript dialogs, `beforeunload`,
  file choosers, downloads' destinations, context menus. There is no
  permission prompt or quiet chip to hide: the delegate path is the only
  one.
- **Windows of their own**, not attached: picture in picture, the task
  manager, DevTools, the colour panel (a `RenderWidgetPopupWindow`),
  `<select>` menus (native menus), macOS's share menu; and Chromium's own
  browser windows for `chrome://` pages it opens (downloads, extensions,
  settings).
- **Nothing at all**: send tab to self, the bookmark, translate, page
  info and save-password bubbles (with or without the toolbar), the app
  and avatar menus and the omnibox popup through commands, storage access,
  a popup blocked without a gesture (not even the delegate hears of it),
  an external protocol without a handler, the date picker, the crash page
  (a page).
- **Ends the browser process**: `IDC_MANAGE_PASSWORDS_FOR_PAGE`, with or
  without the toolbar; CefKit now refuses it.

Bluetooth, HID, screen-capture pickers after a grant, passkey sheets and
Cast were not triggered: each would reach a macOS prompt (Bluetooth,
Input Monitoring, Screen Recording, Touch ID, Local Network). The full
table is the probe's `inventory.md`.

Replacement is offered only where the app can get the surface's content
and act on it through CefKit (`Kind.capabilities`, the guide's table), not
uniformly: CEF has no API for translation, saved passwords, autofill,
device choosers, payments or print preview, so those kinds can be
observed, hidden and dismissed but not replaced.

### Chrome style and a dark page's canvas

A `color-scheme: dark` page without a background of its own shows the
browser's `backgroundColor` in Chrome style, where Alloy shows Blink's dark
canvas. Blink paints that canvas only when the frame's base background is
opaque; Chrome style leaves it transparent (the page's own frame reads
transparent) and paints `kColorWebContentsBackground` behind it, which
CefKit sets to `backgroundColor`. The CEF C API has nothing that sets the
base background of a Chrome-style page: `cef_browser_settings_t`'s
`background_color` does not reach it, `cef_view_t.set_background_color`
colours the view, and the theme colour is what shows through. The DevTools
protocol's `Emulation.setDefaultBackgroundColorOverride` sets it, which
should let Blink paint the dark canvas, but it would keep a DevTools
session on every Chrome-style page, which pages can notice
([guide](guide.md#features-that-use-the-devtools-protocol)); it was not
adopted or tried. SelfTest keeps its two limitation skips.

## Tabs: Chromium's tab strip under the app's own

A tabbed browser on CefSwift wants its own tab interface over Chromium's
own tab model, so that `chrome.tabs`, `chrome.tabGroups`, recently closed
tabs and moving tabs between windows behave as in Chrome. Five ways to
host many tabs in one window were tried on CEF 156 (SelfTest's
`tabHosting` group, and the exploratory probe
`CEFSWIFT_SELFTEST_PROBE=chromeTabStrip`):

| Hosting | What Chromium sees | Result |
|---|---|---|
| (a) Several Chrome-style `cef_browser_view_t` in one `cef_window_t` | — | CEF refuses: `CefBrowserViewImpl::AddedToWidget` logs "Cannot add multiple Chrome style BrowserViews" and never creates the second browser; the first keeps working. Chromium's `BrowserWidget` holds one `BrowserView`. |
| (b) One `CefWindow` per tab, attached as borderless child windows over the page area of one app window | One popup window of one tab per app tab | Works as AppKit (frame tracking, full screen, minimizing, the page taking the keyboard while the app window stays main, with an override of Chromium's `canBecomeMainWindow`), but Chromium's model is N one-tab windows: no indices, no groups. Built, measured and removed. |
| (c) Native window tabbing with the system tab bar hidden | As (b) | macOS keeps the tab bar of a group of two or more tabs shown; `toggleTabBar(_:)` does nothing. No custom rail can replace it. |
| (d) Alloy-style views in an ordinary `NSWindow` | Not tabs at all | `chrome.tabs` does not list Alloy browsers; no `chrome://` pages, extensions UI or history recording. |
| (e) The window Chrome draws (`openChromeWindow`) | A normal window with a real `TabStripModel` | Real tabs, pinning, groups, moves between windows. Chrome draws its own tab strip and toolbar. |

Every Chrome-style `CefWindow` is its own Chromium `Browser` with one tab
(`canExecute(.selectNextTab)` stays false even while macOS shows two of
them as one tab group; CEF's `ChromeBrowserHostImpl` says views-hosted
browsers hold a single tab), and `chrome.windows` reports it as a
`popup`, so `chrome.tabs.group` and `move` refuse its tabs. Only (e) makes
the app's tabs Chromium's.

In a window Chrome draws, measured:

- `chrome.tabs.create({windowId})` adds tabs to it; each reaches the app
  as a `CefBrowser` (`onBrowserCreated`).
- From the `chrome://bookmarks` WebUI, which Chromium grants `chrome.tabs`
  and `chrome.windows` (not `chrome.tabGroups`): `update` (active,
  pinned), `move` (within and between windows), `group` (with
  `createProperties.windowId`: the default target is the caller's window,
  a popup), `ungroup`, `duplicate` and `windows.create({tabId})` work. A
  move between windows keeps the `CefBrowser`, its identifier and its
  page.
- `chrome.tabs.remove` and `update({muted})` from that page ended the
  browser process (status 70, nothing logged); `CefTabStrip` closes tabs
  through CEF instead and leaves muting to `CefBrowser.isAudioMuted`.
- `chrome://tab-strip-internals` loads, and `tab_strip_internals.mojom`'s
  `GetTabStripData()` returns every window's tree: pinned and unpinned
  collections, groups with their title, colour and collapsed state, tabs
  with title, address, activity and alert states, and `OnTabStripUpdated`
  on changes; its window identifiers are `chrome.windows`'. It reports
  neither a new window nor a group renamed or recoloured (an extension's
  `chrome.tabGroups.update`) by itself.
- `chrome://tab-strip.top-chrome` (the WebUI tab strip) is not built on
  macOS; `chrome://tab-search.top-chrome` loads, but its Mojo modules are
  bundled into the app; `tabs_api.mojom.TabStripService` is bound only to
  the experimental WebUI browser window.
- Chrome's tab strip and toolbar take the top of the window (121 of 1006
  points in the probe; the page is the `WebContentsViewCocoa`). Chromium's
  `BridgedContentView` answers every hit test inside itself, so a view
  added to it gets no clicks; a view added to the window's frame view
  above the content view does, and the window buttons still work. An app
  can cover Chrome's strip and toolbar with its own this way.

CefChromium's `CefChromeWindow`, `CefTab`, `CefTabGroup` and `CefTabStrip`
are the result. Measured further (SelfTest `tabStrip`, and the
`extensions` probe's "tab strip and extensions" checks):

- **No way to have Chromium leave the strip and toolbar out.** A normal
  window always has both; popup and app windows have neither but are not
  tabbed. Chrome's vertical tabs (`vertical_tabs.enabled`, width
  `vertical_tabs.uncollapsed_width`) move the strip to the side and leave
  a toolbar of 46 points at the top. So the app's views cover them, at
  Chromium's height (87 points with tabs at the top).
- **Covered controls out of the way.** The accessibility tree loses them
  when `AXPlatformNodeCocoa`'s children leave out elements wholly under
  the cover (checked: no `AXTabGroup` or `AXToolbar` of Chromium's in the
  window's tree, the app's top bar in it). Keyboard focus Chromium moves
  to them (`IDC_FOCUS_LOCATION`, Tab past the page) does not change
  AppKit's first responder when it is already Chromium's content view, so
  CefChromium also looks at Chromium's focused accessibility element after
  each window update and moves focus to the app's views.
- **Matching tabs with browsers exactly.** Neither `chrome.tabs` ids nor
  `TabHandle`s are visible to CEF, and CEF's browser identifier is not the
  tab id. DevTools' `Target.getTargetInfo` gives a target id no tab API
  shows; `Browser.getWindowForTarget` gives the window, but needs a DevTools
  session on every tab. What is exact: a browser's view is in its tab's
  window (`nativeView.window`, background tabs' views included, hidden),
  shown only for the active tab; and `chrome.tabs` reports `mutedInfo` for
  every tab, which CEF sets (`set_audio_muted`). So: the active tab is the
  browser shown in the window, a background tab the one browser in the
  window with its address, and among background tabs of one address a
  browser is muted for a moment to see which tab reports it. Matches are
  kept by `chrome.tabs` id, which survives moves between windows (the
  `CefBrowser` does too).
- **No `chrome.tabs` event listeners on the WebUI host.** With
  `chrome.tabs.onUpdated` and the like listened to on `chrome://bookmarks`,
  Chromium crashed (`SIGTRAP`, nothing logged) later in the same run, when
  an extension was disabled and enabled again or an incognito window
  opened. `CefTabStrip` reads `chrome.windows.getAll({populate: true})` when
  `OnTabStripUpdated` reports a change, and every second for what that
  does not report (a new window, titles, sound); with groups present the
  internal page is read every two seconds for their names and colours.
- **Group names and colours** change through Chrome's own group editor:
  the header's `AXShowMenu` opens it, kept transparent, the name is typed
  through its `NSTextInputClient` and a colour pressed through
  accessibility. **Collapsing** has no route: the header offers no
  `AXPress` or expanded state, the editor no collapse item, and neither a
  click sent through the window at the header (with the cover set aside)
  nor a Space key collapsed it, with the window key. `setCollapsed` throws
  `.unsupported`; the Browser example collapses groups in its own rail.
- **Tabs the app opens keep its configuration.** Chromium adds tabs to its
  windows only itself (`chrome.tabs.create`, its commands), with CefKit's
  default client and configuration. `CefChromeWindow.openTab` creates the
  browser with the app's configuration in a window of its own, kept off
  screen and transparent, then `chrome.tabs.move`s its tab in: the browser,
  its bridges and user scripts come along.
- **Previews.** Chromium's hover-card thumbnails come from
  `ThumbnailTabHelper`, which only Chrome's views tab strip and the WebUI
  tab strip (not built on macOS) read; no route was found. Not done.

## Memory settings measured and not used

These were measured on the Minimal example and are not used: they saved
nothing on an idle page, cost more than they saved, or save the same as
`processPolicy = .onDemand`.

- `--js-flags=--lite-mode` and `--js-flags=--optimize-for-size`: no
  difference while idle; both slow JavaScript down.
- `--disable-extensions`, `--disable-spell-checking`, and turning off
  optimization-guide model downloads, Safe Browsing real-time lookups,
  certificate-transparency updates and preloading: no difference.
- `--disable-gpu-compositing`: 10 MB more.
- `--renderer-process-limit=1` and `--disable-site-isolation-trials`: save
  the spare renderer, as `.onDemand` does; the second also gives up site
  isolation.
- `--enable-low-end-device-mode`: saves the spare renderer and 3 MB more in
  the GPU process, and lowers rendering quality.

## Locale packs, SwiftShader and component updates

Measured on 2026-11-13 with CEF 156.0.28 arm64 on an M3, macOS 27.2.

**Bundle size.** The Minimal example (English only), logical size of
regular files: 333.0 MiB with every locale pack, 284.0 MiB with `en` only
(54 packs, 48.9 MiB, left out), 268.0 MiB without SwiftShader as well
(16.1 MiB). `du` reports 334 MiB, 284 MiB and 268 MiB.

**A locale without a pack.** Chromium told `--lang=ja` with no `ja.lproj`
in the framework starts, reports the locale it was told, and shows English
strings: `NSBundle` falls back to another localization of the framework.
CefKit therefore resolves the locale against the packs before
`cef_initialize`, so the locale Chromium reports matches its strings.

**SwiftShader.** Pages render, windowed and offscreen, with and without it
and with `--disable-gpu`. WebGL runs on ANGLE's Metal backend with the GPU;
with `--disable-gpu` there is no WebGL unless `--enable-unsafe-swiftshader`
is passed and SwiftShader is in the bundle. Chromium 156 does not fall back
to SwiftShader by itself.

**Component updates off.** With `--disable-component-update` Chromium
registers none of the components of `RegisterComponentsForUpdate`
(Widevine, CRLSet, PKI metadata, Safe Browsing lists, origin trials, …),
but it still registers the on-device model manifest ("Optimization Guide
On DeviceModels Manifest") and starts downloading it: the optimization
guide registers it outside that function. Turning off the
`OptimizationHints` or `OptimizationGuideModelExecution` features does not
stop it; no switch that does was found.

**Widevine with component updates on and protected media off.** CefSwift
does not ask for the CDM, and Chromium's updater still tries to fetch it:
in a run with `protectedMedia = .disabled`, `componentUpdates = .automatic`
and an unreachable DNS-over-HTTPS server, the Widevine component, which
started as not installed, reported an update error within 170 seconds,
having been checked without any request from CefSwift.

## Sandbox

Measured on 2026-11-13 with CEF 156.0.28 on an M3 MacBook, macOS 27.2, ad
hoc signed bundles, `Scripts/measure-footprint.py --kinds relaunch`
(median of five runs, physical footprint of the app and every helper,
launch to the first `browser(_:didFinishLoadWithStatus:)`). Another build
ran on the same Mac at the time, so run-to-run spread is wider than in the guide's table.

| App | Sandbox | Launch | Memory (range) |
|---|---|---|---|
| Minimal (`.embedded`) | On | 322 ms | 108.6 MiB (102.7–113.0) |
| Minimal (`.embedded`) | Off (`-sandbox NO`) | 315 ms | 110.6 MiB (90.2–118.2) |
| Browser (`.chrome`) | On | 440 ms | 173.2 MiB (171.1–179.3) |
| Browser (`.chrome`) | Off (`--no-sandbox`) | 384 ms | 162.0 MiB (160.9–165.1) |

In an earlier pair of Minimal runs, per process: GPU 24.5 MiB sandboxed
against 21.0 MiB, network service 10.9 against 7.7 MiB, the others within
1 MiB. The sandbox costs a few MiB in the GPU and network processes and
some tens of milliseconds at launch; SelfTest passes every check with it
on (491 checks, none skipped). It is on by default in every preset.

## Bridge and evaluation transport

Bridge calls and `evaluateJavaScript` carried JSON text in process
message strings: the renderer built a tree of the V8 value and wrote it
as text, the browser process parsed the text into `CefJSON` with
`JSONDecoder`, then encoded that tree with `JSONEncoder` and decoded it
again into the handler's type; results went back the same way, through
`cef_parse_json` and a second tree in the renderer. `Data` became base64
text and an `ArrayBuffer` an empty object. They carry the wire format in
[Data paths](architecture.md#data-paths) instead.

Measured with `SelfTest -benchmark bridge`, `evaluate` and `codec` on
2026-11-13, on AC power, Low Power Mode off, other apps open, the two
builds back to back; the second of two runs. Calls are sequential, each
awaited before the next. Allocations are those of the app's main thread,
counted through `malloc_logger`; the renderer's are not counted.

| Bridge call | JSON: calls a second | Allocations a call | Wire: calls a second | Allocations a call |
|---|---|---|---|---|
| `ping(Int) -> Int` | 14 700 | 90 | 18 500 | 38 |
| 20-field struct, both ways | 4 560 | 559 | 13 100 | 53 |
| 10 000 small structs, both ways | 3.0 | 1 290 375 | 26.7 | 30 076 |
| 16 MB `ArrayBuffer` in | not possible | | 529 (1.9 ms) | 42 |
| 16 MB `Data` out | 0.75 (1.33 s, as base64) | 352 | 253 (3.95 ms) | 47 |
| 16 MB as base64 text in | 1.55 (645 ms) | 463 | 35 (28.7 ms) | 48 |

| `evaluateJavaScript` | JSON: calls a second | Allocations | Wire: calls a second | Allocations |
|---|---|---|---|---|
| `Int` | 17 600 | 51 | 20 900 | 23 |
| 20-field object as a struct | 5 380 | 284 | 15 900 | 26 |
| 10 000-element array as `[Struct]` | 6.1 | 640 171 | 40 | 10 042 |
| The same as `CefJSON` | 7.4 | 490 097 | 44 | 10 023 |

In-process codec cost (`-benchmark codec`, same build, per value):

| Value | JSON decode | Wire decode | JSON encode | Wire encode |
|---|---|---|---|---|
| `Int` | 2.0 µs, 20 allocations | 0.13 µs, 1 | 2.9 µs, 22 | 0.27 µs, 4 |
| 20-field struct | 42 µs, 252 | 2.2 µs, 4 | 51 µs, 257 | 2.0 µs, 15 |
| 10 000 small structs | 100 ms, 640 119 | 5.1 ms, 10 020 | 118 ms, 650 121 | 4.3 ms, 20 017 |

What remains per call is mostly Chromium's: the message, its argument
list and binary value, the frame wrapper and its address, which the
origin check parses, and a `Task` for the handler. Decoding allocates
one container per struct (`Codable`'s `KeyedDecodingContainer` box) and
a string longer than 15 UTF-8 bytes. The wire form is 10 to 30% larger
than JSON text (fixed-width lengths and counts), which no measurement
showed a cost for.

Below 64 KB a payload travels in a `cef_binary_value_t`; above, in
shared memory, whose region costs a mapping on each side but saves
Chromium's copy of the argument list. A 16 MB `ArrayBuffer` argument is
copied once, into the region; the handler's `Data` is the region.

## Offscreen frames: copied, and only where they changed

Presenting Chromium's `IOSurface` directly would cost nothing, but
Chromium renders into a delivered surface again two or three frames
later and nothing the browser process does stops it
([architecture](architecture.md#frame-ownership) has the source
citations). So `CefOffscreenCompositor` copies, and copies only the
damage Chromium reports with each frame, into up to four surfaces of its
own, three above 32 MB a surface.

`SelfTest -benchmark compositor` on 2026-11-13, AC power, Low Power Mode
off, other apps open and other builds running, offscreen frame rate 120,
3 s of animation, two runs each, the two modes from one build
(`-compositorCopy whole` copies every frame whole into up to four
surfaces, as before). "Full" is a page whose whole background changes
every frame; "one block" a 4×4 grid of which one block changes per frame.

| Page, surface | Whole frames: presented a second | Memory | Damage only: presented a second | Memory |
|---|---|---|---|---|
| Full, 1280×800 | 119.8 | +13–63 MB | 119.6–119.9 | +53–63 MB |
| Full, 2560×1600 | 93–116 | +36–56 MB | 106–113 | +50–60 MB |
| Full, 5120×3200 | 47.5–52 | +191–221 MB | 71–115 | +128–159 MB |
| One block, 1280×800 | 119.2–120.1 | +53–63 MB | 119.7–119.8 | +53–63 MB |
| One block, 2560×1600 | 119.9–120.2 | +33–60 MB | 116–117 | +48–60 MB |
| One block, 5120×3200 | 78–83 | +131–237 MB | 98–101 | +129–174 MB |

The 5120×3200 one-block rows again, the two modes alternating, two
processes each:

| 5120×3200, one block | Presented a second | App CPU | App CPU per presented frame | Memory, second run |
|---|---|---|---|---|
| Whole frames | 44.8–48.6 | 19.5–22.9% | 4.1–4.9 ms | +192 MB |
| Damage only | 73.8–100.6 | 23.6–30.0% | 2.9–3.2 ms | +128–129 MB |

The display shows at most 60 frames a second. In every run, no presented
surface changed while it was the layer's contents and every one-block
frame was whole (the `compositor` checks read each presented surface
every 2 ms). App CPU varied by ±8 points between runs on this machine
with other work running, more than any difference between the modes, so
it is not compared here.

## Offscreen accessibility updates

Chromium's accessibility updates arrive as `cef_value_t` trees on the
main thread. A 28 000-node page (`-benchmark axingest`, 2026-11-13, the
two ways alternating in one build, with other builds running, so the
absolute times vary from batch to batch):

| Batch | Way | Main thread | Background | Tree ready |
|---|---|---|---|---|
| 1 | `cef_write_json`, text decoded, parsed on a queue | 63 ms | 315 ms | 971 ms |
| 1 | `copy()`, read value by value on a queue | 19 ms | 542 ms | 1 132–1 203 ms |
| 2 | `cef_write_json`, text decoded, parsed on a queue | 110–127 ms | 554–673 ms | 1 652–2 140 ms |
| 2 | `copy()`, read value by value on a queue | 32 ms | 826–835 ms | 1 838–1 844 ms |

The copy keeps the main thread free for three quarters of the time; the
tree is ready at about the same time either way, the slower background
read making up for the shorter main-thread step. CefKit copies. Reading
the original tree value by value on the main thread, without a copy, took
452 ms there for a 15 000-node page in an earlier measurement.

## Strings, scheme bodies and DevTools events

Measured the same way, 2026-11-13, before and after builds back to back
(`-benchmark requests`, `devtools`; nine and two runs):

- A string going into CEF was copied into an `Array` of UTF-16 units and
  then into a heap buffer; it is transcoded once into a stack buffer.
  The request filter's own work around the filter (three strings out,
  two URLs parsed, headers in) took 3.1–4.9 µs a request before and
  2.9–3.4 µs after: parsing the URL dominates; the referrer is
  parsed only when a filter reads it.
- A 200 MB `.file` body was read in 256 KB `Data` chunks on
  `CefFileActor` and copied from them into Chromium's buffer; it is read
  with `pread(2)` straight into Chromium's buffer. Total time (242–339 ms
  before, 280–284 ms after), peak footprint (+13–15 MB, +12–15 MB) and
  app CPU (220–328 ms, 222–234 ms) did not change measurably: Chromium's
  own work on the body sets them. What changed is one copy and one
  allocation per 256 KB fewer, and no actor hop per chunk.
- 20 000 DevTools events nobody listens to: CefKit copied each event's
  parameters before looking for a listener; it looks first. 8.0–8.2
  allocations an event on the main thread before, 6.0–6.3 after; CefKit's
  own time stayed at 0.9–1.0 µs an event.

The Minimal example's footprint (`measure-footprint.py`, median of five
relaunches) is 88.5 MiB after these changes, as before (88 MiB). The
web-compatibility probe (`compat-matrix.py probe`, rows `nothing`,
`bridge` and `evaluateJavaScript` in the windowed, offscreen and window
hosts) reads the same with the wire transport as without a feature,
except for the bridge's own global.

## Persistent profiles: directly in the root, and loaded before use

Observed on 2026-11-14 with CEF 156.0.28 (Chrome runtime) on an M3,
macOS 27.2, with Chromium's log at `info` and each case run on a new
root cache directory, then again on the same one.

**The rule.** `cef_types.h` says a request context's `cache_path` must
be "equal to or a child directory of" `root_cache_path`. Chromium 156 is
stricter: its profile manager creates profiles only in a direct child of
the user data directory (`root_cache_path`). With the earlier layout,
`<root>/Profiles/<id>`, every persistent profile logged

    ERROR:cef/libcef/browser/chrome/chrome_browser_context.cc:116] Cannot create profile at path …/Profiles/<id>

and got a new off-the-record profile instead, in windowed, offscreen and
Chrome-style browsers alike, at the first launch and every later one:
the directory CefKit had made stayed empty, cookies, local storage and
history lasted as long as the process, and CEF still reported the
context initialized, so nothing in CefKit or SelfTest noticed. Moved to
`<root>/Profile-<id>`, the same profiles were real: Chromium created the
directory and wrote `Cookies`, `Local Storage`, `History`, `Preferences`
and the rest, and found them at the next launch.

**Links count.** The comparison is made with symbolic links resolved: a
root under `FileManager.temporaryDirectory` (`/var/folders/…`, a link to
`/private/var/folders/…`) refused every `<root>/Profile-<id>` built from
it, with the same silent fall-back. CefKit builds profile paths from
`realpath` of the root. (`URL.resolvingSymlinksInPath()` does not help:
it keeps `/var`.)

**The global context.** A `cache_path` other than the root itself is
ignored for the global context: with `<root>/Custom` the directory was
created and stayed empty, and the default profile lived in
`<root>/Default`. CefKit therefore no longer has a `cacheDirectory`
option; the default profile is always `<root>/Default`.

**Creation while loading.** Chromium creates a disk profile
asynchronously; `on_request_context_initialized` reports it, 0.1–0.3 s
after `cef_request_context_create_context` the first time, less once its
directory exists. Until then `cef_browser_host_create_browser_sync`
(windowed browsers) fails, `cef_browser_view_create` gives a view whose
browser never appears (a `CefWindow` stayed empty, its browser
`.pending`), and preferences read `nil` and refuse writes; the
asynchronous `cef_browser_host_create_browser` (offscreen, Chrome's own
window) waits by itself. An in-memory profile, incognito or a fall-back,
is ready at once. CefKit waits for the callback before creating any
browser on a new profile, then checks the context's `get_cache_path` and
the directory, so a fall-back becomes `CefError.profileUnavailable`.
SelfTest's `profileStorage` group creates browsers on brand-new profiles
in each host, and runs two launches on one root to check what survives.

## System notifications at launch

Observed on 2026-11-14 with CEF 156.0.28 on macOS 27.2, from the unified
log (`usernoted`'s “Connection <bundle ID> with path …” lines) and with
`UNUserNotificationCenter` and `NSUserNotificationCenter` swizzled in
SelfTest, in launches that only open a page.

With Chromium's defaults, every launch, `.embedded` and `.chrome` alike,
connected the app's bundle and `<App> Helper (Alerts)` to `usernoted`
within a second of start-up, before any page used notifications: Chromium
gets `NSUserNotificationCenter.defaultUserNotificationCenter` in the
browser process and starts the Alerts helper (for about 70 ms) as it sets
up system notifications for the default profile. At an app's first
launch that is what shows two “would like to send notifications”
banners. What stops it:

| Change | App connects | Alerts helper starts | Web notifications |
|---|---|---|---|
| None | Yes | Yes | Through Notification Center |
| `--disable-features=SystemNotifications` | No | No | Shown, in Chromium's own popups (`onshow` fires, permission `granted`) |
| `--disable-features=NativeNotifications` | No | No | The same |
| `--disable-notifications` | Yes | Yes | `Notification` is undefined |
| `LazyKeyedServiceInstantiation` features on | Yes | Yes | — |

CefKit disables `SystemNotifications` unless
`services.systemNotifications` is `.automatic`. No switch was found that
keeps system notifications and defers the authorization request until a
page shows one.

Other prompts, from `tccd`, `locationd` and `mDNSResponder` in the same
launches: TCC saw only preflights (camera and microphone in both presets,
Input Monitoring in `.chrome`), which never prompt; `locationd` registered
a location client of the app's, with no authorization request; nobody
browsed for Bonjour services, so Local Network was not asked for; there
was no Bluetooth request. The keychain is the mock keychain in ad hoc
builds.

## Building with SwiftPM and with Xcode: one tool, two front ends

Measured and decided on 2026-11-14 with Xcode 27.2 and Swift 6.4, by
setting up a new app each way from scratch (an `swift package init` app,
and a SwiftUI app project as Xcode 27's template makes it, both depending
on a local CefSwift).

**What each track needed before.** SwiftPM: seven steps (init, platforms
and dependency in Package.swift, the app, `cef bundle` with its two
`--allow-…` options, open, `.gitignore`), one surprise (`swift run` cannot
start Chromium) and one wrong hint (the bundle's "check it with" line left
out the options `cef doctor` needs). Xcode: the build succeeded and the app
stopped at launch with `CefError.frameworkNotFound`, whose fix named
`swift package cef bundle`. Nothing described the Xcode track beyond "build
the same two products with the same link order"; making it work by hand
meant downloading and converting CEF, linking the helper as the plugin
does, writing five helper apps and their Info.plists, signing inside out,
and finding out, one launch at a time, that:

- Xcode's template turns on App Sandbox, in which Chromium stops at launch
  (`bootstrap_check_in …MachPortRendezvousServer…: Permission denied`;
  [bundling](bundling.md#app-sandbox));
- the template's User Script Sandboxing keeps a Run Script phase from
  reading anything it did not declare or writing into the app;
- Release builds are universal by default, and a CEF distribution has one
  architecture;
- Xcode turns the hardened runtime off for ad hoc Debug builds but keeps
  it for Release, where library validation refuses an ad hoc framework (and
  Xcode's own `.debug.dylib`, had the Debug build kept it);
- Xcode signs the app last, so the parts inside must be signed before, in
  a phase after Xcode's own; and Xcode's resource bundles
  (`CefSwift_CefKit.bundle`, with an Info.plist and no code) are sealed by
  the app's signature, not signed on their own.

What worked without help: Xcode builds the package, copies its resource
bundles to `Contents/Resources`, where `Bundle.module` finds them, and the
Debug build's `.debug.dylib` and `__preview.dylib` do not disturb the
helpers, whose names derive from `EXECUTABLE_NAME`.

**Where the shared logic lives.** It was Swift in the command plugin, which
only SwiftPM can run. The options:

| Option | For | Against | Chosen |
|---|---|---|---|
| An executable tool target that the plugin and an Xcode Run Script phase both run | One implementation; the convention of SwiftLint, swift-format and DocC (a plugin over a tool); testable as a library target | The Xcode phase builds the tool with SwiftPM once per derived-data folder (about a minute) | Yes: `CefBundling` (library) and `cefswift` (tool) |
| A SwiftPM build tool plugin on the app target | Xcode runs it with no script | A build tool plugin writes only into its own work directory; its outputs become sources or resources (`Contents/Resources`), never `Contents/Frameworks`, and it runs before the app is linked and signed. It cannot add helper apps to the app or sign them, in Xcode 27 as before | No |
| An Xcode command plugin (XcodeProjectPlugin) | Runs from Xcode's menu | Manual, not part of a build | No |
| Helper apps as Xcode targets | Xcode signs and embeds them | Five targets, Info.plists and Copy Files phases in every app project; helper names follow the app's, so they cannot come with the package | No |
| Prebuilt helpers shipped in a framework or XCFramework | Xcode embeds them | Chromium finds helpers as `<executable> Helper (…)` in the app's `Contents/Frameworks`, their bundle identifiers follow the app's, and they must carry the app's signature for library validation, while Embed & Sign signs the framework, not the apps inside it | No |
| CEF as an XCFramework binary target (pull request #27) | Xcode embeds, signs and links the framework itself; universal builds | Needs a release asset per CEF version; does not cover the helpers | The seam: `CEF_EMBED_FRAMEWORK = NO` |

The phase's script builds the tool and runs `cefswift embed`, which reads
Xcode's build settings from its environment, as Xcode's own tools do; the
plugin runs `cefswift bundle` with the facts only it has (the product's
build products, from the package graph). Both then use `CefEmbedder` for
the framework, startup library and helpers, `DistributionPlan` for
Info.plists and entitlements, the same signer, and `cef doctor`'s checks;
the phase reports those as `error:` and `warning:` lines, with
`file:line:` for a `cefapp.json` key, which Xcode puts in its Issue
navigator.

**Settings: each track's own place.** Xcode has a build setting for most of
what `cefapp.json` holds (bundle identifier, version, signing, hardened
runtime, entitlements, usage descriptions); the phase reads those, and adds
`CEF_…` settings, each named after the `cefapp.json` key it matches, for
what only CefSwift has (locale packs, SwiftShader, capabilities, helper
entitlements, the CEF cache). The app's entitlements stay Xcode's: the
phase derives the helpers' from them (get-task-allow, camera, microphone)
rather than asking for them twice, and stops the build, naming the
setting, when one the plan needs is missing. A project built both ways
points `CEF_APP_CONFIG` at its `cefapp.json`.

**Conventions followed.** Apple's guidance for nested code: sign inside out,
each item before what contains it, never with `--deep`; nested helpers in
`Contents/Frameworks` (as Chrome's are) with their own bundle identifiers
and `LSUIElement`; the app's signature last, by Xcode in Xcode. Sparkle
ships its helpers (Autoupdate, its XPC services) generic and signed inside
its framework; Chromium's cannot be generic, since their names, identifiers
and entitlements follow the app's. Electron's and
swift-bundler's packagers assemble the bundle outside Xcode, as `cef
bundle` does for SwiftPM. Helpers of an App Sandbox app would take
`com.apple.security.inherit`; the App Sandbox is not supported with
official CEF builds, so both tracks refuse it instead.

**Previews.** Xcode's previews run the app's code in a process of Xcode's;
Chromium cannot start its helpers there. `CefSwiftApp` skips Chromium when
`XCODE_RUNNING_FOR_PREVIEWS` is 1, and `CefWebView` shows a placeholder
while the runtime has not started, so a view with a web view previews
without crashing. Checked by launching the Debug build of the Xcode example
with that variable set: it stays up with its window and no helper
processes. Xcode's preview canvas itself was not exercised: it has no
command-line entry point.

**Cost.** The Xcode example (`Scripts/check-xcode-example.sh`: Debug and
Release builds, archive, export, three smoke launches, `cef doctor`) took
156 to 159 s in three runs from clean derived data on an M3, including Xcode's own
build of CefSwift twice (build and archive); an incremental build of the
example takes 3.7 s, of which the phase is 2.0 s, most of it `cef doctor`'s
checks: it skips SwiftPM when the tool and helper are newer than their
sources, since SwiftPM's own checks (three builds, each with its own linker flags,
and their `--show-bin-path`) took 15.7 s to find nothing to do.
