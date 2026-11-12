# Contributing

## Build and test

```sh
swift build
swift test
```

CI also runs the unit tests under the sanitizers:

```sh
swift test --sanitize=thread
swift test --sanitize=address --build-system native
```

The default build system links the helper-startup library without the
Address Sanitizer runtime, so that one uses the native build system.

The Command Line Tools are enough; Xcode is not required. `CefKitTests`
covers CefKit, `CefSwiftUITests` the views, and `CefPluginTests` the
plugin's signing, distribution and bundle-assembly logic; none of them
starts Chromium.

`CefPluginTests` compiles `Plugins/CefPlugin/Distribution` through a
directory symlink (`Tests/CefPluginTests/Distribution`). SwiftPM lets a
command plugin depend only on executable and binary targets, which it runs
as tools, not on a library target, and a test target cannot depend on a
plugin; so the plugin and its tests cannot share that code through a
regular target. Keep `Distribution` free of `PackagePlugin` and of running
tools: it is the plugin's pure logic, and the rest of the plugin runs
`swift build`, `codesign` and the other tools around it.

The loader tests run only when `CEF_FRAMEWORK_PATH` names a CEF framework,
either the `.framework` directory or the binary inside it. Download one with
the plugin and point at it with an absolute path:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all cef download
CEF_FRAMEWORK_PATH="$PWD/.cef/dist/<version>_macosarm64_minimal/Release/Chromium Embedded Framework.framework" \
    swift test
```

`swift package cef info` prints the pinned version and the cache's state.
Tests that need a downloaded framework or a repository checkout are
conditioned with `.enabled(if:)`, as in `LoaderTests`; do the same for new
ones.

## Run the examples

The examples are a separate package in `Examples/` and need macOS 15. From
the repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Browser
open Examples/dist/Browser.app
```

The other products are `Showcase` and `SelfTest`. The plugin keeps its cache
in the invoking package, so the Examples package downloads CEF into
`Examples/.cef/`. [Examples/README.md](Examples/README.md) lists the launch
arguments.

## Verify with SelfTest

SelfTest checks CefSwift against the real Chromium runtime: windowed and
offscreen browsers, the bridge, profiles and preferences, Chrome-style
windows, popups, downloads, `beforeunload`, renderer crashes, tab
discarding, Chromium's own interface, swipe navigation, bookmarks, history,
autocomplete, passkeys and a clean quit. Bundle and run it before sending a
change that touches anything CEF does:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product SelfTest
Examples/dist/SelfTest.app/Contents/MacOS/SelfTest
```

It prints one `PASS`, `FAIL` or `SKIP` line per check, a `SUMMARY` line,
and exits with the number of failures. Keep the screen unlocked while it
runs; the offscreen painting check is skipped when its window cannot be
seen. CI runs it on every pull request. Add a check in
`Examples/Sources/SelfTest` for new behavior that crosses into CEF.

- `SELFTEST_ONLY=passkeys,discard` runs only the named groups of checks
  (`SelfTest.checkGroups` lists them), which is quicker while you work on
  one area.
- Each group has a deadline (`SelfTest.groupDeadlines`, 60 seconds unless
  listed). A group that outlives it fails with its name, and the next
  group runs. A last-resort watchdog exits with 124.
- A check that cannot run reports `SelfTest.skip(_:because:_:)` with a
  category: `.environment` when this machine could not run it (offline, an
  occluded window, an assistive app running), `.limitation` when CEF cannot
  do what it needs. `SELFTEST_STRICT=1`, which CI sets, counts environment
  skips, and SKIP lines without a category, as failures.
- `SELFTEST_ISOLATED=1` runs each group in a process of its own, with its
  own cache directory, and kills one that outlives its deadline; no group
  then depends on what an earlier one left behind. It takes longer, and CI
  uses it.
- `SELFTEST_JSON=<path>` writes every result, each group's time and the
  skip counts as JSON.

## Measure threads, lifecycle and frames

`SelfTest -benchmark <name>` runs one measurement instead of the checks
and prints `bench` lines: `requests` (500 small responses and a 200 MB one
through a scheme handler: load time, main-thread busy time, peak memory),
`lifecycle` (CPU time of an animated page in each host while visible,
covered, minimized and with the app hidden), `frames` (offscreen frame
rate, pacing, mouse-to-paint latency and CPU, with Chromium's timer and a
display link; `-frameTiming <label prefix>` runs one), `probes`
(freezing and App Nap), `compositor` (what the offscreen view presents;
`-compositorPage damage` for a page that changes one block per frame,
`-compositorCopy whole` to copy whole frames), `bridge`, `evaluate` and
`codec` (round trips and allocations of bridge calls and evaluations, and
the codecs alone), `axingest` (taking a large accessibility tree from
CEF) and `devtools` (DevTools events nobody listens to). Allocations are
the app's main thread's, counted through `malloc_logger`. Run them with
nothing else on screen; note the power source and Low Power Mode, which
change the numbers.

SelfTest removes its own cache directories in `$TMPDIR` when it exits, and
those of earlier runs whose process is gone. With the live-object census
on, it prints a `CENSUS` line after each group and checks before quitting
that nothing but process-lifetime objects is alive.

## Measure web compatibility

`Scripts/compat-matrix.py` loads a local probe page, and with `sites` a few
public bot-detection test pages, in each kind of host with each CefSwift
feature on by itself, and in Google Chrome for comparison. Run it after a
CEF update and after changing anything a page can observe; the guide's
[Compatibility with bot protection](docs/guide.md#compatibility-with-bot-protection)
records what it shows. SelfTest's `compatibility` group checks the same
readings on a local page. Load public pages a handful of times, not in a
loop.

## Check the documentation samples

`Scripts/check-doc-samples.py` compiles every Swift block in `README.md`
and `docs/` against this checkout, for macOS 14; CI runs it. Run it after
changing public API or a sample. Names an app would define (`browser`,
`openTab`, …) come from stubs in the script; add one there when a sample
needs it, never a stub of CefSwift API. A sample that needs a later macOS
says so in a comment (`// macOS 15`).

## Regenerate the C bridge

`Scripts/generate-bindings.py` writes `ccef_capi.h` and `ccef_symbols.h` in
`Sources/CCef/include` from the vendored headers, at the `CEF_API_VERSION`
pinned in `ccef_config.h`. Never edit those files by hand.

```sh
Scripts/generate-bindings.py           # regenerate
Scripts/generate-bindings.py --check   # verify, as CI does
```

Do not edit the vendored headers in `Sources/CCef/include/include` or
`CEF_VERSION.json` by hand either; `Scripts/update-cef.py` refreshes them.
[Automation](docs/automation.md) describes CEF updates and moving the API
pin.

## Coding notes

- Swift 6 language mode. Prefer `@MainActor` to locks. No force-unwraps in
  library code. Doc comments on public API.
- Keep pull requests focused, and run `swift test` before sending one.

## Reporting issues

Open a GitHub issue with your macOS version, Mac architecture, the pinned CEF
version (`swift package cef info`), and steps to reproduce. For runtime bugs,
attach Chromium's log: set `CefConfiguration.logSeverity = .verbose` and
`logFile`.
