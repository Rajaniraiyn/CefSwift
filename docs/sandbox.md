# Sandbox

## Status: implemented, off by default

CefSwift fully wires the Chromium macOS sandbox; flipping it on is one knob:

```swift
static var cefConfiguration: CefConfiguration {
    var config = CefConfiguration()
    config.noSandbox = false   // enable the Chromium sandbox
    return config
}
```

It still defaults to **off** (`noSandbox = true`) because sandboxed operation
is only supportable on properly signed bundles (see the caveats below). Flip
it for your distribution builds once your signing pipeline is in place.

## How it works

Since CEF M138 the macOS sandbox ships as a dylib inside the framework:
`Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib`. The
sequence CefSwift implements:

1. **Browser process** — `cef_settings_t.no_sandbox = 0` (mapped from
   `CefConfiguration.noSandbox`). With the sandbox on, CEF stops appending
   `--no-sandbox` to helper command lines.
2. **Helper processes** — `CefRuntime.helperMain()` inspects argv: when
   `--no-sandbox` is absent it calls `ccef_sandbox_initialize(argc, argv)`
   (`Sources/CCef/ccef_sandbox.{h,c}`), which dlopens
   `libcef_sandbox.dylib` from the helper-relative path
   (`<exe>/../../../Chromium Embedded Framework.framework/Libraries/…`),
   resolves `cef_sandbox_initialize`, and seals the process — **before** the
   main CEF framework is loaded, as the sandbox contract requires. The
   context and dylib stay alive for the process lifetime. If sealing fails,
   the helper exits 125 with the loader error on stderr (running an
   unsandboxed helper when the browser expected a sandboxed one would be
   silently weaker — we refuse instead).
3. The sandbox loader is intentionally **separate** from the main
   `ccef_loader` symbol table: it has its own dlopen/dlsym pair, mirroring
   CEF's `cef_scoped_sandbox_context_mac.mm`.

No app-code changes are needed beyond the configuration flip; the bundle
layout the `cef` plugin produces is already correct (the dylib ships inside
the framework's `Libraries/` directory).

## What we verified (CEF 148, macOS, Apple Silicon)

Using the Browser example's dev hook (`CEFSWIFT_ENABLE_SANDBOX=1`, see
`Examples/Sources/Browser/BrowserApp.swift`) on an **ad-hoc-signed** dev
bundle:

- `Browser --cef-smoke-test` with the sandbox enabled: **exit 0** (page
  loads and renders).
- Helper command lines contain **no** `--no-sandbox`; renderers run with
  `--enable-sandbox` and a live `--seatbelt-client=<fd>` — i.e. the Seatbelt
  sandbox is genuinely engaged, not silently skipped.
- Normal browsing (DuckDuckGo, chrome:// pages) works under the sandbox.

So on this machine the sandbox works end-to-end even ad-hoc signed. Treat
that as encouraging but not portable:

## Caveats

- **Signing matters.** Chromium's sandbox expectations are tied to bundle
  identity and consistent signing across the app and all five helpers. Ship
  sandboxed builds with real Developer ID / App Store signing (+ hardened
  runtime for notarization). Ad-hoc builds happened to work in our testing;
  that is not a support promise, and OS updates may tighten it.
- **Keep the bundle layout intact.** The dylib path is resolved relative to
  the helper executable; don't restructure what `swift package cef bundle`
  produces.
- **`--no-sandbox` wins.** If anything injects `--no-sandbox` into the
  browser process, CEF propagates it and helpers skip sealing (by design —
  that's the switch CEF itself uses).
- The macOS **App Sandbox** (the App Store entitlement) is a separate
  mechanism from Chromium's sandbox; CefSwift does not manage entitlements.

## Security posture guidance (if you stay unsandboxed)

- **Prefer trusted content.** An embedded dashboard loading your own origins
  is a very different risk profile from a general-purpose browser loading
  arbitrary URLs.
- **Keep CEF current.** The auto-update pipeline
  ([automation.md](automation.md)) turns Chromium security releases into
  auto-merging PRs. Ship updates promptly.
- **Narrow the surface.** Disable features you don't need via
  `extraCommandLineSwitches`; don't enable `remoteDebuggingPort` in
  production (it's an unauthenticated localhost control channel).
- **Treat bridges as attack surface.** `CefBridge` handlers run with app
  privileges — validate inputs ([js-bridge.md](js-bridge.md)).
