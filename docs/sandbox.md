# Sandbox

CefSwift fully wires the Chromium macOS sandbox; flipping it on is one knob:

```swift
static var cefConfiguration: CefConfiguration {
    var config = CefConfiguration()
    config.noSandbox = false   // enable the Chromium sandbox
    return config
}
```

It defaults to **off** because sandboxed operation is only supportable on
properly signed bundles (see caveats). Flip it for distribution builds once
your signing pipeline is in place.

## How it works

Since CEF M138 the macOS sandbox ships as a dylib inside the framework:
`Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib`.

1. **Browser process** — `cef_settings_t.no_sandbox = 0` (mapped from
   `CefConfiguration.noSandbox`). With the sandbox on, CEF stops appending
   `--no-sandbox` to helper command lines.
2. **Helper processes** — `CefRuntime.helperMain()` inspects argv: when
   `--no-sandbox` is absent it calls `ccef_sandbox_initialize(argc, argv)`
   (`Sources/CCef/ccef_sandbox.{h,c}`), which dlopens `libcef_sandbox.dylib`
   from the helper-relative path, resolves `cef_sandbox_initialize`, and
   seals the process — **before** the main CEF framework is loaded, as the
   sandbox contract requires. If sealing fails, the helper exits 125 with
   the loader error on stderr (running an unsandboxed helper when the
   browser expected one sealed would be silently weaker — we refuse).
3. The sandbox loader is intentionally separate from the main `ccef_loader`
   symbol table, mirroring CEF's `cef_scoped_sandbox_context_mac.mm`.

No app-code changes beyond the configuration flip; the bundle layout that
`cef bundle` produces already ships the dylib inside the framework's
`Libraries/` directory.

## Caveats

- **Signing matters.** Chromium's sandbox expectations are tied to bundle
  identity and consistent signing across the app and all five helpers. Ship
  sandboxed builds with real Developer ID / App Store signing (+ hardened
  runtime for notarization). Ad-hoc builds have worked in testing but that
  is not a support promise — OS updates may tighten it.
- **Keep the bundle layout intact.** The dylib path is resolved relative to
  the helper executable; don't restructure what `cef bundle` produces.
- **`--no-sandbox` wins.** If anything injects `--no-sandbox` into the
  browser process, CEF propagates it and helpers skip sealing — by design,
  it's the switch CEF itself uses.
- The macOS **App Sandbox** (the App Store entitlement) is a separate
  mechanism from Chromium's sandbox; CefSwift does not manage entitlements.

## If you stay unsandboxed

- **Prefer trusted content.** An embedded dashboard loading your own
  origins is a very different risk profile from a general-purpose browser.
- **Keep CEF current.** The auto-update pipeline ([automation.md](automation.md))
  turns Chromium security releases into auto-merging PRs.
- **Narrow the surface.** Disable features you don't need via
  `extraCommandLineSwitches`; don't enable `remoteDebuggingPort` in
  production (unauthenticated localhost control channel).
- **Treat bridges as attack surface.** `CefBridge` handlers run with app
  privileges — validate inputs ([configuration.md](configuration.md#js--swift-bridge)).
