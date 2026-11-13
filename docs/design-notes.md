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
| Browser example, one tab, `.browser`, before | 8 | 371 MB | 559 ms |
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
apps open, the second of two runs after. Main-thread time and allocations
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
| 5 000 history entries (synthetic, history host) | 152 / 172 ms; main thread 52 ms | 65 / 84 ms; main thread 4.5 ms | 205 000 → 20 100 |
| Bookmark tree of 10 000, host | 511 / 3 512 ms; main thread 122 ms | 288 / 322 ms; main thread 27 ms | 331 000 → 20 200 |
| Bookmark tree of 10 000, `Bookmarks` file | 36 ms, on the main thread | FILE_AFTER | 90 200 → FILE_ALLOCS |

Where the large results' time went, per call:

| 5 000 history entries | Before | After |
|---|---|---|
| Value → wire in the renderer (`V8Wire`), IPC | 98 ms | 10 ms (plus the JavaScript encoder, inside the renderer's 48 ms with building the records) |
| Decoding in Swift | 45 ms (wire → `CefJSON` → JSON text → `JSONDecoder`), main thread | 6.9 ms, wire → records, off the main thread |

Under load:

| Load | Before | After |
|---|---|---|
| 200 queries 20 ms apart, each cancelling the one before | cancelled queries resumed about 5 ms after their cancel; main thread busy 20% | 0.10 ms (p50, 0.24 ms p95); 13% |
| The same through `results(following:)` | – | a result for each text 1.7 ms after it (p50), complete for the last text 117 ms after it; nothing from superseded texts |
| 1 000 concurrent calls across the hosts | 730 ms; favicons p50 484 ms | 209 ms; favicons 202 ms |
| 10 000 bookmark adds, 32 in flight | 5.1 s; 9 550 change events delivered | 2.9 s; 599 |
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
- `chrome.bookmarks.getTree()` itself takes 250 ms for 10 000 bookmarks,
  in Chromium's extension bindings. `children(of:)` reads one folder at a
  time, and the `Bookmarks` file serves trees while the host is closed.
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
the usual idle timeout. The graph also has `has_nonempty_beforeunload`,
which could replace the DevTools Protocol `beforeunload` check for Alloy
browsers; that is neither done nor measured.

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
