# Contributing

## Build and test

```sh
swift build
swift test
```

The examples' own logic (the Browser example's Memory Saver policy) has
unit tests in the Examples package:

```sh
swift test --package-path Examples
```

CI also runs the unit tests under the sanitizers:

```sh
swift test --sanitize=thread
swift test --sanitize=address --build-system native
```

The default build system links the helper-startup library without the
Address Sanitizer runtime, so that one uses the native build system.

The Command Line Tools are enough; Xcode is not required, except for the
Xcode example. `CefKitTests`
covers CefKit and its AppKit views, `CefPasskeysTests` the passkeys
library, `CefChromiumTests` the CefChromium library, `CefKitAppKitTests` hosts a browser through CefKit's public API
alone (no SwiftUI), and `CefBundlingTests` the bundling logic: signing,
entitlements, bundle assembly, `cef doctor`, and the Xcode build phase
driven by a fake Xcode environment; none of them starts Chromium.

The bundling logic is the `CefBundling` library target, which the
`cefswift` tool (`Sources/CefSwiftTool`) wraps. SwiftPM lets a command
plugin depend only on executable and binary targets, which it runs as
tools, so the `cef` plugin (`Plugins/CefPlugin`) runs `cefswift` rather
than linking `CefBundling`, as the Xcode build phase does
(`Scripts/xcode-embed.sh`). Keep the plugin to what only a plugin can do:
find products and `CEF_VERSION.json` in the package graph and build with
SwiftPM. Everything about the bundle goes in `CefBundling`, so that both
tracks get it.

The loader tests run only when `CEF_FRAMEWORK_PATH` names a CEF framework,
either the `.framework` directory or the binary inside it. They load it in
`CefLoaderProbe` (`Tests/CefLoaderProbe`), a process of its own: as it
loads, the framework swaps the default malloc zone, and a free on another
thread at that moment traps, so no test loads it into the test process.
Download one with the plugin and point at it with an absolute path:

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

The other products are `Gallery`, `Minimal`, `Compat` and `SelfTest`. The plugin keeps its cache
in the invoking package, so the Examples package downloads CEF into
`Examples/.cef/`. [Examples/README.md](Examples/README.md) lists the launch
arguments.

`Scripts/check-xcode-example.sh` builds the Xcode example
(`Examples/Xcode`) with `xcodebuild`, Debug and Release, archives and
exports it, and runs each build's smoke test; run it after changing
`CefBundling`, `Scripts/xcode-embed.sh` or the example. It needs Xcode,
keeps CEF in `Examples/Xcode/.cef/` (clone `Examples/.cef` there with
`cp -Rc` to skip the download) and its derived data in
`Examples/Xcode/build/`.

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
  skips, and SKIP lines without a category, as failures, except those
  whose names start with an entry of `SELFTEST_EXPECTED_SKIPS` (separated
  by semicolons), which CI uses for what a virtual machine cannot run.
- `SELFTEST_ISOLATED=1` runs each group in a process of its own, with its
  own cache directory, and kills one that outlives its deadline; no group
  then depends on what an earlier one left behind. It takes longer, and CI
  uses it.
- `SELFTEST_JSON=<path>` writes every result, each group's time and the
  skip counts as JSON.

## Measure idle footprint

A small footprint is one of the project's goals, so measure before merging
anything that runs at launch or while idle: a new host view or layer, an
observer, a timer, a profile, a helper process or a page Chromium keeps
alive. Bundle the Minimal and Browser examples from your branch and from
the branch you merge into, and measure them one after the other on the
same Mac:

```sh
swift package --package-path Examples --allow-writing-to-package-directory \
  --allow-network-connections all cef bundle --product Minimal --output dist
Scripts/measure-footprint.py Examples/dist/Minimal.app --runs 5
```

The script prints the median of each kind of run and the footprint of
each process kind. Numbers drift by a few MiB within minutes on the same
Mac (the GPU process most), and by more between sessions, so compare
builds measured in alternation, not with a figure from another day; and
compare per process, since a change usually shows in one process. Note
the power source and the machine's load. CI's Footprint step measures
both examples on its virtual machine, writes the numbers to the run
summary, and fails only above wide bounds that a gross regression crosses.

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
that nothing but process-lifetime objects is alive. A group's line waits
for its browsers to finish closing only when something other than the
process-lifetime objects and an open service host is left. The browsers
left discarded for the quit open after the final check.

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
- Text a built-in sheet shows is `String(localized: "…", bundle: .cefKit,
  comment: "…")` (`.cefPasskeys` in CefPasskeys), with the same key and
  comment in the target's `Resources/en.lproj/Localizable.strings`; where
  AppKit or Chromium already has the string (NSAlert's lone OK, the panels,
  Chromium's menu items), use theirs. String Catalogs need Xcode's
  `xcstringstool`, which the Command Line Tools lack, so the strings are
  `.strings` files.
- Keep pull requests focused, and run `swift test` before sending one.

## Naming

Public API follows the [Swift API Design
Guidelines](https://www.swift.org/documentation/api-design-guidelines/), with
these conventions on top. Follow them for new API, so that the library keeps
reading as one.

- **CEF's and Chromium's terms win over product words.** CefSwift embeds
  CEF; it is not a browser framework, so a name says what CEF or Chromium
  calls the thing, or what it turns on: `CefWindow` (CEF's `cef_window_t`),
  the `.chrome` runtime preset (Chrome's services), `onChromeTab` (tabs
  Chromium opens in its own window), `webAuthnAuthenticators`. Words such
  as "browser window" or "browser preset" describe a product an app builds.
- **Principal types** carry the `Cef` prefix: `CefRuntime`, `CefBrowser`,
  `CefWindow`, `CefProfile`, `CefDevTools`. So do types several owners
  share, and the values delegate methods take and return (`CefNavigationAction`,
  `CefDownload`, `CefPermissionRequest`).
- **Types that belong to one owner nest in it**, without the prefix:
  `CefBrowser.Configuration`, `CefBrowser.FindResult`,
  `CefRuntime.ProcessPolicy`, `CefChromiumSurface.Anchor`,
  `CefPermissionRequest.Kinds`. A runtime-wide option nests in `CefRuntime`,
  a browser option in `CefBrowser`, a window option in `CefWindow`. So
  does a value only one type produces or takes: `CefHistory.Entry`,
  `CefHistory.TopSite`, `CefAutocomplete.Suggestion`, `CefMediaRouter.Sink`,
  `CefBridge.Call`, `CefChromiumSurface.Policy`.
- **`Configuration`** is the creation-time value bag of a principal type:
  `CefRuntime.Configuration`, `CefBrowser.Configuration`,
  `CefWindow.Configuration`, `CefBrowser.PDFConfiguration` for one
  operation. Its property is `configuration`, and so is the initializer
  label. Never `Options`.
- **Groups** inside a configuration are named for their topic, without a
  suffix (`services`, `network`, `privacy`, `security`, `credentials`,
  `chromeToolbar`, `contextMenu`), and an option inside a group nests in the
  group (`Network.Preloading`, `Services.ProtectedMedia`).
- **An option's type is named for its property**: `rendering: Rendering`,
  `localization: Localization`, `userAgent: UserAgent`. When the option
  chooses who answers or when CefKit acts, the type ends in `Policy`
  (`clientCertificates: ClientCertificatePolicy`, `unresponsivePages: UnresponsivePagePolicy`,
  `safeStorage: SafeStoragePolicy`); a live runtime knob of that kind is a
  `…Policy` property too (`CefRuntime.shared.energyPolicy`).
- **Case names**: `.automatic` leaves a choice to Chromium (or to the user in
  `chrome://settings`), `.disabled` turns a facility off; not `.default`,
  `.standard`, `.off` or `.disable`. A shared on-or-off choice is
  `CefRuntime.Setting`.
- **Delegates** take the asking object first, `browser(_:…)`. A method that
  returns a choice is `decide<Thing>For:` and returns a `Cef<Thing>Decision`
  (`decidePolicyFor:` → `CefNavigationDecision`, `decideWindowOpenFor:` →
  `CefWindowOpenDecision`, `decidePasskeyFor:` → `CefPasskeyDecision`); an
  event is `did…`/`…Did…`. A request a native sheet can answer has a
  `Cef…Presenter`, whose `present` shows that sheet and returns the answer.
  `credentialFor:`, `shouldProceedDespite:`, `selectClientCertificateFor:`
  and `browserPageIsUnresponsive` are deliberately not `decide…For:`: each
  supplies a value (a credential, a certificate, whether to proceed, what to
  do with a hung page) rather than allowing or denying a request, so do not
  rename them or wrap their answers in new enums for uniformity.
- **Optional modules** (`CefPasskeys`, `CefChromium`) depend on CefKit
  (and on CefKit's own C layer, `CCef` and `CefBase`, only for Chromium's
  identifiers) and name their types as CefKit does
  (`CefPasskeyController`, `CefPasskeyStore`, `CefBookmarks`).
  CefKit never names them: a module plugs in through an extension point
  (`CefBrowserAttachment`, per-profile or
  per-window module state, a Chrome-command interceptor, the service-host
  engine) and gets its own delegate (`CefPasskeyDelegate`) rather than
  members on `CefBrowserDelegate`. What it needs from CefKit and apps
  should not use is `package`, not public; what no other module uses any
  more goes back to internal.
- **What an app could write itself stays out of the library**: UI copy
  (names to show for permissions), product defaults, and heuristics for
  when to use a capability belong in the app, or in `Examples` to show
  how. The library holds what an app cannot write against its public API
  (what calls the CEF C API, hooks Chromium, or works around a CEF or
  Chromium limit), plus the defaults an embedder cannot ship without: the
  built-in sheets and presenters behind delegate methods, which an app
  replaces by implementing the method.
- **Booleans** read as assertions: `isRunning`, `isDiscarded`,
  `showsToolbarButtons`, `usesSafeBrowsing`.
- **No abbreviations** beyond terms of art (`URL`, `PDF`, `DNS`, `HTTPS`,
  `JSON`, `CDM`). A property holding a full address is `url`, not `origin`.
- **One way to do a thing.** Remove a convenience that duplicates another
  API instead of keeping both, and drop options the host overrides.
- **Test hooks** are `@_spi(Testing)`, never plain `public`.
- **Plain values the library hands out** (a history entry, a load error,
  a task manager row) have a public memberwise initializer, documented
  "for previews and tests", labelled as their properties. A value that
  means something only coming from CEF (a request bound to a callback, a
  browser reference, a Chromium node's identifier) has none.
- **Files** are named for the type they declare, `Type+Concern.swift` for an
  extension; split a file that passes about 600 lines along its concerns.

## Reporting issues

Open a GitHub issue with your macOS version, Mac architecture, the pinned CEF
version (`swift package cef info`), and steps to reproduce. For runtime bugs,
attach Chromium's log: set `CefRuntime.Configuration.logSeverity = .verbose` and
`logFile`.
