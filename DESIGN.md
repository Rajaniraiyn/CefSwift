# CefSwift — Architecture Contract

> This document is the **binding contract** between modules. Implementation agents must
> conform to the names/signatures here exactly. Internals are free; public surface is not.
> If something here is impossible in practice, implement the closest working alternative and
> leave a `// CONTRACT-DEVIATION:` comment explaining why.

## Embedding architecture (SETTLED — evidence-backed, CEF 148, macOS)

The central constraint: **CEF/Chromium binds a chrome-runtime browser's compositor to its
own NSWindow.** Native-parent (`parent_view`) and windowless both force Alloy style on macOS
(libcef `browser_host_create.cc`; tracking issue #3294 — Win/Linux only). Plain NSView
reparenting of a chrome browser blanks rendering (compositor re-detaches in ~2s). Remote
CALayer mirroring (CAContext id) is not exposed by CEF and is App-Store-hostile. Therefore
CefSwift ships **three hosting modes**, each proven with screenshots:

1. **Windowed Alloy** — `CefWebView` (NSViewRepresentable, `parent_view`). CEF renders +
   handles input/IME/AX natively. Cannot composite native UI *over* the page region. Default,
   max compatibility. SHIPPING.
2. **Chrome-runtime window (inverted ownership)** — `CefChromeWindow`: a CEF Views top-level
   window (`cef_browser_view` + `cef_window`, chrome style, toolbar hidden via
   `CEF_CTT_NONE`) that HOSTS native `NSHostingView` SwiftUI overlays added as subviews of the
   CEF window's content view (proven: SwiftUI tabstrip/omnibox composite on top of full chrome
   runtime — chrome://history/extensions/settings render). CEF owns the NSWindow (not SwiftUI's
   `WindowGroup`); lifecycle driven through `cef_window_delegate_t`. The "full browser" mode.
3. **OSR / Metal (`windowlessRenderingEnabled`)** — `CefMetalWebView`: CEF paints into a
   shared `IOSurface` (`on_accelerated_paint`, `shared_texture_enabled`) composited in a
   `CAMetalLayer`/`CALayer`-backed view → a genuine in-tree subview, retina-correct, native UI
   compositable anywhere (beats Electron's BrowserView). Alloy style only (no chrome://). All
   "native" affordances are DIY via capi handlers: input (`send_mouse_*`/`send_key_event` +
   DIP coordinate mapping), IME (`NSTextInputClient` ↔ `ime_set_composition`), cursor
   (`on_cursor_change`), AX (`cef_accessibility_handler` → `NSAccessibility`), context menu
   (`cef_context_menu_handler`), DevTools (`show_dev_tools` → own surface). The "indistinguishable
   embedded web view" premium primitive.

Native JS binding (`window.<name>` Electron/Playwright parity): feasible via
`get_render_process_handler` → `on_context_created` installing `cef_v8_value_create_function`
+ `cef_v8_handler_t` → `send_process_message` IPC → browser route → reply → promise resolve.
Requires the shared `cef-helper` app to carry a render-process handler (extends the same app
seam the custom-schemes work opened). Complements (does not replace) the `cefswift://` scheme
bridge.

## Vision

CefSwift is to Swift/SwiftUI what CefSharp is to .NET — but designed as if Apple shipped it:
a Swift Package that embeds the Chromium Embedded Framework as first-class SwiftUI views,
with fully automated CEF download/bundling via a SwiftPM command plugin, zero link-time CEF
dependency (runtime `dlopen`/`dlsym`), modern Chrome runtime style (tabs, extensions,
chrome:// internals) and everything configurable & pluggable. Capable of powering a full
browser (Arc/Atlas-class) or a single embedded web card in a dashboard.

## Pinned facts (verified 2026-06-11; do not re-research)

- Pinned CEF: `148.0.10+g7ee53f5+chromium-148.0.7778.218` (stable). Distros from
  `https://cef-builds.spotifycdn.com/<urlencoded name>` (`+` → `%2B`), `.tar.bz2`, sha1 in index.json.
  Extracted copy lives at `/tmp/cefswift-ref/cef_binary_148.0.10+g7ee53f5+chromium-148.0.7778.218_macosarm64_minimal/`.
- The framework dylib (`Release/Chromium Embedded Framework.framework/Chromium Embedded Framework`)
  **exports all `cef_*` C API globals** (`_cef_initialize` etc.). Official pure-C flow
  (`tests/cefsimple_capi/cefsimple_mac.m`): dlopen framework → `cef_api_hash(CEF_API_VERSION, 0)`
  FIRST → `cef_initialize`/`cef_execute_process` → … → `cef_shutdown` → dlclose.
- dlopen flags: `RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST`. Framework path resolution:
  main app `<exe>/../Frameworks/Chromium Embedded Framework.framework/...`;
  helper `<exe>/../../../Chromium Embedded Framework.framework/...` (helpers live in
  `Contents/Frameworks/` of the main app).
- **Five** helper apps, all the same binary: `<App> Helper.app`, plus suffixes
  `(Alerts)`, `(GPU)`, `(Plugin)`, `(Renderer)`; bundle-id suffixes `.helper`,
  `.helper.alerts`, `.helper.gpu`, `.helper.plugin`, `.helper.renderer`. Names are
  load-bearing: helper exe name must be `<main exe name> Helper (Suffix)` exactly.
- Helper Info.plist: `LSUIElement=1`, `LSFileQuarantineEnabled=true`. Main app Info.plist:
  `LSEnvironment={MallocNanoZone="0"}` (required), `NSPrincipalClass=NSApplication`,
  `LSMinimumSystemVersion=14.0`, `NSSupportsAutomaticGraphicsSwitching=true`.
- Most CEF structs start with `size_t size` — must be set to `sizeof(...)`.
- Refcounting (capi rules): +1 (add_ref) before passing an object INTO CEF as a non-self arg
  (CEF consumes one ref); objects CEF hands to your callbacks arrive +1 and you must release
  unless retaining; `cef_string_userfree_t` freed with `cef_string_userfree_utf16_free`.
- `cef_string_t` = `cef_string_utf16_t {char16_t* str; size_t length; dtor}`. Convert via
  `cef_string_utf8_to_utf16`.
- macOS: `multi_threaded_message_loop` unsupported → we use `external_message_pump=1` +
  `on_schedule_message_pump_work(delay_ms)` driving `cef_do_message_loop_work()` on the main
  thread (NSTimer, clamp max delay 33 ms, guard re-entrancy) because SwiftUI owns the run loop.
- NSApplication must conform to CEF's `CefAppProtocol` (= CrAppControlProtocol:
  `isHandlingSendEvent`/`setHandlingSendEvent:`), override `sendEvent:` to wrap the flag, and
  must be instantiated **before** any `NSApp` touch → custom `main()` pattern, NOT NSApplicationMain.
- Sandbox: v1 ships `no_sandbox=1`. (M138+: sandbox is `Libraries/libcef_sandbox.dylib`,
  helpers would call `cef_sandbox_initialize(argc, argv)` before loading the framework —
  leave a clean seam + doc, don't implement.)
- API versioning: `#define CEF_API_VERSION` to a stable version from
  `include/cef_api_versions.h` (pick the newest listed stable version, e.g. `14800`-series —
  read the vendored header to choose) → ABI-stable across CEF bumps; call
  `cef_api_hash(CEF_API_VERSION, 0)` before everything in every process.
- Windowed embedding: `cef_window_info_t` (mac): `size`, `window_name`, `bounds` (cef_rect_t),
  `hidden`, `parent_view` (NSView*), `view` (out), `runtime_style` (cef_runtime_style_t).
- Toolchain on this machine: Swift 6.3.2, **Command Line Tools only (no Xcode)** — everything
  must work via `swift build` + scripts. XcodeGen IS installed for project.yml generation.

## Repository layout

```
Package.swift                      # authored — do not restructure targets
CEF_VERSION.json                   # pinned CEF manifest (schema below)
DESIGN.md
README.md
.gitignore
Sources/
  CCef/                            # C target: vendored CEF headers + dlopen loader
  CCefAppKit/                      # ObjC target: CEFApplication (CrAppControlProtocol)
  CefKit/                          # Swift core wrapper
  CefSwiftUI/                      # SwiftUI layer
  cef-helper/                      # helper-process executable (main.swift)
Plugins/
  CefPlugin/                       # command plugin, verb "cef"
Examples/
  Package.swift                    # separate package, deps: .package(path: "..")
  project.yml                      # XcodeGen (generated .xcodeproj gitignored)
  Sources/Browser/                 # Arc-style mini browser example
  Sources/Gallery/                 # embedded-web-components example
Scripts/
  cef-update.sh                    # poll index.json, bump pins, re-vendor headers
.github/workflows/ci.yml
.github/workflows/cef-update.yml
docs/                              # architecture.md, bundling.md, chrome-style.md,
                                   # configuration.md, accessibility.md, sandbox.md
```

`.cef/` at package root = plugin's download/extract cache (gitignored).

## CEF_VERSION.json schema

```json
{
  "cef": "148.0.10+g7ee53f5+chromium-148.0.7778.218",
  "chromium": "148.0.7778.218",
  "channel": "stable",
  "platforms": {
    "macosarm64": { "minimal": {"name": "...", "sha1": "...", "size": 0},
                     "standard": {"name": "...", "sha1": "...", "size": 0} },
    "macosx64":  { ... same ... }
  }
}
```

## Target: CCef (C)

- Vendors the CEF `include/` tree verbatim (BSD-licensed) from the extracted 148 distro.
  CEF headers self-include as `"include/capi/..."` — preserve the prefix and arrange
  `publicHeadersPath` so that resolves. Custom `module.modulemap`, module name `CCef`,
  umbrella `CCef.h` including **C-safe** headers only (`include/capi/*.h`,
  `include/internal/*` C types, `include/cef_api_hash.h`, `include/cef_version*.h`) — never
  the C++ headers (`include/*.h` like cef_browser.h, include/base, include/wrapper).
- `ccef_config.h`: `#define CEF_API_VERSION <chosen>` BEFORE any CEF include; umbrella
  includes it first.
- `ccef_loader.{h,c}`: runtime loader —
  ```c
  int  ccef_load_framework(const char* framework_binary_path); // 1 on success
  void ccef_unload_framework(void);
  const char* ccef_loader_error(void);                          // last error message
  ```
  Resolves (dlsym) every `cef_*` global CefSwift uses into a pointer table and defines
  **real-named trampoline functions** (`cef_initialize`, …) so Swift code calls the C API
  naturally. Maintain the symbol list with one X-macro list (`ccef_symbols.h`) so adding a
  symbol is a one-liner. Missing symbol ⇒ load fails with the symbol name in the error.
  Cover at minimum: api_hash/version, initialize/shutdown/execute_process/get_exit_code,
  message-loop fns, browser_host_create_browser(+_sync), string utf8/utf16 conv/clear/set,
  userfree free, request_context_get_global_context, command_line, post_task/currently_on,
  dictionary/list/binary value create, cookie manager, v8 not needed v1.

## Target: CCefAppKit (ObjC)

Header `CCefAppKit.h` exposing:
```objc
@interface CEFApplication : NSApplication  // conforms CrAppControlProtocol
+ (void)install;   // creates [CEFApplication sharedApplication]; asserts NSApp class
@end
```
`sendEvent:` wraps the handlingSendEvent flag; `terminate:` delegates to a C callback the
Swift side registers (so quit routes through browser close + cef_quit_message_loop).
Re-declare the two Cr protocols locally in ObjC (don't import CEF C++ headers).

## Target: CefKit (Swift, depends CCef + CCefAppKit)

Public surface (exact):

```swift
public struct CefConfiguration: Sendable {
  public var flavor commentary not needed — runtime only knobs:
  public var noSandbox: Bool                  // default true
  public var rootCachePath: URL?              // default ~/Library/Application Support/<bundleid>/CefSwift
  public var cachePath: URL?
  public var locale: String?
  public var userAgentProduct: String?
  public var logSeverity: CefLogSeverity      // .default/.verbose/.debug/.info/.warning/.error/.fatal/.disable
  public var logFile: URL?
  public var remoteDebuggingPort: Int?
  public var persistSessionCookies: Bool
  public var defaultRuntimeStyle: CefRuntimeStyle   // .default (=chrome)
  public var externalMessagePump: Bool        // default true
  public var frameworkDirectory: URL?         // override; default = Bundle .../Frameworks/Chromium Embedded Framework.framework
  public var browserSubprocessPath: URL?      // override
  public var extraCommandLineSwitches: [String: String?]   // pluggable chromium switches
  public var onBeforeCommandLineProcessing: (@Sendable (CefCommandLine) -> Void)?
  public init()
  public static let `default`: CefConfiguration
}

public enum CefRuntimeStyle: Sendable { case `default`, chrome, alloy }
public enum CefLogSeverity: Sendable { ... }

@MainActor public final class CefRuntime {
  public static let shared: CefRuntime
  public private(set) var isInitialized: Bool
  public func initialize(configuration: CefConfiguration = .default) throws(CefError)
  public func shutdown()
  /// For helper executables: never returns.
  public static func helperMain() -> Never
}

public enum CefError: Error { case frameworkNotFound(String), loadFailed(String),
  apiHashMismatch(expected: String, actual: String), initializationFailed(exitCode: Int32),
  alreadyInitialized, notInitialized }

@MainActor public final class CefBrowser: Identifiable {
  public let id: Int32                       // cef identifier
  public weak var delegate: CefBrowserDelegate?
  public private(set) var url: URL?
  public private(set) var title: String
  public private(set) var isLoading: Bool
  public private(set) var canGoBack: Bool
  public private(set) var canGoForward: Bool
  public func load(_ url: URL)
  public func loadHTML? — v1 skip
  public func goBack(); public func goForward(); public func reload(ignoreCache: Bool = false); public func stopLoading()
  public func executeJavaScript(_ script: String)
  public var zoomLevel: Double { get set }
  public var isAudioMuted: Bool { get set }
  public func showDevTools(); public func closeDevTools()
  public func find(_ text: String, forward: Bool, matchCase: Bool)
  public func close(force: Bool = false)
  public var nativeView: NSView?             // CEF-created NSView once available
}

/// All-optional, pluggable observer. Default impls = no-op.
@MainActor public protocol CefBrowserDelegate: AnyObject {
  func browser(_ b: CefBrowser, didChangeTitle title: String)
  func browser(_ b: CefBrowser, didChangeURL url: URL?)
  func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
  func browser(_ b: CefBrowser, didChangeProgress progress: Double)
  func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String)
  func browser(_ b: CefBrowser, didChangeFavicon urls: [URL])
  func browser(_ b: CefBrowser, didChangeFullscreen isFullscreen: Bool)
  func browser(_ b: CefBrowser, requestsPopupFor url: URL?) -> CefPopupDecision  // .allow/.block/.openInSameBrowser
  func browserDidClose(_ b: CefBrowser)
  func browser(_ b: CefBrowser, didReceiveConsoleMessage message: String, level: CefLogSeverity, source: String, line: Int)
}

@MainActor public struct CefBrowserOptions {
  public var runtimeStyle: CefRuntimeStyle
  public var backgroundColor: NSColor?
  public var enableJavaScript etc — keep small: runtimeStyle + backgroundColor v1
  public init()
}

@MainActor public enum CefBrowserFactory {
  /// Creates a windowed browser as a child of `parentView` filling `bounds`.
  public static func createBrowser(parentView: NSView, bounds: CGRect, url: URL,
      options: CefBrowserOptions = .init(), delegate: CefBrowserDelegate?) -> CefBrowser
}
```

Internals (guidance, not contract): handler structs via the extended-struct trick
(`cef_client_t` first member + `Unmanaged` backpointer); a `CefRefCounted` helper managing
`cef_base_ref_counted_t` with atomics; `CefString` RAII wrapper; message pump class
(CFRunLoopTimer/NSTimer on main, 33ms clamp); browser registry keyed by cef id; all CEF
callbacks hop to MainActor via `DispatchQueue.main` when needed (CEF UI thread == main
thread on macOS with external pump, so most are already main — assert + direct call).

## Target: cef-helper (executable)

`main.swift`: `CefRuntime.helperMain()` — loads framework via helper-relative path
(`<exe>/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework`),
`cef_api_hash`, `cef_execute_process(&args, nil, nil)`, exit with its return value.

## Target: CefSwiftUI (Swift, depends CefKit)

```swift
/// `@main struct MyApp: CefSwiftApp` — the one-line bootstrap.
public protocol CefSwiftApp: SwiftUI.App {
  @MainActor static var cefConfiguration: CefConfiguration { get }   // default .default
}
extension CefSwiftApp {
  @MainActor public static func main()   // installs CEFApplication, CefRuntime.initialize,
                                         // then SwiftUI App main; on failure: fatalError with guidance
}

@Observable @MainActor public final class CefWebViewModel /* + CefBrowserDelegate */ {
  public var url: URL?                       // observed; set → navigates
  public private(set) var title: String
  public private(set) var isLoading: Bool
  public private(set) var estimatedProgress: Double
  public private(set) var canGoBack: Bool
  public private(set) var canGoForward: Bool
  public private(set) var faviconURL: URL?
  public var browser: CefBrowser? { get }
  public var options: CefBrowserOptions
  // pluggable hooks (all optional):
  public var onConsoleMessage: ((String) -> Void)?
  public var onPopupRequest: ((URL?) -> CefPopupDecision)?
  public init(url: URL? = nil, options: CefBrowserOptions = .init())
  public func load(_ url: URL); goBack(); goForward(); reload(); stopLoading()
  public func executeJavaScript(_ script: String)
}

public struct CefWebView: NSViewRepresentable {
  public init(model: CefWebViewModel)
  public init(url: URL)                      // owns a private model
}
```

`CefWebView` makes a hosting NSView, creates the browser on first layout (needs a window),
resizes the CEF child view on layout, and closes the browser on dismantle.

## Plugin: CefPlugin (command plugin, verb `cef`)

Permissions: `.writeToPackageDirectory`, `.allowNetworkConnections(scope: .all(ports: []))`.
Subcommands (`swift package cef <sub> ...`):

- `download [--platform macosarm64|macosx64] [--flavor minimal|standard] [--cef-version V]`
  → reads CEF_VERSION.json (of the ROOT package — when used from Examples, walk up / accept
  `--manifest path`), downloads via `curl` to `.cef/downloads/`, sha1-verifies, extracts to
  `.cef/dist/<version>_<platform>_<flavor>/`. Skips when present. Also converts the framework
  to **versioned bundle layout** (Versions/A + symlinks — Xcode 26 requirement) in place.
- `bundle --product <Name> [--configuration debug|release] [--flavor minimal|standard]
  [--platform ...] [--output <dir>] [--bundle-id <id>] [--name <Display>]`
  → `packageManager.build(.product(name))` + builds product `cef-helper`; assembles
  `<Output>/<Name>.app` with framework + 5 helper apps (copies of cef-helper binary renamed),
  generated Info.plists per pinned-facts section, then ad-hoc codesign inside-out
  (framework → helpers → app). Prints the path + `open` hint.
- `info` → prints pinned version, cache state, flavors.
- `clean` → removes `.cef/`.

Per-product overrides may come from an optional `cefapp.json` next to the target's sources:
`{ "bundleIdentifier": "...", "displayName": "...", "minimumSystemVersion": "14.0" }`.

Implementation: pure Foundation + Process (`curl`, `tar`, `codesign`, `/usr/bin/shasum -a 1`,
`plutil` or write plists with PropertyListSerialization). `BuildParameters(configuration:,
echoLogs: true)`. CLI pre-approval doc string: `swift package --allow-writing-to-package-directory
--allow-network-connections all cef bundle --product Browser`.

## Examples (separate package `Examples/`)

- **Browser**: Arc-class mini browser. SwiftUI: sidebar-or-top tab strip (multiple
  `CefWebViewModel`s), omnibox (URL + search fallback), back/forward/reload, progress bar,
  favicon, per-tab title, new-tab/close-tab, popup → new tab, DevTools menu item, Chrome
  runtime style (so chrome://extensions, chrome://history work — show those in a menu).
- **Gallery**: grid/dashboard of embedded `CefWebView` cards inside ordinary SwiftUI layout
  (mixing native controls + web), demonstrating configuration knobs (alloy style card,
  muted card, custom switches, console-log viewer panel).
- `Examples/project.yml` (XcodeGen) defining both apps for Xcode users (gitignore
  `*.xcodeproj`); document `xcodegen generate` + the plugin path both.

## CI & automation

- `ci.yml`: push/PR. `macos-15` runner (pin), `swift build` (root), `swift test`,
  build Examples package, `actions/cache` for `.cef/downloads` keyed on CEF version,
  `swift package ... cef bundle --product Browser`, smoke test: run
  `Browser.app/Contents/MacOS/Browser --cef-smoke-test` (the example exits 0 after first
  successful load when this flag is present — implement in example) under `timeout`.
- `cef-update.yml`: `schedule: cron '17 6 * * 1,4'` (Mon/Thu) + manual dispatch. Runs
  `Scripts/cef-update.sh`: conditional-GET index.json, pick max stable for both mac
  platforms, if newer than CEF_VERSION.json → rewrite manifest, download new minimal,
  re-vendor `Sources/CCef/.../include` tree, commit branch `cef-update/<version>`, open PR
  (gh), `gh pr merge --auto --squash`. Document the GITHUB_TOKEN-PRs-don't-trigger-CI
  pitfall: workflow uses a PAT secret `CEF_UPDATE_TOKEN` if present, else GITHUB_TOKEN with
  a doc note.
- Keep everything cheap: minimal flavor, single platform (arm64) in CI, cache hits.

## Tests (few, cheap)

`Tests/CefKitTests`: CefString round-trip, configuration→cef_settings mapping, refcount
helper sanity, version-manifest decode, plugin's plist generation logic if reachable.
No CEF runtime needed for unit tests (loader untested without framework — guard with
`XCTSkip` if framework missing).

## Style

Swift 6 language mode, `@MainActor` discipline over locks, no force-unwraps in library code,
doc comments on all public API (DocC-ready), errors with actionable messages (an
Apple-quality SDK explains how to fix). ObjC++ only if unavoidable (currently: not needed).
