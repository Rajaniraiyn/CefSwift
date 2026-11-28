# AGENTS.md

Instructions for coding agents working in this repository. Humans: see
[CONTRIBUTING.md](CONTRIBUTING.md), which this file summarizes.

CefSwift is a Swift and SwiftUI binding for the official prebuilt CEF
(Chromium Embedded Framework) on macOS. The pinned CEF and Chromium
versions are in `CEF_VERSION.json`.

**Building an app with CefSwift rather than changing CefSwift?** Use the
skills in [`skills/`](skills): `cefswift` (modules, hosts, rules, API) and
`build-a-browser` (a complete browser). Install them with
`npx skills add Rajaniraiyn/CefSwift`. The docs site is
https://rajaniraiyn.dev/cefswift/ (`llms.txt`, `llms-full.txt`).

## Layout

| Path | What |
|---|---|
| `Sources/CefKit` | The core: runtime, pages, profiles, delegates, AppKit host views, `CefWindow`, offscreen rendering, discarding. No SwiftUI. |
| `Sources/CefSwiftUI` | `CefSwiftApp`, `CefWebView`, SwiftUI modifiers. Re-exports CefKit. |
| `Sources/CefChromium` | Optional: `CefChromeWindow`, `CefTabs`, bookmarks, history, autocomplete, extensions, Chromium's surfaces. Bound to Chromium internals of the pinned CEF. |
| `Sources/CefPasskeys` | Optional: WebAuthn answered by the app. |
| `Sources/CefBundling`, `Sources/CefSwiftTool`, `Plugins/CefPlugin` | Bundle assembly, signing, `cef doctor`; the `cefswift` tool and the `swift package cef` plugin. |
| `Sources/CCef` | Vendored CEF C headers and the generated bridge. Never edit by hand. |
| `Sources/CefBase`, `CefRenderer`, `CefHelper`, `CefHelperStartup` | Shared reference counting, renderer-side code, the helper executable, its sandbox startup. |
| `Examples/` | A separate package (macOS 15): Browser, Gallery (30 demos), Minimal, Compat, SelfTest, SystemEngine, an Xcode project. |
| `docs/` | The source of the technical documentation: `guide.md` (tasks), `architecture.md` (internals), `design-notes.md` (measurements), `bundling.md`, `sandbox.md`, `automation.md`. |
| `www/` | The docs site (Blume, Bun). Pages are assembled from `docs/*.md` by `www/scripts/build-pages.ts`; see `www/README.md`. |
| `skills/` | Agent skills published with `npx skills add`. |
| `Scripts/` | CEF updates, bridge generation, doc-sample checks, measurements. |

## Commands

```sh
swift build                                   # the library
swift test                                    # unit tests; none starts Chromium
swift test --package-path Examples            # the Browser example's logic
Scripts/check-doc-samples.py                  # compile every Swift block in README, docs/, www/pages/, skills/
Scripts/generate-bindings.py --check          # the C bridge is current

# End-to-end against the real Chromium runtime (needs a logged-in GUI session):
swift package --package-path Examples --allow-writing-to-package-directory \
    --allow-network-connections all cef bundle --product SelfTest
Examples/dist/SelfTest.app/Contents/MacOS/SelfTest   # exit status = failures
SELFTEST_ONLY=passkeys,discard Examples/dist/SelfTest.app/Contents/MacOS/SelfTest

# The docs site:
cd www && bun install && bun run build
```

Building SwiftUI targets needs an Xcode toolchain: SwiftUI's macro plugin
(`@Entry`, and `@State` in the macOS 27 SDK) is not in the Command Line
Tools.

## Rules

- Never `swift run` an app target: Chromium starts only from an app bundle
  (`swift package … cef bundle --product <Name>`).
- Never add the App Sandbox entitlement: official CEF builds do not run
  under it.
- Do not edit `Sources/CCef/include/include`, `ccef_capi.h`,
  `ccef_symbols.h` or `CEF_VERSION.json` by hand: `Scripts/update-cef.py`
  and `Scripts/generate-bindings.py` write them.
- Swift 6 language mode, `@MainActor` over locks, no force-unwraps in
  library code, doc comments on public API. Names follow CEF's and
  Chromium's terms (CONTRIBUTING.md, Naming).
- The library holds only what an app cannot write against the public API;
  product decisions (UI, defaults, heuristics) belong in `Examples/`.
- A change that crosses into CEF gets a SelfTest check
  (`Examples/Sources/SelfTest`). A new public API gets a sample in
  `docs/guide.md`, which `Scripts/check-doc-samples.py` compiles.
- A new `##` or `###` section in `docs/*.md` needs a
  `<!-- section docs/<file>#<anchor> -->` line in a page under
  `www/pages/`, or the site build fails and names it.
- Keep measurements in `docs/design-notes.md` and `docs/architecture.md`
  with their date, machine and CEF version; do not restate numbers
  elsewhere without a link to them.
- Prose: plain and specific, no marketing words, no emoji.
