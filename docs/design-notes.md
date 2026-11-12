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

## Memory settings measured and not used

These were measured on the Minimal example and are not used: they saved
nothing on an idle page, cost more than they saved, or save the same as
`memoryPolicy = .reduced`.

- `--js-flags=--lite-mode` and `--js-flags=--optimize-for-size`: no
  difference while idle; both slow JavaScript down.
- `--disable-extensions`, `--disable-spell-checking`, and turning off
  optimization-guide model downloads, Safe Browsing real-time lookups,
  certificate-transparency updates and preloading: no difference.
- `--disable-gpu-compositing`: 10 MB more.
- `--renderer-process-limit=1` and `--disable-site-isolation-trials`: save
  the spare renderer, as `.reduced` does; the second also gives up site
  isolation.
- `--enable-low-end-device-mode`: saves the spare renderer and 3 MB more in
  the GPU process, and lowers rendering quality.

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
