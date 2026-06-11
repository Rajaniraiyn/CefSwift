# Sandbox

## Status: v1 ships unsandboxed

CefSwift v1 initializes CEF with `no_sandbox = 1` (`CefConfiguration.noSandbox`
defaults to `true`, and v1 does not support turning it off). Renderer, GPU,
and utility processes run **without** Chromium's macOS sandbox.

This is a deliberate, documented v1 trade-off — wiring the sandbox correctly
across five helper apps, ad-hoc signing, and a SwiftPM-built loader is real
work we chose to land after the core — but you should understand what it
means before shipping.

## What enabling the sandbox will require

Since CEF M138, the macOS sandbox ships as a dylib inside the framework:
`Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib`
(previously it was the static `cef_sandbox.a` you had to link). The enabling
sequence, per process:

1. **Helpers first.** Each helper process must call
   `cef_sandbox_initialize(argc, argv)` from `libcef_sandbox.dylib`
   **before loading the main CEF framework** — the sandbox must be sealed
   before Chromium code runs. (There is a corresponding
   `cef_sandbox_destroy` for teardown.)
2. The browser process initializes CEF with `no_sandbox = 0`.
3. Bundle structure must remain exactly as the plugin builds it (the sandbox
   policy depends on helper layout), and signing identities/entitlements must
   be consistent across app and helpers.

CefSwift's design leaves a **clean seam** for this: the helper entry point
(`CefRuntime.helperMain()`) is the single place the dylib load order is
decided, and the loader already resolves the framework path before any CEF
call. When this lands it will be a configuration flip plus a plugin update —
no app-code changes.

Until then, do not set `noSandbox = false`; v1 ignores/rejects it.

## Security posture guidance (running unsandboxed)

Treat your v1 CefSwift app the way you would treat any unsandboxed browser
runtime:

- **Prefer trusted content.** An embedded dashboard loading your own origins
  is a very different risk profile from a general-purpose browser loading
  arbitrary URLs. For the latter, understand that a renderer compromise is not
  contained by an OS sandbox.
- **Keep CEF current.** This is the single highest-leverage mitigation, and
  CefSwift automates it — the auto-update pipeline
  ([automation.md](automation.md)) turns Chromium security releases into
  auto-merging PRs. Ship updates promptly.
- **Narrow the surface.** Use `extraCommandLineSwitches` to disable features
  you don't need; don't enable `remoteDebuggingPort` in production builds
  (it's an unauthenticated localhost control channel).
- **Standard hardening still applies.** Hardened runtime + notarization for
  distribution ([bundling.md](bundling.md)), HTTPS-only content, and treating
  console/JS bridges as untrusted input.
- The macOS **App Sandbox** (the App Store entitlement) is a separate
  mechanism from Chromium's sandbox and is likewise not supported in v1.
