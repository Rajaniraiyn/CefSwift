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
2. **Helper processes.** `CefRuntime.helperMain()` checks its arguments.
   Without `--no-sandbox`, it calls `ccef_sandbox_initialize(argc, argv)`
   (`Sources/CCef/ccef_sandbox.c`), which loads `libcef_sandbox.dylib` from
   its path relative to the helper executable and calls
   `cef_sandbox_initialize` to seal the process before the framework loads,
   as the sandbox requires. If sealing fails, the helper prints the error and
   exits with status 125 rather than run unsandboxed.
3. The sandbox loader is separate from the main loader (`ccef_loader.c`),
   as in CEF's `cef_scoped_sandbox_context_mac.mm`.

No other code changes are needed. Bundles from `cef bundle` already contain
the library in the framework's `Libraries/` directory.

## Requirements

- **Signing.** The sandbox depends on bundle identity and on consistent
  signing across the app and all five helpers. Ship sandboxed builds signed
  with a Developer ID or App Store identity, with the hardened runtime for
  notarization ([bundling](bundling.md#distributing)). Ad hoc signed builds
  may work, but that is not guaranteed across macOS updates.
- **Bundle layout.** The library's path is resolved relative to the helper
  executable, so keep the layout that `cef bundle` produces.
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
