# Sandbox

CefSwift supports Chromium's macOS sandbox, which confines renderer, GPU and
other helper processes. Turn it on in the configuration:

```swift
static var cefConfiguration: CefConfiguration {
    var configuration = CefConfiguration.browser
    configuration.isSandboxEnabled = true
    return configuration
}
```

It is off by default, because sandboxed helpers depend on a consistently
signed bundle (see [Requirements](#requirements)). Turn it on for
distribution builds once your signing is in place.

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
   status 125 rather than run unsandboxed. The sources are in
   `Plugins/CefPlugin/Helper/`.
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
  signing across the app and all five helpers. Ship sandboxed builds signed
  with a Developer ID or App Store identity, with the hardened runtime for
  notarization ([bundling](bundling.md#distributing)). Ad hoc signed builds
  may work, but that is not guaranteed across macOS updates.
- **Bundle layout.** The helper finds both libraries and the framework by
  paths relative to its executable, so keep the layout that `cef bundle`
  produces.
- **Library validation.** The helpers load the startup library and the
  framework at launch by `@executable_path`-relative paths. Sign both with
  the same identity as the helpers, as `cef bundle` does, so library
  validation under the hardened runtime accepts them. Chromium reverted a
  2022 version of its Aperitif helpers because macOS refused such paths in
  processes with library validation disabled; on macOS 27.2 an ad hoc
  signed bundle with the hardened runtime and
  `com.apple.security.cs.disable-library-validation` starts normally.
- **`--no-sandbox`.** If anything adds `--no-sandbox` to the browser
  process's command line, Chromium passes it on and helpers skip sealing.
  This is the switch Chromium itself uses.
- The App Sandbox (the App Store entitlement) is a separate mechanism from
  Chromium's sandbox. CefSwift does not manage entitlements.

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
