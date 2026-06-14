# Contributing to CefSwift

Thanks for helping build the CEF embedding macOS deserves.

## Ground rules

- Read `DESIGN.md` first — it documents the three hosting modes and why each
  alternative was ruled out. Changes to the public surface need a design
  discussion before code.
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

On a Command Line Tools–only machine (no Xcode), make sure the active
developer directory is the CLT — prefix commands with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` if `xcode-select -p`
points elsewhere. To run the test suite there (the XCTest/Testing frameworks
live inside the CLT):

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## The C bridge: vendored headers and the symbol table

`Sources/CCef` contains two very different kinds of files:

- **Vendored CEF headers** (the inner `include/` tree, BSD-licensed — see
  `Sources/CCef/LICENSE.CEF.txt`). These are **committed on purpose**: they are
  required to compile the package on a machine that has never downloaded CEF,
  and they are replaced wholesale by the auto-update pipeline
  (`Scripts/cef-update.sh`). Never hand-edit them.
- **CefSwift-authored bridge files** (`ccef_loader.c`, `ccef_symbols.h`,
  `ccef_config.h`, `ccef_string.*`, `ccef_object.*`, `CCef.h`,
  `module.modulemap`). These are normal source files.

### Adding a CEF C API symbol to the bridge

The loader dlsym-resolves every symbol it uses from one X-macro list, so a new
symbol is a one-liner plus its Swift wrapper:

1. Add one `CCEF_SYM(returnType, cef_name, (params), (args))` — or
   `CCEF_SYM_VOID(...)` for void returns — line to
   `Sources/CCef/include/ccef_symbols.h`. The trampoline, pointer table, and
   dlsym resolution in `ccef_loader.c` are generated from that line; there is
   nothing else to write in C.
2. Add/extend the Swift wrapper in `Sources/CefKit` that calls it.
3. Run `Scripts/check-symbols.sh` — it verifies every listed symbol is an
   exported global of the real CEF binary (downloads in `.cef/dist` or
   `CEF_FRAMEWORK_PATH`). CI runs the same check.
4. `swift test` — `MaintenanceTests` guards the X-macro list shape and
   `LoaderTests` exercises a real dlopen when a framework is present.

### CEF version updates

Automated end to end: the `cef-update` workflow runs `Scripts/cef-update.sh`
twice a week, which bumps `CEF_VERSION.json`, re-vendors the headers, greps
the new headers for every bridge symbol (a miss blocks auto-merge), and opens
a PR that CI must pass — including `check-symbols.sh` against the freshly
downloaded binary and a live smoke launch. To test the script locally just run
`Scripts/cef-update.sh`; when the pin is current it prints "up to date" and
touches nothing.

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
