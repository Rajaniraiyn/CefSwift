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
