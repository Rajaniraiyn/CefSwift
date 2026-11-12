# Contributing

## Build and test

```sh
swift build
swift test
```

The Command Line Tools are enough; Xcode is not required. `CefKitTests`
covers CefKit, `CefSwiftUITests` the views, and `CefPluginTests` the
plugin's signing and distribution logic; none of them starts Chromium.
`CefPluginTests` compiles `Plugins/CefPlugin/Distribution` through a
directory symlink, since a test target cannot depend on a plugin, so keep
that directory free of `PackagePlugin` and of running tools.

SwiftPM fetches the CEF framework that `Package.swift` pins from its GitHub
release ([The framework](docs/bundling.md#the-framework)). To build without
that release, for example on a branch that moves CEF before its framework is
published, repackage the official distributions locally and point the
package at the result:

```sh
Scripts/package-cef.py --no-zip        # downloads both minimal distributions (~280 MB) once
export CEFSWIFT_LOCAL_FRAMEWORK=1      # use .cef/xcframework instead of the release asset
```

Keep the variable set for every `swift` command in that shell, including the
plugin's: SwiftPM caches the evaluated manifest by its environment.

The loader tests run only when `CEF_FRAMEWORK_PATH` names a CEF framework,
either the `.framework` directory or the binary inside it, by an absolute
path. The XCFramework SwiftPM resolved has one:

```sh
CEF_FRAMEWORK_PATH="$PWD/.cef/xcframework/ChromiumEmbeddedFramework.xcframework/macos-arm64_x86_64/Chromium Embedded Framework.framework" \
    swift test
```

(Without `CEFSWIFT_LOCAL_FRAMEWORK`, SwiftPM extracts the XCFramework under
`.build/artifacts/`.)
`swift package cef info` prints the framework's version and where it came
from. Tests that need a framework or a repository checkout are conditioned
with `.enabled(if:)`, as in `LoaderTests`; do the same for new ones. Test
targets do not depend on the `ChromiumEmbeddedFramework` product: a test
bundle that links it cannot load.

## Run the examples

The examples are a separate package in `Examples/` and need macOS 15. From
the repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Browser
open Examples/dist/Browser.app
```

The other products are `Showcase`, `Minimal`, `Compat` and `SelfTest`. The
Examples package depends on the checkout by path, so it uses the same
framework. [Examples/README.md](Examples/README.md) lists the launch
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

It prints one `PASS`, `FAIL` or `SKIP` line per check and exits with the
number of failures, or 124 if it does not finish within 240 seconds. Keep the
screen unlocked while it runs; the offscreen painting check is skipped when
its window cannot be seen. CI runs it on every pull request. Add a check in
`Examples/Sources/SelfTest` for new behavior that crosses into CEF.
`SELFTEST_ONLY=passkeys,discard` runs only the named groups of checks
(`SelfTest.checkGroups` lists them), which is quicker while you work on one
area.

## Measure web compatibility

`Scripts/compat-matrix.py` loads a local probe page, and with `sites` a few
public bot-detection test pages, in each kind of host with each CefSwift
feature on by itself, and in Google Chrome for comparison. Run it after a
CEF update and after changing anything a page can observe; the guide's
[Compatibility with bot protection](docs/guide.md#compatibility-with-bot-protection)
records what it shows. SelfTest's `compatibility` group checks the same
readings on a local page. Load public pages a handful of times, not in a
loop.

## Regenerate the C bridge

`Scripts/generate-bindings.py` writes `ccef_capi.h` and `ccef_symbols.h` in
`Sources/CCef/include` from the vendored headers, at the `CEF_API_VERSION`
pinned in `ccef_config.h`. Never edit those files by hand.

```sh
Scripts/generate-bindings.py           # regenerate
Scripts/generate-bindings.py --check   # verify, as CI does
```

Do not edit the vendored headers in `Sources/CCef/include/include`,
`CEF_VERSION.json` or the `cefFramework` pin in `Package.swift` by hand
either; `Scripts/update-cef.py` and `Scripts/package-cef.py --write`
refresh them.
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
