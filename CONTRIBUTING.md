# Contributing to CefSwift

Thanks for helping build the CEF embedding macOS deserves.

## Ground rules

- Read `DESIGN.md` first — it is the binding contract for module boundaries
  and public API. Changes to the public surface need a design discussion
  before code.
- Swift 6 language mode, `@MainActor` discipline over locks, no force-unwraps
  in library code, doc comments on all public API.
- Everything must work with **Command Line Tools only** (`swift build`,
  `swift test`, the `cef` plugin) — never assume Xcode.

## Dev setup

```sh
git clone https://github.com/rajaniraiyn/CefSwift.git && cd CefSwift
swift build && swift test

# Download CEF (cached in .cef/, ~120 MB once) and run the example browser:
swift package --allow-writing-to-package-directory --allow-network-connections all cef download
swift package --package-path Examples --allow-writing-to-package-directory \
              --allow-network-connections all cef bundle --product Browser
open Examples/dist/Browser.app
```

## Pull requests

- Keep PRs focused; include tests where the change is testable without the
  CEF runtime (unit tests must not require a downloaded framework — use
  `XCTSkip` if one is needed).
- CI must pass: build, tests, example bundling, and the CEF launch smoke test.
- CEF version bumps are automated (`docs/automation.md`) — don't hand-edit
  `CEF_VERSION.json` or the vendored headers in `Sources/CCef/.../include`
  unless you're fixing the automation itself.

## Reporting issues

Include macOS version, architecture, the pinned CEF version
(`swift package cef info` or `CEF_VERSION.json`), and Chromium's log
(`CefConfiguration.logSeverity = .verbose`, `logFile`) when relevant.
