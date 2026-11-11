# Contributing

## Build and test

```sh
swift build
swift test
```

Command Line Tools alone is enough — Xcode is not required.

## Run the examples

```sh
# Download CEF once (cached in .cef/, ~120 MB).
swift package --allow-writing-to-package-directory \
              --allow-network-connections all cef download

# Build and run an example.
swift package --package-path Examples \
              --allow-writing-to-package-directory \
              --allow-network-connections all \
              cef bundle --product Browser
open Examples/dist/Browser.app
```

Other example products: `Showcase`, `SelfTest`.

## Coding notes

- Swift 6 language mode. `@MainActor` over locks, no force-unwraps in library code, doc comments on public API.
- The C bridge is generated: `Scripts/generate-bindings.py` writes `ccef_capi.h` and `ccef_symbols.h` from the vendored headers, exposing the whole CEF C API. Never edit those two files by hand.
- `Examples/Sources/SelfTest` checks behavior against the real Chromium runtime. Add a check there for anything that crosses into CEF; bundle and run it before sending a change.
- Don't hand-edit the vendored headers under `Sources/CCef/include/include` or `CEF_VERSION.json` — `Scripts/update-cef.py` refreshes both.

## Pull requests

- Run `swift test` before submitting.
- Keep PRs focused. Tests that need a downloaded CEF framework should `XCTSkip` when one isn't present.

## Reporting issues

Open a GitHub issue with: macOS version, architecture, pinned CEF version (`swift package cef info`), and reproduction steps. For runtime bugs, attach Chromium logs (`CefConfiguration.logSeverity = .verbose`, `logFile`).
