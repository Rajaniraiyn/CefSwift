# Sandbox

Chromium's macOS sandbox confines the renderer, GPU, network and other
helper processes. CefSwift turns it on by default, in every preset, as
Chrome does. Turn it off only to debug a helper, or for a bundle that
`cef bundle` did not make:

```swift
static var runtimeConfiguration: CefRuntime.Configuration {
    var configuration = CefRuntime.Configuration.chrome
    configuration.isSandboxEnabled = false   // development only
    return configuration
}
```

`--no-sandbox` on the app's command line turns it off for one run.

## Evidence

Measured on 2026-11-13 with CEF 156.0.28 on an M3 MacBook, macOS 27.2, ad
hoc signed bundles from `cef bundle`:

- SelfTest passes every check with the sandbox on (491 passed, none
  skipped), and `sandbox_check` reports each helper process sandboxed and
  the app process not. CI runs SelfTest with the sandbox, the
  default; `SELFTEST_SANDBOX=0` runs it without.
- Footprint and launch time, measured with
  [`Scripts/measure-footprint.py`](../Scripts/measure-footprint.py), are in
  [design notes](design-notes.md#sandbox).
- Not covered by SelfTest: system media decoders a sandboxed renderer
  cannot open, which Chromium does not use for web media.
- The Alerts helper (`<App> Helper (Alerts)`), which posts system
  notifications, is never sandboxed, as in Chrome. It starts only when the
  app turns system notifications on
  ([`services.systemNotifications`](guide.md#system-notifications)); by
  default it never runs.

## How it works

Since CEF 138 the macOS sandbox ships as a library inside the framework,
`Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib`.

1. **Browser process.** `isSandboxEnabled` sets `cef_settings_t.no_sandbox`
   to 0. Chromium then stops passing `--no-sandbox` to helper processes.
2. **Helper processes.** The helper executable links
   `Contents/Frameworks/libcefswift_helper_startup.dylib` ahead of the
   framework. That library's initializer runs before any framework code.
   Without `--no-sandbox` among the helper's arguments, it calls
   `cef_sandbox_initialize(argc, argv)` from `libcef_sandbox.dylib` to seal
   the process. If sealing fails, the helper prints an error and exits with
   status 125 rather than run unsandboxed. The library is CefSwift's
   `cefswift_helper_startup` product (`Sources/CefHelperStartup`).
3. This is the order CEF requires (`cef_sandbox_mac.h`: initialize the
   sandbox before the framework loads), reached with the framework linked
   at launch instead of loaded with `dlopen` afterwards. See
   [architecture](architecture.md#loading-the-framework-at-launch) for why.

No other code changes are needed. Bundles from `cef bundle` contain both
libraries.

### libcef_sandbox and Chromium's Aperitif helpers

Chrome 157 ships helper apps named `Google Chrome Helper (Aperitif).app`,
`(Aperitif Renderer)`, `(Aperitif GPU)` and `(Aperitif Alerts)`, which link
`libaperitif.dylib` before the framework. That library is Chromium's
counterpart of `libcef_sandbox.dylib` plus CefSwift's startup library: it
seals the seatbelt sandbox and registers PartitionAlloc's malloc zone
before any other code runs. Chromium launches those helpers only when its
`AperitifHelpers` feature is on. CEF 156 ships no `libaperitif.dylib` and
no Aperitif helpers, leaves the feature off, and asks clients to seal the
sandbox with `libcef_sandbox.dylib`, which is what CefSwift does. Do not
turn `AperitifHelpers` on: Chromium then looks for helper apps the bundle
does not have, fails to start the GPU process, and ends the app.

## Requirements

- **Signing.** The sandbox depends on bundle identity and on consistent
  signing across the app and all five helpers, which `cef bundle` gives
  every bundle, ad hoc ones included. Ship builds signed with a Developer
  ID or App Store identity, with the hardened runtime for notarization
  ([bundling](bundling.md#distribution)).
- **Bundle layout.** The helper finds both libraries and the framework by
  paths relative to its executable, so keep the layout that `cef bundle`
  produces.
- **Library validation.** The helpers load the startup library, the
  framework and `libcef_sandbox.dylib` at launch by
  `@executable_path`-relative paths. Under the hardened runtime, library
  validation loads them only when they carry the helper's team identifier.
  `cef bundle` signs all of them with the app's identity (CEF ships its
  libraries linker-signed ad hoc), so a team-signed bundle needs no
  `com.apple.security.cs.disable-library-validation`. An ad hoc or
  self-signed bundle has no team to match, so with the hardened runtime
  `cef bundle` adds that entitlement; on macOS 27.2 such a bundle starts
  normally and passes SelfTest.
- **`--no-sandbox`.** If anything adds `--no-sandbox` to the browser
  process's command line, Chromium passes it on and helpers skip sealing.
  This is the switch Chromium itself uses.
- The App Sandbox (the App Store entitlement) is a separate mechanism from
  Chromium's sandbox, and CefSwift does not support it
  ([bundling](bundling.md#app-sandbox)).

## Without the sandbox

- **Prefer trusted content.** A view that loads your own origins carries far
  less risk than a general-purpose browser.
- **Keep CEF current.** The update workflow ([automation](automation.md))
  turns each stable CEF release, including Chromium security fixes, into a
  pull request that merges itself once CI passes.
- **Narrow the surface.** Turn off features you do not need with
  `disabledFeatures` or `extraCommandLineSwitches`. Do not set
  `remoteDebuggingPort` in shipping builds: it opens an unauthenticated
  control channel on localhost.
- **Treat bridges as attack surface.** `CefBridge` handlers run with your
  app's privileges; validate their input and check the caller's origin
  ([guide](guide.md#bridge)).
