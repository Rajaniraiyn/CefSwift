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

Other example products: `Gallery`, `Launcher`.

## Coding notes

- Swift 6 language mode. `@MainActor` over locks, no force-unwraps in library code, doc comments on public API.
- The C bridge dlsym-resolves CEF symbols from one X-macro list: `Sources/CCef/include/ccef_symbols.h`. To wire a new CEF C API call, add one `CCEF_SYM(...)` line there and write the Swift wrapper in `Sources/CefKit`.
- `Scripts/check-symbols.sh` validates that every listed symbol exists in the downloaded CEF binary. CI runs it; run it locally before sending a PR that touches `ccef_symbols.h`.
- Don't hand-edit the vendored headers under `Sources/CCef/.../include` or `CEF_VERSION.json` — both are refreshed by `Scripts/cef-update.sh`.

## Pull requests

- Run `swift test` before submitting.
- Keep PRs focused. Tests that need a downloaded CEF framework should `XCTSkip` when one isn't present.

## Reporting issues

Open a GitHub issue with: macOS version, architecture, pinned CEF version (`swift package cef info`), and reproduction steps. For runtime bugs, attach Chromium logs (`CefConfiguration.logSeverity = .verbose`, `logFile`).
