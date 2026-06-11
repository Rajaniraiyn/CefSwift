# Architecture

How CefSwift turns the CEF C API into an Apple-quality Swift framework.

## Module graph

```
                    ┌──────────────┐
                    │  CefSwiftUI  │  SwiftUI layer: CefSwiftApp, CefWebView,
                    └──────┬───────┘  CefWebViewModel (@Observable)
                           │
                    ┌──────▼───────┐
                    │    CefKit    │  Swift core: CefRuntime, CefBrowser,
                    └──┬────────┬──┘  CefConfiguration, delegates
                       │        │
            ┌──────────▼──┐  ┌──▼──────────┐
            │    CCef     │  │ CCefAppKit  │
            │ (C target)  │  │ (ObjC)      │
            └─────────────┘  └─────────────┘
   vendored CEF headers +     CEFApplication: NSApplication
   dlopen/dlsym loader        conforming to CrAppControlProtocol

            ┌─────────────┐
            │ cef-helper  │  executable, depends on CefKit;
            └─────────────┘  bundled 5× by the CefPlugin
```

- **CCef** vendors the CEF `include/` tree verbatim (BSD-licensed) and exposes
  only the **C-safe** subset through its umbrella header: `include/capi/*.h`,
  the C types in `include/internal/`, `cef_api_hash.h`, and the version
  headers. The C++ headers (`include/cef_browser.h`, `include/base`,
  `include/wrapper`) are present on disk but never imported.
- **CCefAppKit** is a tiny Objective-C target providing `CEFApplication`, the
  `NSApplication` subclass Chromium requires (see Threading below).
- **CefKit** is the Swift wrapper: lifecycle (`CefRuntime`), browsers
  (`CefBrowser`, `CefBrowserFactory`), configuration, and the delegate
  protocol. All `@MainActor`.
- **CefSwiftUI** layers `CefSwiftApp` (app bootstrap), `CefWebViewModel`
  (observable state), and `CefWebView` (`NSViewRepresentable`) on top.
- **cef-helper** is the subprocess executable. Its `main.swift` is one line:
  `CefRuntime.helperMain()`.

## The dlopen loader: zero link-time CEF

CefSwift never links against CEF. The framework dylib inside
`Chromium Embedded Framework.framework` exports the entire `cef_*` C API as
ordinary symbols, so CCef's loader (`ccef_loader.c`):

1. `dlopen`s the framework binary with `RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST`.
   The path is resolved relative to the executable: the main app looks in
   `<exe>/../Frameworks/...`, helpers in `<exe>/../../../...` (helpers live in
   the main app's `Contents/Frameworks/`).
2. `dlsym`s every symbol CefSwift uses into a function-pointer table. The
   symbol list is a single X-macro list (`ccef_symbols.h`) — adding a symbol
   is a one-line change.
3. Defines **real-named trampoline functions** (`cef_initialize`, …) that
   forward through the table, so Swift code calls the C API naturally through
   the `CCef` module.

A missing symbol fails the load with the symbol's name in the error — never a
crash at call time.

After loading, and **before anything else in every process**, CefSwift calls
`cef_api_hash(CEF_API_VERSION, 0)`. `CEF_API_VERSION` is pinned in
`ccef_config.h` to a stable version from CEF's versioned-API mechanism
(`include/cef_api_versions.h`), which keeps the C API ABI-stable across CEF
releases — the property that makes automated CEF bumps (docs/automation.md)
safe.

## Refcounting bridge

The CEF C API uses intrusive reference counting: every object begins with a
`cef_base_ref_counted_t`. CefSwift bridges this with two patterns:

- **Objects CefSwift implements** (clients, handlers, callbacks) use the
  extended-struct trick: a struct whose first member is the CEF struct
  (e.g. `cef_client_t`), followed by an `Unmanaged` backpointer to the Swift
  object. `add_ref`/`release` adjust an atomic counter that retains/releases
  the Swift side; C callbacks recover `self` by casting the struct pointer
  back.
- **Objects CEF hands to us** follow the capi rules exactly:
  - Pass +1 (call `add_ref`) before handing an object **into** CEF as a
    non-`self` argument — CEF consumes one reference.
  - Objects arriving in callbacks come with +1; release them unless retaining.
  - `cef_string_userfree_t` results are freed with
    `cef_string_userfree_utf16_free`.

Strings: `cef_string_t` is UTF-16 (`char16_t*` + length + dtor). A `CefString`
RAII wrapper converts via `cef_string_utf8_to_utf16` and guarantees cleanup.
One more capi gotcha handled centrally: most CEF structs begin with
`size_t size`, which must be set to `sizeof(...)` before use.

## External message pump

macOS CEF does not support `multi_threaded_message_loop`, and SwiftUI owns the
main run loop — so CefSwift uses CEF's external message pump:

- `cef_settings_t.external_message_pump = 1`.
- CEF calls our `on_schedule_message_pump_work(delay_ms)` whenever it wants
  CPU time.
- CefSwift schedules a main-thread timer for `delay_ms` (clamped to a 33 ms
  maximum so CEF stays responsive even if it asks for a long delay) that calls
  `cef_do_message_loop_work()`.
- A re-entrancy guard prevents `cef_do_message_loop_work` from being entered
  recursively (CEF may pump nested run loops during it).

The result: Chromium and SwiftUI share one main thread cooperatively, with no
busy loop and near-zero idle CPU.

## Threading model

- With the external pump, **the CEF UI thread is the macOS main thread**.
  CefKit is `@MainActor` end to end; most CEF callbacks already arrive on the
  main thread and are asserted + dispatched directly, with a `DispatchQueue.main`
  hop only for the few that originate elsewhere.
- `NSApplication` must conform to CEF's `CefAppProtocol`
  (`isHandlingSendEvent` / `setHandlingSendEvent:`) and wrap `sendEvent:` with
  that flag — Chromium uses it to track nested event dispatch. The application
  object must be `CEFApplication` **before anything touches `NSApp`**, which
  is why `CefSwiftApp.main()` exists: it installs `CEFApplication`, initializes
  `CefRuntime`, and only then enters SwiftUI's `App.main()` — the standard
  `NSApplicationMain` path is never used.
- `terminate:` is intercepted so quitting routes through browser close and
  `cef_quit_message_loop` instead of killing renderers mid-flight.

## Process model

Chromium is multi-process. The main app runs the browser process; renderers,
GPU, plugin, and alert processes are launched from the five helper `.app`s in
`Contents/Frameworks/` (see docs/bundling.md). Every helper is the same
`cef-helper` binary: it loads the framework via its helper-relative path,
calls `cef_api_hash`, then `cef_execute_process(&args, nil, nil)` and exits
with its return value — CEF decides what kind of process to become from the
command line it passed.
