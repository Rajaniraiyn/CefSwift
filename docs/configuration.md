# Configuration

Everything tunable in CefSwift, in three layers: the runtime
(`CefConfiguration`, set once at launch), per-browser options
(`CefBrowserOptions`), and build-time choices on the plugin (flavor, version,
platform).

## CefConfiguration

Supply it from your app type:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.remoteDebuggingPort = 9222
        return config
    }
    var body: some Scene { /* ... */ }
}
```

Or, without `CefSwiftApp`, pass it to
`CefRuntime.shared.initialize(configuration:)` yourself.

| Knob | Type / default | Effect |
|---|---|---|
| `noSandbox` | `Bool`, `true` | v1 always runs unsandboxed; see [sandbox.md](sandbox.md). |
| `rootCachePath` | `URL?`, `~/Library/Application Support/<bundle-id>/CefSwift` | Root for all profile data (cookies, local storage, caches). |
| `cachePath` | `URL?` | A specific profile directory under the root. Unset = "incognito-like" global profile semantics per CEF defaults. |
| `locale` | `String?` | UI locale, e.g. `"de"`. Defaults to the system locale. |
| `userAgentProduct` | `String?` | Product token inserted into the default Chromium user agent (e.g. `"MyApp/1.0"`). |
| `logSeverity` | `CefLogSeverity`, `.default` | `.verbose`/`.debug`/`.info`/`.warning`/`.error`/`.fatal`/`.disable`. |
| `logFile` | `URL?` | Chromium log destination (default: `debug.log` next to the cache). |
| `remoteDebuggingPort` | `Int?` | Opens the Chrome DevTools Protocol on `localhost:<port>` — attach Chrome's `chrome://inspect`, Playwright, etc. |
| `persistSessionCookies` | `Bool` | Keep session cookies across launches. |
| `safeStorage` | `CefSafeStoragePolicy`, `.automatic` | How cookies are encrypted at rest — real keychain vs mock key. `.automatic` skips the keychain (and its prompt) for ad-hoc-signed dev builds. See [the safe-storage section below](#the-keychain-chromium-safe-storage-prompt). |
| `defaultRuntimeStyle` | `CefRuntimeStyle`, `.default` (= chrome) | Default style for new browsers; see below. |
| `externalMessagePump` | `Bool`, `true` | Leave on. SwiftUI owns the run loop; see [architecture.md](architecture.md). |
| `frameworkDirectory` | `URL?` | Override where the CEF framework is found (default: the app bundle's `Contents/Frameworks/`). Useful for unbundled dev setups. |
| `browserSubprocessPath` | `URL?` | Override the helper executable path. |
| `extraCommandLineSwitches` | `[String: String?]` | Any Chromium switch — `nil` value for boolean switches: `["disable-gpu-shader-disk-cache": nil]`. |
| `onBeforeCommandLineProcessing` | closure | The last word: inspect/mutate the full `CefCommandLine` before Chromium parses it. |

## Runtime styles: chrome vs alloy

`CefRuntimeStyle` is the single most consequential knob.

### `.chrome` (the default)

The browser view is a real Chrome browser without Chrome's window chrome:

- **Tabs** exist under the hood (one per browser view), with Chrome's session
  and profile machinery.
- **Extensions** — Chrome extensions can load and run.
- **`chrome://` pages** — `chrome://history`, `chrome://extensions`,
  `chrome://settings`, `chrome://version`, `chrome://gpu`, … all work when
  navigated to.
- **Profiles** — Chrome's profile model backs the cache paths.
- Chrome's standard dialogs, permission prompts, find bar behavior, etc.

This is what you want for anything browser-shaped. See
[chrome-style.md](chrome-style.md).

### `.alloy`

CEF's traditional lightweight embedded style: no Chrome UI machinery, no
extensions, no `chrome://` internals — just a rendering engine in a view.
Slightly lighter, fully delegate-driven. Right for "a web card in my
dashboard" cases where you want zero browser semantics.

Set per browser via `CefBrowserOptions.runtimeStyle`, or globally via
`CefConfiguration.defaultRuntimeStyle`.

## CefBrowserOptions (per browser)

```swift
var options = CefBrowserOptions()
options.runtimeStyle = .alloy
options.backgroundColor = .windowBackgroundColor
let model = CefWebViewModel(url: url, options: options)
```

| Option | Effect |
|---|---|
| `runtimeStyle` | Chrome vs alloy for this browser only. |
| `backgroundColor` | Paint color before the page renders (kills the white flash in dark UIs). |

(Deliberately small in v1; more knobs land here as they prove necessary.)

## Build-time: plugin flags

The `cef` plugin chooses *which CEF binary* you run:

```sh
# Flavor: minimal (default) or standard (includes CEF debug build)
swift package ... cef download --flavor standard
swift package ... cef bundle --product MyApp --flavor standard

# Platform: defaults to the host; cross-download for the other Mac arch
swift package ... cef download --platform macosx64

# Version override: any exact CEF version string from cef-builds index
swift package ... cef download --cef-version "148.0.10+g7ee53f5+chromium-148.0.7778.218"

# Codesigning identity: '-' = ad-hoc; default auto-detects the first
# "Apple Development" identity, else "Developer ID Application", else ad-hoc
swift package ... cef bundle --product MyApp --sign "Apple Development: Jane Doe (TEAMID)"
```

`cef bundle` signs the whole bundle inside-out (framework → helpers → app).
The identity comes from, in order of precedence: the `--sign` flag, the
`"signingIdentity"` key in `cefapp.json` next to the target sources, then
auto-detection via `security find-identity -v -p codesigning`. Signing with a
real identity makes the keychain "Always Allow" grant stick across rebuilds
(see [the safe-storage section](#the-keychain-chromium-safe-storage-prompt)).

The pinned default lives in `CEF_VERSION.json` at the package root (the
plugin walks up to find the root manifest when invoked from the Examples
package, or accepts `--manifest <path>`). The pin is kept current
automatically — see [automation.md](automation.md).

Other plugin verbs: `cef info` (pinned version, cache state, flavors),
`cef clean` (delete the `.cef/` cache).

## The Keychain "Chromium Safe Storage" prompt

When Chromium first uses the real keychain it creates the key it encrypts
cookies with — the **"Chromium Safe Storage"** item — and macOS shows the
*"<YourApp> wants to use your confidential information stored in 'Chromium
Safe Storage'"* dialog. `CefConfiguration.safeStorage` decides whether that
ever happens:

```swift
config.safeStorage = .automatic     // the default
```

| Policy | Behavior |
|---|---|
| `.automatic` (default) | Dev builds (ad-hoc signed / unsigned): mock key, **no prompt ever**. Properly signed builds: real keychain, one-time prompt. |
| `.keychain` | Always use the user's keychain — exactly what Chrome does. One prompt; **Always Allow** sticks for signed builds. |
| `.mockKeychain` | Never touch the keychain (`--use-mock-keychain`). Cookies are "encrypted" with a fixed mock key — fine for demos, kiosks, and CI; not for browsing profiles you care about. |

**How `.automatic` detects a dev build:** at startup CefKit inspects the main
executable's static code signature (Security framework,
`SecCodeCopySigningInformation`). An empty/absent certificate chain means
ad-hoc or unsigned — the signature of every local `swift build` and of
`cef bundle`'s ad-hoc fallback — so the mock key is used and the prompt never
appears. A real certificate chain (Apple Development, Developer ID, App
Store) means the keychain is used, Chrome-style. If the signature can't be
inspected at all, CefKit conservatively assumes a properly signed build and
uses the real keychain — the safe failure mode for user data.

**Why the prompt re-appears for ad-hoc dev builds:** the keychain item's
access control list records the app's *code-signature identity*. Ad-hoc
signatures change on every rebuild, so the "Always Allow" grant can never
match the next build. Signing with a stable identity fixes this: `cef bundle`
auto-detects one (or take `--sign` / cefapp.json `"signingIdentity"`), and
Xcode-managed signing does the same. With a real identity the prompt is
one-time: click **Always Allow** once and it never returns, across rebuilds
and updates.

**Why the dialog can't be Touch ID or restyled:** it is the legacy keychain
ACL prompt, drawn by the macOS security daemon (`securityd`), not by your
app. There is no API to replace it, suppress it for the real keychain, or
upgrade it to Touch ID/local authentication. Chrome shows the exact same
dialog on first run.

User-specified switches always win: if you set `use-mock-keychain` yourself
in `extraCommandLineSwitches`, the policy never duplicates or overrides it.
