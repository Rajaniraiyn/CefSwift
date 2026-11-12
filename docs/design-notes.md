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
launch to the first `didFinishLoad`). Another build ran on the same Mac at
the time, so run-to-run spread is wider than in the guide's table.

| App | Sandbox | Launch | Memory (range) |
|---|---|---|---|
| Minimal (`.embedded`) | On | 322 ms | 108.6 MiB (102.7–113.0) |
| Minimal (`.embedded`) | Off (`-sandbox NO`) | 315 ms | 110.6 MiB (90.2–118.2) |
| Browser (`.browser`) | On | 440 ms | 173.2 MiB (171.1–179.3) |
| Browser (`.browser`) | Off (`--no-sandbox`) | 384 ms | 162.0 MiB (160.9–165.1) |

In an earlier pair of Minimal runs, per process: GPU 24.5 MiB sandboxed
against 21.0 MiB, network service 10.9 against 7.7 MiB, the others within
1 MiB. The sandbox costs a few MiB in the GPU and network processes and
some tens of milliseconds at launch; SelfTest passes every check with it
on (491 checks, none skipped). It is on by default in every preset.
