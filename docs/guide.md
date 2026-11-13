# Guide

Task-oriented reference for CefSwift. Snippets assume `import CefSwiftUI`,
which re-exports `CefKit`. The runtime, browser, window and profile APIs
are `@MainActor`.

- [Starting Chromium](#starting-chromium)
  - [Configuration](#configuration)
  - [Languages](#languages)
  - [Services and privacy](#services-and-privacy)
  - [Keychain access](#keychain-access)
  - [Enterprise policies](#enterprise-policies)
  - [Preferences](#preferences)
  - [Relaunching](#relaunching)
- [Browsers](#browsers)
  - [PDF](#pdf)
- [Showing a browser](#showing-a-browser)
  - [Offscreen rendering](#offscreen-rendering)
  - [Swipe navigation](#swipe-navigation)
  - [Offscreen accessibility](#offscreen-accessibility)
  - [Keyboard focus](#keyboard-focus)
- [Discarding browsers](#discarding-browsers)
- [Processes](#processes)
  - [Unresponsive pages](#unresponsive-pages)
- [JavaScript](#javascript)
  - [Frames](#frames)
  - [User scripts and style sheets](#user-scripts-and-style-sheets)
  - [Bridge](#bridge)
- [Decisions](#decisions)
  - [HTTP authentication](#http-authentication)
  - [Navigation and new windows](#navigation-and-new-windows)
  - [Downloads](#downloads)
  - [File choosers](#file-choosers)
  - [Passkeys](#passkeys)
- [Context menu](#context-menu)
- [Building a browser](#building-a-browser)
  - [Connection security](#connection-security)
  - [Client certificates](#client-certificates)
  - [Toolbar and window](#toolbar-and-window)
  - [Tabs](#tabs)
  - [Popups](#popups)
  - [Chrome commands](#chrome-commands)
  - [Chromium's own interface](#chromiums-own-interface)
  - [Tabs Chromium opens itself](#tabs-chromium-opens-itself)
- [Customizing Chromium's own pages](#customizing-chromiums-own-pages)
- [Profiles](#profiles)
  - [Network maintenance](#network-maintenance)
  - [Requests through Chromium's network stack](#requests-through-chromiums-network-stack)
  - [Site settings](#site-settings)
  - [Bookmarks, history and suggestions](#bookmarks-history-and-suggestions)
- [DevTools](#devtools)
- [Compatibility with bot protection](#compatibility-with-bot-protection)
- [Serving your own content](#serving-your-own-content)
- [Playing streaming services](#playing-streaming-services)
  - [Widevine in Chromium](#widevine-in-chromium)
  - [WebKit and FairPlay](#webkit-and-fairplay)
  - [Services](#services)
- [Footprint and launch time](#footprint-and-launch-time)
- [Known limits](#known-limits)

## Starting Chromium

A SwiftUI app conforms to `CefSwiftApp` instead of `App`. Before SwiftUI
starts, it installs the `NSApplication` subclass Chromium needs
(`CefApplication`) and calls `CefRuntime.shared.initialize(configuration:)`
with `runtimeConfiguration`:

```swift
@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        configuration.isOffscreenRenderingEnabled = true
        return configuration
    }

    init() {
        // Chromium is running here; register scheme handlers before any page loads.
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

If Chromium cannot start, `CefSwiftApp` prints the reason and exits with
status 1. If another instance of the app already uses the same data
directory, Chromium hands the launch to it and this process exits with
status 0; see [Relaunching](#relaunching).

An AppKit app initializes the runtime first thing in `main`, before anything
touches `NSApp`:

```swift
@main
@MainActor
enum Main {
    static func main() {
        do {
            try CefRuntime.shared.initialize(configuration: .embedded)
        } catch .anotherInstanceRunning {
            exit(0)
        } catch {
            fatalError("\(error)")
        }
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        withExtendedLifetime(delegate) { NSApp.run() }
    }
}
```

Quitting through `NSApp.terminate(_:)` closes every browser first, so pages
can run `beforeunload` handlers, and then shuts Chromium down; there is no
shutdown call of your own to make. `CefRuntime.shared.state` goes from
`.notStarted` through `.starting` to `.running`, and at quit through
`.stopping` to `.stopped`. Chromium starts once per process: `initialize`
throws `CefError.alreadyInitialized` while it runs and `CefError.shutDown`
after it has stopped.

### Configuration

Start from a preset and change what you need:

| Preset | Use |
|---|---|
| `CefRuntime.Configuration.embedded` | Showing your own or trusted web content. Turns off background networking, component updates, Widevine, sync, translation, preloading, hyperlink auditing, password saving and autofill, first-run and default-browser prompts, and starts renderer processes only when a page needs one. |
| `CefRuntime.Configuration.browser` | A general-purpose browser. Keeps session cookies across launches and skips first-run and default-browser prompts; everything else is as Chromium has it and as users set it in `chrome://settings`, Widevine included. |
| `CefRuntime.Configuration()` | Chromium's defaults. |

Common options:

| Property | Effect |
|---|---|
| `isOffscreenRenderingEnabled` | Required for `.offscreen` browsers. Off by default. |
| `customSchemes` | URL schemes of your own, registered in every Chromium process. See [Serving your own content](#serving-your-own-content). |
| `preferences` | Chromium preferences by dotted name. See [Preferences](#preferences). |
| `productName`, `stringOverrides` | Your product name, and replacements for other built-in strings. See [Customizing Chromium's own pages](#customizing-chromiums-own-pages). |
| `chromeToolbar` | Hides Chrome app-menu commands, toolbar buttons and page-action icons in Chrome-style windows. |
| `extensions` | Unpacked extension folders (each with a `manifest.json`) to load. Extensions run in Chrome-style browsers. |
| `processPolicy` | How many helper processes Chromium keeps running. See [Footprint and launch time](#footprint-and-launch-time). |
| `enabledFeatures`, `disabledFeatures` | Chromium feature names, passed as `--enable-features` and `--disable-features`. |
| `safeStorage`, `keychainItem` | Whether Chromium uses the keychain, and which item. See [Keychain access](#keychain-access). |
| `services`, `network`, `privacy`, `security`, `credentials` | Component updates, protected media and translation; preloading and DNS over HTTPS; third-party cookies and hyperlink auditing; HTTPS-First; password saving and autofill. See [Services and privacy](#services-and-privacy). |
| `enterprisePolicy` | Whether Chromium applies administrator-managed policies, and from which preferences domain. See [Enterprise policies](#enterprise-policies). |
| `authenticationPrompt` | Who asks for HTTP sign-in credentials. See [HTTP authentication](#http-authentication). |
| `services.protectedMedia` | Whether Chromium fetches Google's Widevine CDM for protected (DRM) media: `.automatic`, `.disabled` (the `.embedded` preset), or `.preinstalled(widevineDirectory:)`. See [Playing streaming services](#playing-streaming-services). |
| `rootCacheDirectory`, `cacheDirectory` | Where profile data lives. Defaults to `~/Library/Application Support/<bundle ID>/CefSwift`. |
| `persistsSessionCookies` | Whether session cookies survive a relaunch. |
| `localization`, `acceptLanguages` | The language of Chromium's own interface, and the languages pages are offered. See [Languages](#languages). |
| `userAgent` | How the browser names itself to sites: Chromium's own, with your product's token, or a string of your own. See [Compatibility with bot protection](#compatibility-with-bot-protection). |
| `logSeverity`, `logFile` | Chromium's log. |
| `remoteDebuggingPort` | Exposes the DevTools Protocol on a localhost port. Leave it `nil` in shipping apps. |
| `isSandboxEnabled` | Chromium's macOS sandbox for the helper processes. On by default; see [Sandbox](sandbox.md). |
| `extraCommandLineSwitches`, `onBeforeCommandLineProcessing` | Any other Chromium switch, such as `["proxy-server": "socks5://localhost:1080"]`. |
| `frameworkDirectory`, `helperExecutableURL` | Override where the framework and helper are found. Rarely needed. |

### Languages

`configuration.localization` chooses the language of Chromium's own
interface: menus, dialogs, error pages, `chrome://` pages and the strings
Chromium gives pages, such as a date picker's.

| Policy | Language |
|---|---|
| `.application` (default) | The app's: the localization macOS picks for the app from those it has (`Bundle.main.preferredLocalizations`), which follows the user's language order and the per-app language in System Settings. An English-only app shows Chromium in English. |
| `.system` | The first of the user's preferred languages (`Locale.preferredLanguages`) that Chromium has strings for. |
| `.fixed("de")` | That language. |

CefKit resolves the policy before Chromium starts, against the locale packs
the bundle contains (`cef bundle` keeps those of the app's localizations; see
[Bundling](bundling.md#locale-packs)): the first choice with a pack, else
the app's development language, else English (`en-US`).
`CefRuntime.shared.locale` is the result, such as `"fr"`, `"pt-BR"` or
`"en-US"`. Identifiers map onto Chromium's locales as Chromium matches
them: `zh-Hans` is `zh-CN` and `zh-Hant` is `zh-TW`; `pt` is `pt-BR`;
Spanish for Latin America and the US is `es-419`; English outside the US is
`en-GB`; `iw`, `tl`, `in` and `no` are `he`, `fil`, `id` and `nb`. Chromium
reads the locale once; a change applies at the next launch.

Telling Chromium a locale itself (`extraCommandLineSwitches["lang"]`)
bypasses that check. For a locale without a pack, Chromium starts with a
locale name its strings do not match: it reports the requested locale and
shows English text.

`acceptLanguages` lists the languages pages are offered, the
`Accept-Language` header and `navigator.languages`, most preferred first.
Empty, the default, takes the user's preferred languages at start-up,
whatever the interface language: a French user of an English-only app gets
English menus and French pages. Chromium adds each language's base
(`fr-CA` brings `fr`) to the header. The list applies at every launch and
wins over the languages a user picks in `chrome://settings/languages`. A
profile can have a list of its own; set it before the profile's first
browser:

```swift
let profile = CefProfile.persistent(id: "client")
profile.acceptLanguages = ["de-CH", "fr"]
```

Spelling follows the spelling language of macOS (Keyboard settings, Text
Input), as in Chrome on macOS; `spellcheck.dictionaries` reports it and
`browser.enable_spellchecking` turns checking off.

### Services and privacy

Typed options for what Chromium does on its own. Each defaults to
Chromium's behavior, which users can change in `chrome://settings` where
Chromium offers the setting; any other value is set again at every launch
and wins over what users chose there. A key in `preferences` wins over the
typed option that sets the same preference.

| Option | Values | Chromium setting | Scope |
|---|---|---|---|
| `services.componentUpdates` | `.automatic`, `.disabled` | `--disable-component-update` | App, at start-up |
| `services.translation` | `.automatic`, `.disabled` | `translate.enabled` | Every profile |
| `network.preloading` | `.automatic`, `.standard`, `.extended`, `.disabled` | `net.network_prediction_options` | Every profile |
| `network.secureDNS` | `.automatic`, `.disabled`, `.secure(templates:)` | `dns_over_https.mode`, `dns_over_https.templates` | App |
| `privacy.thirdPartyCookies` | `.automatic`, `.block` | `profile.cookie_controls_mode` | Every profile |
| `privacy.hyperlinkAuditing` | `.automatic`, `.disabled` | `--no-pings` | App, at start-up |
| `security.httpsFirst` | `.automatic`, `.balanced`, `.strict` | `https_first_balanced_mode_enabled`, `https_only_mode_enabled` | Every profile |
| `credentials.passwordSaving` | `.automatic`, `.disabled` | `credentials_enable_service`, `credentials_enable_autosignin` | Every profile |
| `credentials.autofill` | `.automatic`, `.disabled` | `autofill.profile_enabled`, `autofill.credit_card_enabled` | Every profile |

```swift
var configuration = CefRuntime.Configuration.browser
configuration.privacy.thirdPartyCookies = .block
configuration.security.httpsFirst = .balanced
configuration.network.secureDNS = .secure(templates: ["https://dns.example/dns-query{?dns}"])
```

- Component updates keep data files current: certificate revocation
  (CRLSet) and Certificate Transparency lists, Safe Browsing file-type and
  SSL error lists, origin trials, subresource filter rules, and the
  Widevine CDM. Turned off, Chromium registers none of them; it still
  fetches one component of its own, the on-device model manifest, which
  no switch stops ([design notes](design-notes.md#locale-packs-swiftshader-and-component-updates)). Protected
  media that needs Widevine keeps the updater on, since the CDM arrives
  through it; see [Widevine in Chromium](#widevine-in-chromium).
- Preloading covers DNS prefetch, preconnect, prefetch and prerender.
  `.disabled` saves those requests; navigations can take longer.
- `.secure(templates:)` sends every lookup to those DNS-over-HTTPS servers,
  which can bypass a network's split DNS or VPN resolver.
- Blocking third-party cookies can break sign-in, payment and comment
  widgets embedded from another site.
- `.strict` HTTPS-First warns before every HTTP page, intranet and device
  pages included; `.balanced` warns only for sites that usually have HTTPS.
- `passwordSaving = .disabled` stops Chromium from offering to save
  passwords and from signing in automatically; it still fills passwords the
  profile saved earlier.
- Hyperlink auditing is the request an `<a ping>` link sends when it is
  followed. Pages can still send requests of their own.

Chromium 156 keeps the Privacy Sandbox ad APIs (Topics, Protected Audience,
ad measurement) off: their preferences default to off and are cleared at
start-up, and no setting turns them on, so there is no option for them.

### Keychain access

Chromium encrypts cookies and saved passwords with a key it keeps in an
item of the user's keychain. The first time an app reads that item, macOS
asks the user to allow it. Choosing Always Allow records the
app's code signature, so the question does not come back while the signature
stays the same. An ad hoc signature changes with every build, so ad hoc
signed builds are asked again after each rebuild.

`configuration.safeStorage` chooses the behavior, and
`configuration.keychainItem` the item:

| Policy | Behavior |
|---|---|
| `.automatic` (default) | `.keychain` when the app is signed with a team identity, such as an Apple Development or Developer ID certificate; `.mockKeychain` when it is unsigned or ad hoc signed. |
| `.keychain` | Always use the keychain, as Chrome does. |
| `.mockKeychain` | Use a fixed key and never touch the keychain (`--use-mock-keychain`). Nothing is protected at rest; use it for development, demos and tests. |

| `keychainItem` | Item |
|---|---|
| `.application` (default) | The app's own: service "`<bundle identifier>` Safe Storage", account "`<bundle identifier>`". Other apps built on Chromium cannot read it. |
| `.chromium` | Chromium's "Chromium Safe Storage", shared by every app built on stock Chromium or CEF that names no other. |
| `.named(service:account:)` | An item of your choice, for instance one several of your apps share. |

The item holds the key, so a different item means a different key:
cookies and passwords a profile saved under the old item cannot be read
under the new one, and Chromium drops them. Choose the item before you
ship. `keychainItem` applies only while Chromium uses the keychain; the mock
keychain of ad hoc builds has no item.

`cef bundle` signs with your Apple Development or Developer ID identity
when the keychain has one; [bundling](bundling.md#distribution) lists what
each kind of signature allows.

### Enterprise policies

Chromium applies the policies an administrator manages for Chrome
(`HomepageLocation`, `PasswordManagerEnabled`, `URLBlocklist`, …) only
from a preferences domain the app names:

```swift
configuration.enterprisePolicy = .applicationBundleIdentifier   // or .domain("com.google.Chrome")
```

| `enterprisePolicy` | Domain |
|---|---|
| `.disabled` (default) | None: no policies apply. |
| `.applicationBundleIdentifier` | The app's bundle identifier, which an administrator manages as they would `com.google.Chrome`. |
| `.domain(_:)` | Another domain, such as Chrome's, to follow what is managed for Chrome. |

Values a configuration profile forces (`/Library/Managed Preferences`)
are mandatory policies: users cannot change them. Values in the user's
own preferences for the domain, such as `defaults write <domain>
ShowHomeButton -bool true`, are recommended policies: they set the
default, which users can change. On a Mac that is not managed, Chromium
ignores the policies it counts as sensitive. `chrome://policy`, in a
Chrome-style browser, lists what applies. The app's own `UserDefaults`
are not policies unless the domain is the app's and the names are
Chromium's.

### Signing and capabilities

`CefRuntime.shared.capabilities` (also `CefAppCapabilities.current`)
describes what the running app's signature, entitlements and Info.plist let
Chromium do, so the app can adapt its UI:

```swift
let capabilities = CefRuntime.shared.capabilities
if !capabilities.passkeyAuthenticators.contains(.iCloudKeychain) {
    // Offer the app's own passkeys (CefBrowser.PasskeyPolicy.app) instead.
}
```

| Property | Value |
|---|---|
| `signature` | `.unsigned`, `.adHoc`, `.development`, `.developerID`, `.appStore` or `.other` (a certificate without an Apple team). |
| `teamIdentifier` | The team of an Apple certificate, else nil. |
| `isHardenedRuntime`, `isAppSandboxed` | From the signature's flags and entitlements. |
| `entitlements`, `keychainAccessGroups` | The entitlements the signature grants. |
| `usageDescriptions` | The `NS…UsageDescription` keys in the Info.plist. |
| `passkeyAuthenticators` | `.securityKey`, `.hybrid`, `.touchID`, `.iCloudKeychain`: what `.chromium` passkeys can offer. |
| `canLoadWidevine` | Whether the base helper can load Google's Widevine CDM: false for a team-signed hardened helper without `disable-library-validation` (the `protectedMedia` capability). |
| `resolvedSafeStorage(_:)` | The safe-storage policy Chromium gets for a configured one. |

At start-up CefSwift logs one line (subsystem `CefSwift`) naming what the
signature leaves out, such as "Chromium passkeys offer only security keys".
`swift package cef doctor <App.app>` reports the same for a bundle on disk.

### Preferences

`preferences` sets Chromium preferences, the settings behind
`chrome://settings`, by dotted name. Each applies to every profile when the
profile is first used, or once at start-up to the few preferences Chromium
keeps for the whole app:

```swift
configuration.preferences["credentials_enable_service"] = false   // per profile: no password manager
configuration.preferences["webkit.webprefs.default_font_size"] = 18
configuration.preferences["browser.confirm_to_quit"] = false      // application-wide
```

To read or change them later, use a profile's `preferences` for
per-profile settings ([Profiles](#profiles)), and the runtime's for
application-wide ones:

```swift
let confirms = CefRuntime.shared.preferences.value(named: "browser.confirm_to_quit")?.boolValue
try CefRuntime.shared.preferences.setValue(false, named: "browser.confirm_to_quit")
```

`value(named:)` returns `nil` for an unknown name. `setValue(_:named:)`
throws `CefError.operationFailed` for an unknown name or a value of the wrong
type, and restores the default when passed `nil`. Values are `CefJSON`,
which accepts Swift literals.

`CefProfile.preferences` and `CefRuntime.shared.preferences` also give
preferences typed keys, observation and their state. A `CefPreferences.Key`
names a preference with the Swift type of its value; the common ones are
static members, and `Key<Bool>("dotted.name")` makes others:

```swift
let preferences = profile.preferences
try preferences.set(false, for: .savesPasswords)
let size = preferences[.defaultFontSize]                 // Int?
try preferences.set(["de", "en-US"], for: .acceptLanguages)
try preferences.reset(.acceptLanguages)                  // its default again

for await languages in preferences.observe(.acceptLanguages) {
    print(languages ?? [])                               // now, then on each change
}
```

`canSet(_:)` is `false` for a preference an enterprise policy manages or a
command-line switch set; Chromium does not say which of the two.
`isDefault(_:)` tells whether anything set a preference. Chromium has no
call that reads a default while another value is set, so to see one,
`reset(_:)` the preference. `observe(_:)` yields the value first, then each
change, from Chromium's settings pages as well as from your code, for as
long as you iterate it.

### Relaunching

Only one process can use a data directory, so an app runs as a single
instance. When it is launched again while running, from the command line or
by another app, the new process hands its arguments to the running one and
exits. The running app is brought to the front and
`CefRuntime.shared.onRelaunch` receives the new launch's arguments, without
the program path, and its working directory:

```swift
CefRuntime.shared.onRelaunch = { arguments, workingDirectory in
    let urls = arguments.compactMap(URL.init(string:)).filter { $0.scheme != nil }
    if urls.isEmpty { openTab(nil) } else { urls.forEach(openTab) }
}
```

Resolve relative file paths against `workingDirectory`. Without a handler,
a relaunch only brings the app to the front.

## Browsers

`CefBrowser` is the model of one browser: an `@Observable` object with the
page's state and the commands you can send it. Create it, bind views to it,
and hand it to a view or window. Chromium creates the underlying browser
when it is first shown.

| Kind | Members |
|---|---|
| State | `url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`, `favicon`, `faviconURL`, `zoomLevel`, `isFullscreen`, `statusText`, `downloads`, `findResult`, `state` (`.pending`, `.live`, `.closed`) |
| Navigation | `load(_:)` (returns a `CefNavigation`), `goBack()`, `goForward()`, `reload(ignoringCache:)`, `stopLoading()`, `waitUntilLoaded(timeout:)` ([waiting for a load](#waiting-for-a-load)) |
| Page | `isAudioMuted`, `find(_:backwards:caseSensitive:)`, `stopFinding(clearingSelection:)`, `findSession` (an observable find-bar model), `print()`, `pdf(configuration:)`, `printToPDF(at:configuration:)` ([PDF](#pdf)), `snapshot()` |
| JavaScript | `evaluateJavaScript(_:timeout:)`, `evaluateJavaScript(_:as:timeout:)`, `executeJavaScript(_:)`, `addUserScript(_:)` |
| DevTools | `devTools`, `showDevTools(inspecting:)`, `closeDevTools()`, `isShowingDevTools` |
| Lifetime | `ready()`, `close(force:)` |
| Memory | `isDiscarded`, `discard()`, `restore()`, `discardBlockers()`, `discardSnapshot`, `lifecycle`, `lifecycleChangedAt` ([discarding](#discarding-browsers)) |
| Relations | `delegate`, `configuration`, `opener`, `popupFeatures`, `hostWindow` |

Options are fixed at creation:

```swift
var browserConfiguration = CefBrowser.Configuration()
browserConfiguration.profile = .persistent(id: "work", displayName: "Work")
browserConfiguration.backgroundColor = .windowBackgroundColor
browserConfiguration.requestFilter = { request in
    request.url?.host() == "ads.example" ? .block : .allow
}
let browser = CefBrowser(url: URL(string: "https://swift.org")!, configuration: browserConfiguration, delegate: policy)
```

A `requestFilter` sees every network request and returns `.allow`, `.block`,
`.redirect(_:)` or `.setHeaders(_:)`. Chromium waits for the answer on its
IO thread, so the filter runs there, isolated to `CefIOActor`, and must be
fast. State it keeps on `CefIOActor` needs no lock; state on the main actor
it cannot read. Keep a copy on `CefIOActor` and update it from the main
actor:

```swift
@CefIOActor var blockedHosts: Set<String> = []

browserConfiguration.requestFilter = { @CefIOActor request in
    blockedHosts.contains(request.url?.host() ?? "") ? .block : .allow
}

// When the user edits the list, on the main actor:
let hosts = Set(settings.blockedHosts)
Task { @CefIOActor in blockedHosts = hosts }
```

`CefIOActor` runs on Chromium's IO thread, which carries every request
and message between processes: never block it. `CefFileActor` runs on
Chromium's sequence for blocking work the user waits on, such as reading
files.

`favicon` is the page's icon as an `NSImage`, downloaded at up to 32 points
from the address in `faviconURL`. Both are `nil` until the page reports an
icon, and become `nil` again when a new main-frame document starts loading.
For pages that are not open, use
[`profile.history.favicon(for:size:)`](#bookmarks-history-and-suggestions).

`zoomLevel` is 0 for 100%, and each step of 1 scales the page by 20%. You can
set it, and it follows the zoom Chromium applies: the level it remembers for
each site, restored as the browser moves between sites, and Chrome's zoom
commands. CEF does not report zoom changes, so CefKit reads the level back
after navigations, zoom commands and changes made through `zoomLevel`; other
changes show up at the next navigation. In a windowed browser, pinching
magnifies the page without changing `zoomLevel`.

A browser holds its `delegate` weakly, as `WKWebView` does. Keep a strong
reference to the delegate for as long as the browser lives; a delegate
created inline, as in `CefBrowser(url: url, delegate: Policy())`, is
released at once and the browser falls back to the default decisions.

A browser you create lives until you call `close()`. Unless you pass
`force: true`, the page's `beforeunload` handler can ask the user to stay.
After `state` becomes `.closed`, create a new `CefBrowser` to browse again.

### Waiting for a load

`load(_:)` returns the `CefNavigation` it started. Await it to continue
once that page has loaded:

```swift
let result = try await browser.load(url).waitUntilLoaded(timeout: .seconds(30))
print(result.url as Any, result.httpStatus ?? 0)
```

`waitUntilLoaded(timeout:)` on the browser waits for whatever it loads
now, and returns at once when it has loaded already. It suits a browser
just created, a reload, or a page that navigates by itself:

```swift
let browser = CefBrowser(url: home)
// …once a view or window shows it:
try await browser.waitUntilLoaded(timeout: .seconds(30))
```

CEF gives navigations no identity of their own. The navigation a
`CefNavigation` stands for is the first main-frame navigation Chromium
starts as a direct load after `load(_:)` was called; links, scripts,
reloads and history steps do not count as it. Each wait ends in exactly
one of these ways:

| Outcome | What the wait returns or throws |
|---|---|
| The document committed and its `load` event ran | `CefLoadResult`: the final `url` after redirects, the `httpStatus` |
| A server redirect, or a script or `<meta>` refresh navigating before the page finished | Part of the same navigation; `url` is where it ended |
| Only the fragment differs from the page shown | Finishes as the address changes, with `isSameDocument` set |
| A network or HTTP-level failure | The `CefLoadError` the delegate's `didFailLoad` gets |
| No new page: a download, a 204 or 205 response, `stopLoading()`, the delegate cancelling it | `CefLoadError` with `isCancellation` (`ERR_ABORTED`) |
| Another `load(_:)`, a link, a script, back or forward starts first | `CefError.navigationSuperseded` |
| The renderer crashed while the document loaded (`chrome://crash` included) | `CefError.renderProcessTerminated(_:)` |
| The browser closed | `CefError.browserClosed` |
| `timeout` ran out | `CefError.timedOut`; the navigation goes on |
| The waiting task was cancelled | `CancellationError`; the navigation goes on |

The browser-wide `waitUntilLoaded(timeout:)` follows a superseded
navigation to the one that replaced it, so it ends only when the browser
has settled; when the last navigation failed, it throws that error, even
if the browser settled earlier. A browser not created yet waits for its
first page, and a discarded browser is restored first. A load asked of a
browser that is still being created, setting up or discarded starts once
it can, and is not superseded by the browser's own set-up.

### PDF

`pdf(configuration:)` renders the page as PDF data, and
`printToPDF(at:configuration:)` writes it to a file. A
`CefBrowser.PDFConfiguration` starts from the user's Page Setup: the paper
size of `NSPrintInfo.shared`, portrait, Chromium's default margins,
backgrounds printed, and a tagged PDF, which assistive apps read in order,
with an outline made from the page's headings.

```swift
var configuration = CefBrowser.PDFConfiguration()
configuration.isLandscape = true
configuration.margins = .uniform(36)                     // points
configuration.pageRanges = [1...2, 5...5]
configuration.footerTemplate = """
    <div style="font-size: 9px; margin: auto">
      <span class=pageNumber></span> / <span class=totalPages></span>
    </div>
    """
let data = try await browser.pdf(configuration: configuration)
```

Sizes and margins are in points. `prefersCSSPageSize` uses the size a
page's `@page` rule asks for instead of `paperSize`; a page whose rule
gives a size keeps that size's orientation whatever `isLandscape` says.
Header and footer templates fill in elements with the classes `date`,
`title`, `url`, `pageNumber` and `totalPages`; give them a font size, since
Chromium sets none. A page range past the last page, or ranges that leave
no page, make the call throw.

## Showing a browser

`CefWebView` shows a browser in SwiftUI:

```swift
struct Reader: View {
    @State private var browser = CefBrowser(url: URL(string: "https://swift.org")!)

    var body: some View {
        CefWebView(browser)
            .navigationTitle(browser.title)
            .toolbar {
                Button("Back", systemImage: "chevron.left", action: browser.goBack)
                    .disabled(!browser.canGoBack)
            }
    }
}
```

`CefWebView(_:)` never closes the browser you give it, so the browser
survives the view leaving and re-entering the hierarchy and can move to
another view. `CefWebView(url:configuration:)` creates and owns its browser,
loads a new URL when `url` changes, and closes the browser when the view
goes away.

`CefBrowser.Configuration.rendering` picks how the page draws:

| Rendering | How it draws | Use |
|---|---|---|
| `.windowed` (default) | Chromium's own `NSView` inside yours. Chromium handles input, IME and accessibility. | Most embedding. Nothing can be drawn over the page. |
| `.offscreen` or `.offscreen(frameRate:)` | Frames composited in a layer. | SwiftUI content over the page, clipping, animation. |

In AppKit, assign the browser to a `CefWindowedBrowserView` or
`CefOffscreenBrowserView` (both in `CefSwiftUI`), or call
`browser.host(windowedIn:)` with a view of your own.

Views embed browsers in the Alloy runtime style, which has no `chrome://`
pages, extensions or history. For those, use a
[`CefBrowserWindow`](#building-a-browser).

### Offscreen rendering

Offscreen browsers need `configuration.isOffscreenRenderingEnabled = true`.

```swift
var browserConfiguration = CefBrowser.Configuration()
browserConfiguration.rendering = .offscreen(frameRate: 120)
browserConfiguration.allowsBackForwardNavigationGestures = true
let browser = CefBrowser(url: url, configuration: browserConfiguration)
```

Pinch and smart magnify change `zoomLevel`. Set
`CefBrowser.Configuration.forwardsRawTouchEvents = true` to send trackpad touches to the
page instead of interpreting them as gestures.

Offscreen browsers cannot open native popup windows: a request that would
open one loads in the same browser instead (see
[Navigation and new windows](#navigation-and-new-windows)).

To draw offscreen frames in a view of your own, adopt `CefOffscreenHost` and
call `browser.host(offscreenIn:size:)`. The host receives frames, cursors,
IME ranges, context menus and drags. A frame's `IOSurface` comes from
Chromium's pool and is valid only during the call: Chromium renders later
frames into it, even while a layer still shows it, so copy it into a
surface of your own before returning, as `CefOffscreenBrowserView` does
with a Metal blit (see [Frame ownership](architecture.md#frame-ownership)).
In return the host drives the browser as AppKit drives a view:

- Lifecycle: `hostViewDidResize()`, `hostViewDidHide()`,
  `hostViewDidUnhide()`, `hostViewDidBecomeKey()`, `hostViewDidResignKey()`,
  `hostViewDidChangeBackingProperties()`, and `hostViewDidMove()` when the
  view's window moves.
- Input: `sendMouseMove(to:modifiers:)`,
  `sendMouseDown(at:button:clickCount:modifiers:)`,
  `sendMouseUp(at:button:clickCount:modifiers:)`,
  `sendMouseExit(at:modifiers:)`, `sendScrollWheel(at:delta:modifiers:)`,
  `sendKeyEvent(_:)`, `sendTouchEvent(_:)`.
- Text input: `setMarkedText(_:selectedRange:replacementRange:)`,
  `insertText(_:replacementRange:)`, `unmarkText(keepingSelection:)`,
  `cancelComposition()`.
- Drag and drop: `draggingEntered(…)`,
  `draggingUpdated(at:modifiers:allowedOperations:)`, `draggingExited()`,
  `performDrop(at:modifiers:)` and `draggingSessionEnded(at:operation:)`,
  which mirror `NSDraggingDestination` and `NSDraggingSource`.

`CefOffscreenBrowserView` is the reference implementation.

### Swipe navigation

With `CefBrowser.Configuration.allowsBackForwardNavigationGestures`, a two-finger swipe that
starts sideways (when the system's "Swipe between pages" setting allows it)
and the dedicated navigation swipe go back and forward, in `CefWebView`,
both renderings, and in `CefBrowserWindow`, where Chrome's own swipe
handling does the work. It is off by default everywhere.

While a swipe is in progress, `browser.navigationGestureProgress` moves from
0 toward -1 (back) or 1 (forward); at ±1 and beyond, releasing navigates.
`CefBrowser.Configuration.navigationGestureIndicator` chooses what is drawn over the page:

| Indicator | Drawing |
|---|---|
| `.automatic` (default) | CefSwift's: a chevron in a circle that slides in from the edge, resists past the commit point, and fills with the accent color once releasing navigates. |
| `.chromium` | Chrome's own arrow, in `CefBrowserWindow`; `.automatic` elsewhere. |
| `.hidden` | Nothing; draw your own from `navigationGestureProgress`. |

To replace the indicator with a SwiftUI view:

```swift
CefWebView(browser)
    .navigationGestureIndicator { progress in
        Image(systemName: progress < 0 ? "chevron.left" : "chevron.right")
            .padding(12)
            .background(.regularMaterial, in: .circle)
            .frame(maxWidth: .infinity, alignment: progress < 0 ? .leading : .trailing)
            .opacity(min(1, abs(progress)))
    }

window.setNavigationGestureIndicator { progress in MyIndicator(progress: progress) }   // a CefBrowserWindow
```

In AppKit, `CefWindowedBrowserView` and `CefOffscreenBrowserView` turn the
built-in indicator off with `showsBuiltInGestureIndicator = false`, and
`CefBrowserWindow.navigationGestureIndicatorView` takes a view of your own.

A view claims a swipe as it begins, when there is history in its direction,
so the page does not also scroll sideways; in a `CefBrowserWindow`, Chrome
lets the page scroll first and swipes only at its edge.

### Offscreen accessibility

VoiceOver, Voice Control, Full Keyboard Access, Accessibility Inspector and
UI tests read an offscreen page as they read a windowed one. The view is an
`AXGroup` whose child is the page's `AXWebArea`, and below it are the
page's headings, links, buttons, text fields, checkboxes, lists, tables,
images, landmarks and frames, with their frames on screen, hit testing,
keyboard focus, and the notifications assistive apps follow (focus, value,
selected text, layout, load complete and live-region announcements).

Chromium builds the tree only when something reads it, because keeping it
costs renderer time and memory on every change. `offscreenAccessibility`
decides when:

| Value | The tree is built |
|---|---|
| `.automatic` (default) | When VoiceOver is running, when an assistive app first asks the view for its children, hit-tests it or asks for its focused element, or when an app sets `AXEnhancedUserInterface` or `AXManualAccessibility` on the application, as Voice Control and automation tools do. It then stays on for the browser's lifetime. |
| `.enabled` | From creation. |
| `.disabled` | Never. The page is a single element. |

```swift
browserConfiguration.offscreenAccessibility = .enabled
```

`setAccessibilityEnabled(_:)` turns the tree on or off at any time,
whatever the option says, and `isAccessibilityEnabled` reports it.

Actions from assistive apps reach the page as the user's own input would:
pressing clicks the element's centre, incrementing and decrementing press
the arrow keys, and setting a text field's value selects its text and
inserts the new text as an input method does. Focusing an element and
scrolling it into view use the DevTools protocol's `DOM.focus` and
`DOM.scrollIntoViewIfNeeded`.

A host of your own reads the same model: `browser.accessibilityTree` is a
`CefAccessibilityTree` of `CefAccessibilityNode`s with frames in view
points, `offscreenAccessibilityTreeDidChange(_:)` reports each change, and
`browser.performAccessibilityAction(_:on:)` carries out actions. For tests
and diagnostics, `CefOffscreenBrowserView.didPostAccessibilityNotification`
reports every notification the view posts.

### Keyboard focus

`CefWindowedBrowserView` and `CefOffscreenBrowserView` take part in the
window's key-view loop like any control. Tab from the control before the
view focuses the page's first focusable element, Shift-Tab from the control
after it the page's last. Tab past the page's last element (or Shift-Tab
past its first) moves on to the next (or previous) key view outside the
browser's view:

```swift
nameField.nextKeyView = browserView
browserView.nextKeyView = sendButton
```

Chromium reports a page giving up focus natively (`on_take_focus`). It has
no call for focusing a page's first or last element, so entering the page
clears its focused element with one `blur()` in the page's main world and
presses Tab (or Shift-Tab) for it. An offscreen view of your own calls
`hostViewDidBecomeKey(selecting:)` with the window's
`keyViewSelectionDirection` from `becomeFirstResponder()`.

## Discarding browsers

A browser the user is not looking at can give back its page's memory
while staying in your UI. Discarding ends the page's renderer process; the
browser keeps its `url`, `title` and `favicon`, and loads the page again
as soon as it is shown, navigated or used. `isDiscarded` is observable, so
a tab can fade while it sleeps:

```swift
Image(nsImage: browser.favicon ?? fallbackIcon)
    .opacity(browser.isDiscarded ? 0.4 : 1)
```

CefKit provides the capability; when to use it is your app's policy.
CefKit never discards a browser on its own:

```swift
do {
    try await tab.discard()
} catch .blocked(let blockers) {
    print("kept loaded:", blockers)          // [.visible], [.playingAudio], …
}
```

A policy such as "sleep tabs hidden for an hour, and every hidden tab when
memory is low" takes a timer, a `DispatchSource.makeMemoryPressureSource`,
and how long each browser has been hidden, which `lifecycle` and
`lifecycleChangedAt` tell:

```swift
for browser in CefRuntime.shared.browsers
where browser.lifecycle == .hidden && .now - browser.lifecycleChangedAt > .seconds(60 * 60) {
    try? await browser.discard()
}
```

The Browser example's Memory Saver (`Examples/Sources/Browser/TabDiscarding.swift`)
is a complete one, with exemptions left to the app: a tab the user pinned is
simply never passed to `discard()`.

Only a browser that is off screen can be discarded: a window tab that is
not selected, a hidden or minimized window, or a `CefWebView` that is
hidden or out of a visible window. `discardBlockers()` lists what keeps a
browser loaded, and `discard()` throws `CefBrowser.DiscardError.blocked` with the
same set:

| Blocker | When |
|---|---|
| `.visible` | The browser is on screen. |
| `.exempt` | Chromium protects the tab: an extension, pinning, or a setting or enterprise policy. |
| `.notLoaded` | The browser is not open yet, is loading, or shows DevTools itself. |
| `.playingAudio` | The page plays sound, or did in the last minute. |
| `.capturingMedia` | The page uses the camera, microphone or screen capture, or is cast. |
| `.formInteraction` | The user typed into the page. |
| `.beforeUnloadHandler` | The page has a `beforeunload` handler. |
| `.devToolsOpen` | The browser's DevTools window is open. |
| `.downloading` | A download it started is in progress. |
| `.pictureInPicture`, `.connectedToDevice` | Picture in picture; a Bluetooth or USB device. |
| `.unknown(reason)` | CefKit could not tell: a check failed or timed out, Chromium gave a reason CefKit does not know, or Chromium cannot tell this tab from another with the same address and title. |

A browser that is shown, starts loading or navigates while it is being
discarded stays loaded, and `discard()` throws.

Every blocker is something Chromium or CefKit knows natively; CefKit does
not read the page's content to find more. Chrome-style browsers get
Chromium's own discard rules, which cover audio, form input, picture in
picture and devices in every frame. A `CefWebView` browser has no such
rules in Chromium, so its set holds only `.visible`, `.notLoaded`,
`.capturingMedia`, `.beforeUnloadHandler`, `.devToolsOpen`, `.downloading`
and `.unknown`: an empty set does not mean the page is silent or has no
unsent form input. An app that knows more about its pages decides itself
before calling `discard()`.

`restore()` loads a discarded page at once, even while it is hidden. The
delegate hears `browserWillDiscard(_:)`, while the page can still be read,
then `browserDidDiscard(_:)`, and `browserDidRestore(_:)` when the page
starts loading again. `discardSnapshot` is an image of the page taken
just before it was discarded, for a tab preview or to show while it loads.

What a discard keeps:

| | `CefBrowserWindow`, Chrome UI windows | `CefWebView` |
|---|---|---|
| URL, title, favicon, zoom, profile, delegate | Kept | Kept |
| Back/forward list | Kept | Starts again from the current page |
| Scroll position | Restored | Lost |
| Form input not yet submitted | Lost | Lost |
| Bridges and user scripts | Work as before | Installed again |
| `devTools` event streams | Keep delivering | Keep delivering; enabled domains are enabled again |
| Other DevTools session state | Kept | Lost (overrides, scripts added through `devTools`) |
| `identifier` | Kept | A new one |
| Offscreen accessibility tree | — | Emptied, and built again when the page loads |

A Chrome-style browser is discarded by Chromium itself and comes back when
its window is shown. A browser in a view is discarded by closing its
Chromium browser and creating a new one in the same view; it stays in
`CefRuntime.shared.browsers` meanwhile. Quitting with discarded browsers
needs nothing special.

## Lifecycle and energy

`browser.lifecycle` says whether the user can see a page and whether it
has their input, following the web's Page Lifecycle. It is observable, and
the page's `document.visibilityState` agrees with it:

| `lifecycle` | `visibilityState` | When |
|---|---|---|
| `.active` | `visible`, and `document.hasFocus()` | On screen, in the key window of the active app, with focus in the browser's view |
| `.passive` | `visible` | On screen without focus |
| `.hidden` | `hidden` | Its window is covered, minimized or ordered out, the app is hidden, its tab is not selected, or its view is hidden or out of a window |
| `.discarded` | — | Discarded to free memory |

```swift
Text(browser.title)
    .foregroundStyle(browser.lifecycle.isVisible ? .primary : .secondary)
```

A hidden page draws nothing and runs no animation frames, in every kind
of host: for a browser in one of your views, CefKit hides Chromium's view
while its window is minimized or ordered out or the app is hidden, which
Chromium does not notice by itself. You do not need to do anything for it.
Chromium also keeps App Nap off for your app and watches memory pressure
and sleep itself.

`CefRuntime.shared.energyPolicy` lowers offscreen browsers to 30 frames a
second while Low Power Mode is on or the Mac reports serious thermal
pressure, which roughly halves the CPU time an animated page takes. Turn
it off for content that must stay smooth:

```swift
CefRuntime.shared.energyPolicy = .disabled
CefRuntime.shared.energyPolicy = CefRuntime.EnergyPolicy(reducedOffscreenFrameRate: 45)
```

Windowed and Chrome-style browsers draw at the display's rate in any
case.

## Processes

`CefRuntime.shared.taskManager` is Chromium's task manager: an `@Observable`
list of the app's processes and what runs in them, with CPU and memory,
as Chrome's Task Manager shows them.

```swift
struct TaskList: View {
    private let manager = CefRuntime.shared.taskManager

    var body: some View {
        Table(manager.tasks) {
            TableColumn("Task", value: \.title)
            TableColumn("Memory") { task in
                Text(task.memory.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "–")
            }
        }
    }
}
```

Each `CefTaskManager.Task` has a `kind` (`.browser`, `.gpu`, `.renderer`,
`.utility`, `.serviceWorker`, …), Chromium's `title`, `cpuUsage` in percent
of one core (up to `processorCount` × 100), `memory` and `gpuMemory` in
bytes (`nil` until Chromium has measured them), and `canTerminate`.
`terminate(_:)` ends a task's process, as End Process does; the pages it
showed report `browser(_:renderProcessDidTerminate:)`. Chromium does not
end the app's own process.

`tasks` refreshes every `refreshInterval` (one second) while something
reads it: a view showing it, or code that reads it again within two
intervals. When nothing does, it stops, and Chromium stops measuring.
`refresh()` takes one snapshot at once.

The figures belong to processes, and several tasks can share one: tabs of
one site in one renderer, a page and its workers. Tasks of one process
report the same figures and the same `process`; `processes` groups them,
and `CefTaskManager.Process.estimatedTotalMemory(of:)` counts each process
once. Chromium's API names no process, so the grouping is an estimate:
CefSwift groups the consecutive renderer tasks with identical measured
figures, which is what the tasks of one process have. Two separate
renderers that report the same figures side by side are grouped as one,
which undercounts the total, and tasks not measured yet stay apart. Show
the grouping; do not decide anything by it.

`browser.rendererTask` is the task of the renderer showing a browser's page,
and `taskManager.browsers(in:)` lists the browsers in the same estimated
process, so a browser's memory is that process's memory shared with those
browsers.

### Unresponsive pages

A page whose renderer has not handled input for 15 seconds, such as one
stuck in a loop, is unresponsive: `browser.isResponsive` turns `false`
until it responds again or its process ends. Chrome-style browsers show
Chromium's “Page Unresponsive” dialog. Other browsers ask the delegate,
whose default is a native sheet offering Wait and Force Reload:

```swift
func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision {
    .reload   // .wait asks again later if the page still does not respond; .terminate ends it
}
```

Set `CefBrowser.Configuration.unresponsivePages` to `.delegate` to have
Chrome-style browsers ask the delegate too, instead of showing Chromium's
dialog. A page that responds again before you answer withdraws the
question: the task is cancelled and the default sheet dismisses itself.
So do a navigation, closing the browser, and a second notification while
the first is still open, which replaces it; an answer to a withdrawn
question is ignored. `.reload` reloads only when the renderer it was asked
about ends, never a later one.

## JavaScript

```swift
let count = try await browser.evaluateJavaScript("document.links.length").intValue
let size = try await browser.evaluateJavaScript("({w: innerWidth, h: innerHeight})", as: Size.self)
```

`evaluateJavaScript(_:)` runs in the main frame's own JavaScript context,
waits for a returned promise, and returns the value as `CefJSON`. The `as:`
form decodes it into any `Decodable` type. An exception thrown by the script
arrives as `CefJavaScriptError`, and so does a navigation that replaces the
page before the result is ready. `executeJavaScript(_:)` runs a script
without waiting for a result.

A script that may never settle takes a `timeout`. When it runs out, the
call throws `CefError.timedOut`; only the wait ends, and the script, with
any promise it returned, goes on running in the page:

```swift
do {
    let ready = try await browser.evaluateJavaScript("app.whenReady()", as: Bool.self, timeout: .seconds(5))
    print(ready)
} catch CefError.timedOut {
    print("still waiting for the page")
}
```

The frame variants, `evaluateJavaScript(_:in:timeout:)` and
`evaluateJavaScript(_:as:in:timeout:)`, take one too.

Some web APIs need a user gesture: opening a popup, entering fullscreen,
starting audio, a `beforeunload` prompt. `evaluateJavaScript(_:userGesture:
true)` runs the script as if the user had just clicked. Only the DevTools
Protocol can do that, so it attaches `devTools` to the browser; see
[Compatibility with bot protection](#compatibility-with-bot-protection).

### Frames

`browser.frames` lists the page's frames connected to a renderer: the main
frame first, then each `iframe` in the order it attached. `mainFrame` is
the top-level one. Each `CefFrame` has an `id`, its `url`, the `name` of
its `iframe`, `isMain`, and its parent's `parentID`. The list is
observable and follows Chromium's frame events: an `iframe` appears when it
attaches and goes when it is removed, and a frame's `url` follows its
navigations. A cross-site navigation of the main frame replaces it with a
new frame.

```swift
for frame in browser.frames where !frame.isMain {
    let title = try await browser.evaluateJavaScript("document.title", in: frame)
    print(frame.url as Any, title)
}
```

`evaluateJavaScript(_:in:)` and `executeJavaScript(_:in:)` run a script in
one frame, cross-site frames in other renderer processes included, as the
main-frame versions do. An evaluation in a frame that is gone, or that
goes while the script runs, throws `CefError.frameDetached`.

### User scripts and style sheets

User scripts run in every document the browser loads, before the page's own
scripts:

```swift
browserConfiguration.userScripts = [
    CefUserScript(source: "window.appVersion = '1.2'"),
    // At document start the page has no <body> yet; this one waits for it.
    CefUserScript(source: "document.body.dataset.app = 'yes'", matching: "https://*.example.com/*",
                  injectionTime: .documentEnd),
    .styleSheet("header { display: none }", matching: "https://news.example/*"),
]
```

- `matching:` limits a script to URLs that match the pattern as a whole,
  where `*` stands for any run of characters. A matched script runs inside a
  function, so its top-level declarations are not global.
- `injectionTime: .documentEnd` runs the script when the document has been
  parsed (`DOMContentLoaded`), before the page's own listeners for it.
- `frames: .mainFrame` runs it in top-level documents only; by default it
  runs in every frame, cross-site frames included.
- Scripts share the page's globals: CEF's API has no isolated worlds.
- `CefUserScript.styleSheet(_:matching:includingShadowRoots:)` adds CSS. With
  `includingShadowRoots` (the default) its rules also apply inside every
  shadow root, including roots whose component sets its own
  `adoptedStyleSheets`.
- `browser.addUserScript(_:)` adds a script after creation; it applies from
  the next document on. A renderer process the browser moves to later
  learns of it as its first document of the browser starts, and runs it
  from the next one.

A selector cannot cross a shadow boundary, even when the rules reach inside
shadow roots. If `#row` lives in the shadow root of `settings-section`, the
selector `settings-section #row` matches nothing; write `#row`.

### Bridge

`CefBridge` exposes Swift methods to JavaScript as functions that return
promises. Arguments and results are JSON's kinds of values plus bytes, so
any `Codable` type works, and an `ArrayBuffer` argument or a `Data` result
travels as bytes: an `ArrayBuffer` in the page, `Data` in Swift. Typed
arrays reach Swift as objects; pass their `buffer`.

```swift
struct Person: Codable { var name: String }

let bridge = CefBridge(name: "app")
bridge.handle("greet") { (person: Person) in "Hello, \(person.name)!" }
bridge.handle("save") { (document: Document, call: CefBridgeCall) in
    guard call.origin == "https://app.example.com" else { throw AppError.forbidden }
    try documents.save(document)
}

var browserConfiguration = CefBrowser.Configuration()
browserConfiguration.bridges = [bridge]
```

```js
const reply = await app.greet({ name: "Ada" });
const stop = app.on("themeChanged", theme => apply(theme));
```

- The global exists before any page script runs, in every frame `access`
  permits, cross-site frames and popups included.
- A handler that throws rejects the promise.
- `bridge.emit("themeChanged", theme)` delivers an event to `app.on`
  listeners, in every browser the bridge is attached to or in one
  (`to: browser`).
- `CefBridgeCall` describes the caller: `browser`, `method`, `origin` and
  `isMainFrame`. The browser process establishes the origin from its own
  record of the frame's address, so neither a page nor a compromised
  renderer can claim another one. `about:blank` and `srcdoc` frames have
  their parent's origin and a `blob:` document the origin in its address.
  Where the address cannot confirm an origin (`data:` documents, sandboxed
  ones, a popup's first `about:blank`) the origin is `"null"`, which no
  `.origins` list matches.
- Values travel as `JSON.stringify` would write them: own enumerable
  properties, read through the page's getters. A getter that throws
  rejects the call with its exception instead of sending part of the
  value. Values nest at most 64 deep, and a call's payload holds at most
  1 GiB and 16 Mi values; past those, the call is rejected.

Handlers run with your app's privileges, so `bridge.access` decides where
the global exists:

| Access | Documents that get the bridge |
|---|---|
| `.mainFrame` (default) | Top-level documents. |
| `.origins(["https://app.example.com"])` | Documents from the listed origins, in any frame, including their `about:blank`, `srcdoc` and `blob:` subframes. Never `data:` or sandboxed documents. `"file://"` matches a top-level `file:` page only, not `file:` subframes or frames inside them, since CEF cannot tell a sandboxed one apart; the same holds for custom schemes registered with `.local`. A custom scheme without `.standard` has no origin to list. |
| `.anyFrame` | Every document. Use it only for browsers that show nothing but your own content. |

A document outside `access` has no global and no way to reach the bridge.
Calls are checked again in Swift against the caller's origin and frame. A change to `access` applies to calls at once and to
the global from the next document load:

```swift
bridge.access = .origins(["app://start"])   // only your start page
```

## Decisions

`CefBrowserDelegate` covers what observation cannot: decisions and one-time
events. Every method has a default, so implement only the ones you need.
Decisions Chromium can wait for are `async`: present your own UI, await the
user, and return.

```swift
final class Policy: CefBrowserDelegate {
    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        await askUser(about: request.kinds, from: request.origin) ? .allow : .deny
    }

    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        // Keep the native sheet for everything but alerts.
        dialog.kind == .alert ? .accept() : await CefDialogPresenter.present(dialog, in: browser.hostWindow)
    }
}
```

| Method | Default |
|---|---|
| `browser(_:runJavaScriptDialog:) async` | Native sheet |
| `browser(_:confirmLeavingPage:) async` (`beforeunload`) | Native sheet |
| `browser(_:decidePermissionFor:) async` | `.deny`. Asked only when the site settings leave the request to the user; see [Site settings](#site-settings) |
| `browser(_:credentialFor:) async` (HTTP and proxy authentication) | Native sign-in sheet; see [HTTP authentication](#http-authentication) |
| `browser(_:shouldProceedDespite:) async` (certificate errors) | `false`: the load is cancelled |
| `browser(_:selectClientCertificateFor:) async` | Native sheet; asked only with `CefBrowser.Configuration.clientCertificates = .delegate`, otherwise Chromium's picker. See [Client certificates](#client-certificates) |
| `browserPageIsUnresponsive(_:) async` | Native sheet; Chrome-style browsers show Chromium's dialog instead. See [Unresponsive pages](#unresponsive-pages) |
| `browser(_:decideDestinationFor:suggestedName:) async` | `.saveToDownloadsFolder`: `~/Downloads` |
| `browser(_:decidePasskeyFor:) async` | Native passkey sheet; see [Passkeys](#passkeys) |
| `browser(_:decidePolicyFor:)` | `.allow` |
| `browser(_:decideWindowOpenFor:)` | `CefWindowOpenDecision.default(for:)` |
| `browser(_:handleKeyEvent:isBeforePage:)` | `false` |
| `browser(_:configureContextMenu:for:)`, `browser(_:handleContextMenuCommand:for:)` | No change |
| `browser(_:handleChromeCommand:disposition:)` | `false`: Chrome runs the command |

An `async` decision that stops mattering before you answer is cancelled:
a dialog, permission, certificate or passkey decision when the page
navigates away, and every decision when the browser closes. The task
running your method is cancelled and its answer is ignored; the default
sheets dismiss themselves.

Events: `browserDidCreate(_:)`, `browserDidClose(_:)`, `browser(_:didOpen:)`
(a popup or DevTools browser opened on this browser's behalf, which inherits
the delegate), `browser(_:didFinishLoadWithStatus:)`,
`browser(_:didFailLoad:)`, `browser(_:didLog:)`,
`browser(_:renderProcessDidTerminate:)` and
`browser(_:downloadDidUpdate:)`.

`CefDialogPresenter` provides the native sheets behind the defaults, so your
delegate can keep them for some cases.

### HTTP authentication

When a site or proxy asks for a user name and password (Basic, Digest,
NTLM), Chromium asks the browser's delegate, in both runtime styles:

```swift
func browser(_ browser: CefBrowser, credentialFor challenge: CefAuthenticationChallenge) async -> CefCredential? {
    if challenge.isProxy { return CefCredential(username: "proxy-user", password: "proxy-password") }
    return await CefDialogPresenter.requestCredential(for: challenge, in: browser.hostWindow)
}
```

`challenge` names the full address of the request (`url`), the server or proxy (`host`,
`port`, `isProxy`), the `realm` and the `scheme` (`"basic"`, `"digest"`,
…). Returning `nil` cancels the sign-in, and the page shows what the
server sent with its 401 or 407. When the server refuses the credentials,
the delegate is asked again with the same challenge. Chromium keeps
accepted credentials for the profile and sends them again without asking.
A request that belongs to no browser, such as a service worker's, is
refused. A sign-in still waiting for an answer is cancelled when the page
navigates away or the browser closes, and the default sheet dismisses
itself.

`configuration.authenticationPrompt = .chromium` shows Chromium's own
dialog instead, for the whole app, and the delegate is not asked. In a
Chrome-style browser the dialog is the `.signIn` surface
([Chromium's own interface](#chromiums-own-interface)) and Chromium's
password manager can fill it. In a `CefWebView` the load first fails with `ERR_INVALID_AUTH_CREDENTIALS`, reported to
`browser(_:didFailLoad:)`, and Chromium shows the dialog in a window of its
own; closing such a browser leaves the page first, which dismisses that
window (Chromium crashes when the browser closes under it).

### Navigation and new windows

`browser(_:decidePolicyFor:)` returns `.allow` or `.cancel` for each
main-frame navigation. To handle a URL yourself, cancel it and act.

`browser(_:decideWindowOpenFor:)` routes links with `target=_blank`,
`window.open` and ⌘-clicks. The request has `targetURL`, `disposition`
(`.newForegroundTab`, `.newBackgroundTab`, `.newPopup`, `.newWindow`, …),
`features`, `hasUserGesture`, `isSourceOffscreen` and `isSourceChromeStyle`.
Return one of:

| Action | Effect |
|---|---|
| `.allowNativePopup` | Chromium opens the window or tab itself. Offscreen browsers cannot, so for them this acts as `.openInCurrentBrowser`, or `.deny` without a URL. |
| `.openInCurrentBrowser` | Loads the URL in the requesting browser. |
| `.handled` | You opened it yourself, for example in a new `CefBrowserWindow`. |
| `.deny` | Ignores the request. |

`CefWindowOpenDecision.default(for:)`, the default, chooses
`.allowNativePopup` for Chrome-style browsers; for other browsers it loads
the URL in place, and allows a blank popup only when the browser is not
offscreen. Return it for requests you do not handle:

```swift
func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
    guard request.disposition != .newPopup, let url = request.targetURL else { return .default(for: request) }
    openTab(url, inBackground: !request.disposition.prefersForeground)
    return .handled
}
```

### Downloads

`browser.downloads` lists the browser's downloads, oldest first, as
`CefDownload` values with `receivedBytes`, `expectedBytes` (`nil` when the
server gives no size), `destinationURL` and a `state`: `.inProgress`,
`.paused`, `.completed`, `.cancelled`, or `.interrupted(reason)` when an
error stopped it. Control them with `pauseDownload(_:)`,
`resumeDownload(_:)` and `cancelDownload(_:)`, and start one with
`startDownload(_:)`. A paused or interrupted download keeps its controls,
so `canResume` downloads continue with `resumeDownload(_:)`.

Each download asks the delegate where to save:

```swift
func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision {
    guard let folder = await chooseFolder() else { return .cancel }
    return .save(to: folder.appending(path: suggestedName))
}
```

### File choosers

An `<input type="file">` or `showOpenFilePicker()` asks the delegate,
with a `CefFileDialog`: its `mode` (`.open`, `.openMultiple`,
`.openFolder`, `.save`), the page's `title`, a `defaultURL`, and the
`acceptedTypes` the page lists, each with its `contentTypes` as `UTType`s.
Return the chosen files, or `nil` to cancel:

```swift
func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]? {
    if dialog.mode == .open, let recent = recentDocument { return [recent] }
    return await CefFileDialogPresenter.present(dialog, in: browser.hostWindow)
}
```

The default, `CefFileDialogPresenter`, shows an `NSOpenPanel` (or
`NSSavePanel`) as a sheet on the browser's window, limited to the accepted
types. A page that navigates away closes the panel as Cancel. CefSwift has
no API for opening a file panel on the app's behalf: use `NSOpenPanel`.

### Passkeys

`CefBrowser.Configuration.passkeys` chooses who answers a page's WebAuthn calls,
`navigator.credentials.create()` and `.get()`:

| Mode | Who answers |
|---|---|
| `.chromium` (default) | Chromium, with its own dialog and authenticators. |
| `.app(store)` | Your app, from a `CefPasskeyStore`, through the delegate. Chromium's dialog and authenticators are not used. |
| `.disabled` | Nobody: every call rejects with `NotAllowedError`. |

`.app` and `.disabled` take the calls over through the DevTools Protocol,
with a debugger that stops each document as it starts; pages can observe
both ([Compatibility with bot protection](#compatibility-with-bot-protection)).
Use them for browsers that show your own or trusted pages.

Chromium creates a native popup and runs its first document before
DevTools can attach to it, so with `.app` and `.disabled` a popup, tab or
window the delegate lets Chromium open (`.allowNativePopup`) is opened in a
browser CefKit creates instead, with the opener's configuration and the
calls taken over from its first document. It arrives as a native popup
does (`browser(_:didOpen:)`, then `onPopup` or a window of its own), but
the page cannot script it: `window.open` returns `null`, the popup has no
`window.opener`, and a blank popup is refused. A sign-in flow that posts
its result back to the opener needs `.chromium`.

With `.chromium`, what Chromium can offer depends on how the app is
signed and configured. The `passkeys` capability of `cef bundle` adds what
it can ([bundling](bundling.md#features)):

| Authenticator | Needs |
|---|---|
| USB and NFC security keys | Nothing. |
| A phone or tablet (QR code and Bluetooth) | `NSBluetoothAlwaysUsageDescription` in the app's `Info.plist` and, under the hardened runtime, `com.apple.security.device.bluetooth`; and a launch from Finder or `open`, which makes the app responsible for its own Bluetooth access. |
| iCloud Keychain passkeys, through AuthenticationServices | The `com.apple.developer.web-browser.public-key-credential` entitlement, which Apple grants to web browsers on request, in a provisioning profile, and an Apple Development or Developer ID signature. |
| Chromium's own profile passkeys (Touch ID) | Not available: CEF 156 checks for a keychain access group without a team prefix, which no provisioning profile can authorize. |

An ad hoc signed app gets security keys and, with the Bluetooth key,
phones. `CefRuntime.shared.capabilities.passkeyAuthenticators` lists what
the running app gets, and CefSwift logs a line at start-up when it is only
part of the list. Chromium shows its dialog ("Use your security key with
example.com") as a window attached to a `CefBrowserWindow`, or as a
free-standing window for a `CefWebView`.

With `.app(store)`, the delegate decides each call while the page waits at
it:

```swift
var browserConfiguration = CefBrowser.Configuration()
browserConfiguration.passkeys = .app(CefKeychainPasskeyStore())

func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
    guard request.hasUserGesture else { return .ignore }   // conditional requests wait
    switch request.kind {
    case .registration:
        return await confirm("Save a passkey for \(request.host)?") ? .createPasskey : .deny
    case .assertion:
        guard let passkey = await choose(from: request.passkeys) else { return .deny }
        return .signIn(with: passkey)
    }
}
```

- `CefPasskeyRequest` has `kind`, `origin` (the calling document's, as
  Chromium reports it), `isMainFrame`, `hasUserGesture` and, for an
  assertion, `passkeys`: the stored passkeys a page on that origin may use,
  most recently used first.
- `.createPasskey` makes a new ECDSA P-256 key pair and saves the passkey,
  with the account the page named, to the store. `.signIn(with:)` signs
  with that passkey and saves its new sign count. Both tell the site the
  user was verified, so verify the user first.
- `.deny` rejects the call with `NotAllowedError` at once. `.ignore`
  leaves it waiting until the page aborts it or its timeout passes, which
  suits conditional requests (passkeys offered in an autofill list).
- The page stays stopped at its call until you answer, as it does for
  `alert()`. JavaScript you evaluate in it meanwhile waits too.
- The default, `CefPasskeyPresenter.present(_:in:verifier:)`, ignores
  requests without a user gesture, shows a sheet naming the site (with an
  account menu when several passkeys fit), and verifies the user before
  answering. The verifier, `CefUserVerifier.deviceOwner` by default, asks
  for Touch ID or the account password through `LAContext` and returns a
  `CefUserVerification`: `.verified`, `.failed`, or `.unavailable(_:)`
  on a Mac that cannot verify its user. Only `.verified` answers the
  request; anything else refuses it. Pass your own `CefUserVerifier` to
  verify another way or to treat `.unavailable` differently, and in tests,
  so that no system prompt appears.

Store failures fail closed. Before it asks the delegate about a
registration, CefKit calls the store's `checkAvailability()` (by default
a read of `passkeys()`), and before an assertion it reads the usable
passkeys; if either throws, the call rejects with `NotAllowedError`
without asking. A save happens after Chromium has handed the page its
answer, so a save that fails cannot reject the call: the site holds a
credential whose key the store does not. Every store failure reaches
`browser(_:passkeyStoreDidFail:)` as a `CefPasskeyStoreError` with its
`operation` (`.checkAvailability`, `.read`, `.save`) and, for a save, the
`passkey` that was not saved, so the app can keep it another way or tell
the user; the default logs it.

`CefPasskey` holds the credential ID, `relyingPartyID`, `userHandle`,
`userName`, `userDisplayName`, the PKCS #8 `privateKey`, `signCount` and
dates. List and remove passkeys through the store, for a settings screen:

```swift
let saved = try await store.passkeys()
try await store.remove(saved[0])
```

| Store | Keeps passkeys |
|---|---|
| `CefInMemoryPasskeyStore` | In memory, until it is released. For tests and private browsing. |
| `CefKeychainPasskeyStore(service:accessGroup:)` | In the data protection keychain, one item per passkey, available while the Mac is unlocked and never synced. Needs a team signature with a provisioning profile, which gives the app the `com.apple.application-identifier` entitlement the data protection keychain checks; an ad hoc signed app gets `errSecMissingEntitlement` (-34018) as `CefError.operationFailed`. It never shows a keychain password prompt. |

Adopt `CefPasskeyStore` (`passkeys()`, `save(_:)`, `remove(_:)`, and
optionally `checkAvailability()`) to keep them elsewhere, such as in a
password manager.

Chrome's settings link to Chromium's password manager from Autofill and
passwords → Passkeys. That tab arrives through
[`onOpenBrowser`](#tabs-chromium-opens-itself) like the other
password-manager links.

The Browser example has a Passkeys setting (Chromium or the browser
itself) and lists and removes saved passkeys in its Settings window
(`BrowserPasskeys.swift`).

## Context menu

Shape the menu without a delegate through `CefBrowser.Configuration.contextMenu`:

```swift
browserConfiguration.contextMenu.hiddenCommands = [.viewSource, .print]
browserConfiguration.contextMenu.showsInspectElement = true
browserConfiguration.contextMenu.items = [
    CefContextMenuItem("Search Notes", isVisible: { !$0.selectedText.isEmpty }) { _, target in
        search(target.selectedText)
    },
]
```

- `hiddenCommands` removes Chromium's items (`CefContextMenuCommand`: back,
  reload, copy, paste, find, print, view source, …).
- `items` are added below Chromium's. `isVisible` decides per click, from
  the `CefContextMenuTarget`: `linkURL`, `sourceURL`, `pageURL`,
  `selectedText`, `mediaType`, `isEditable`, `location`.
- `showsInspectElement` adds Inspect Element, which opens DevTools on the
  clicked element.
- `isEnabled = false` removes the menu.

For menus that depend on app state, implement
`browser(_:configureContextMenu:for:)`, which runs after the configuration
and edits the `CefMenuModel` directly, and handle your command IDs in
`browser(_:handleContextMenuCommand:for:)`. Take IDs from
`CefMenuModel.userCommandIDs`; `items` use IDs from its start and Inspect
Element its last ID.

## Building a browser

`CefBrowserWindow` is a window with one Chrome-style browser: the full
Chrome runtime with `chrome://settings`, `chrome://extensions`, history,
downloads, the password manager, autofill, extensions and PDF viewing.
Chromium provides Chrome style only in windows it creates, so the window owns
its `NSWindow` instead of living in a SwiftUI scene.

```swift
let browser = CefBrowser(url: home, delegate: controller)
var configuration = CefBrowserWindow.Configuration()
configuration.tabbingIdentifier = "tabs"
let window = CefBrowserWindow(browser: browser, configuration: configuration)
window.setToolbar {
    NavigationButtons(browser: browser)   // beside the window buttons
} principal: {
    AddressBar(browser: browser)          // centered
} trailing: {
    Button("New Tab", systemImage: "plus") { controller.openTab() }
}
window.setTabAccessory { TabIcon(browser: browser) }   // in the native tab
window.show()
```

A tab accessory is a small view shown in the window's native tab, such as
the page's icon:

```swift
struct TabIcon: View {
    let browser: CefBrowser

    var body: some View {
        if let favicon = browser.favicon {
            Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe")
        }
    }
}
```

The window starts hidden; call `show()`. `CefBrowserWindow.all` lists the
open windows and keeps them alive, `close()` closes one (its page's
`beforeunload` handler may keep it open), and `onClose` runs after it is
destroyed. `window.window` is the `NSWindow`: Chromium owns its lifetime,
and its frame, title, ordering and tabbing are yours.

`CefBrowserWindow.Configuration`:

| Property | Effect |
|---|---|
| `toolbar` | `.none` (default) shows only the page; `.chrome` shows Chrome's toolbar and omnibox; `.location` shows Chrome's read-only location bar. |
| `frame` | Initial frame in screen coordinates. `nil` centers a 1200 × 800 window. |
| `tabbingIdentifier` | Windows that share one are grouped as native tabs. `nil` keeps the window out of tab groups. |
| `titleFollowsPage` | Keeps the window title in sync with the page, as `title` makes it. On by default. |
| `title` | Makes the window title from the browser: by default its page title, or the host while the page has none. Re-run whenever the observable state it reads changes, so `{ $0.title.isEmpty ? "New Tab" : $0.title }` titles blank tabs. |
| `isFrameless` | Removes the title bar and window buttons. |

`CefRuntime.shared.openChromeWindow(url:frame:configuration:delegate:)` opens a
window drawn entirely by Chrome instead, with its tab strip, omnibox and
menus.

### Connection security

`browser.connectionSecurity` describes how the page shown was loaded, and
changes as the browser navigates:

```swift
if let security = browser.connectionSecurity {
    switch security.level {
    case .secure: showLock()
    case .partiallySecure, .notSecure: showWarning()
    case .local: break                      // the app's scheme, a file, a Chromium page
    }
    print(security.protocolVersion as Any, security.certificate?.subject.displayName ?? "")
}
```

`level` sums up `isSecureConnection`, the `certificateStatus` Chromium
found (`.dateInvalid`, `.authorityInvalid`, `.nameMismatch`,
`.extendedValidation`, …) and whether the page `displayedInsecureContent`
or `ranInsecureContent` loaded over HTTP. `protocolVersion` is the TLS
version, `.tls1_2`, `.tls1_3` or `.quic`; Chromium's API gives no cipher
suite. An HTTPS page your own scheme handler serves has no TLS, so it is
`.notSecure`.

A `CefCertificate` has its `subject` and `issuer` (common name,
organizations, country, …), `serialNumber`, `validFrom` and `validUntil`,
the `issuerChain` the server sent, the `sha256Fingerprint`, and the
`subjectAlternativeNames` it covers. `derRepresentation` and
`secCertificate` bridge it to the Security framework, for example to show
the system's certificate sheet:

```swift
import SecurityInterface

if let chain = browser.connectionSecurity?.certificate?.secCertificateChain, let window = browser.hostWindow {
    SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil,
                                           contextInfo: nil, certificates: chain, showGroup: true)
}
```

The `CefCertificateError` that `browser(_:shouldProceedDespite:)` receives
carries the same `certificate` and its `status`.

### Client certificates

A site can ask for a certificate to identify the user. Chromium lists the
user's identities in the keychain whose issuers the server accepts, and by
default shows its own picker. With `CefBrowser.Configuration.clientCertificates =
.delegate`, `browser(_:selectClientCertificateFor:)` decides instead: the
`CefClientCertificateRequest` has the `host`, `port` and the offered
`certificates`; return one of them, or `nil` to continue without. The
default implementation asks with `CefClientCertificatePresenter`, a native
sheet. Private keys stay in the keychain; Chromium signs with them itself.

### Toolbar and window

`setToolbar(leading:principal:trailing:)` gives the window a unified
title-bar toolbar laid out as Safari's is: `leading` beside the window
buttons, `principal` centered, `trailing` at the far edge. Each view is a
native toolbar item, and the native tab bar appears beneath the toolbar when
the window joins a tab group. `setToolbar(principal:)` sets only the
centered view. Installing a toolbar keeps the window's frame.

The builder closures run once, when you call the method, and the views they
build stay live: SwiftUI updates them as the observable state they read
changes. Put views that read browser state in a `View` type of their own,
such as `NavigationButtons` above, so they read the state in `body`; a value
read in the closure itself is captured once. Call `setToolbar` again to
replace the toolbar.

`setToolbar`, `setTabAccessory(_:)` and `topAccessory` take effect as soon
as the `NSWindow` exists, which is immediately for a window you create. For
other setup that needs the `NSWindow`, `withWindow(_:)` runs a closure at
the same moment. All of them do nothing once the window has closed.

Around the page:

```swift
window.topAccessory = statusBanner                                    // an NSView between title bar and page
window.contentInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
window.contentCornerRadius = 10                                       // the page as an inset, rounded card
```

`topAccessory` sits outside Chromium's view hierarchy, so focus, key
equivalents and menus behave as in any AppKit window. `contentInsets`
reserves space around the page for native views; the window background
shows around a page with insets or rounded corners.

### Tabs

Each `CefBrowserWindow` holds one browser. A tabbed browser is one window per
tab, grouped by a shared `tabbingIdentifier`. To show the "+" button in the
native tab bar, implement `newWindowForTab(_:)` in your app delegate. To put
a new tab in a specific group, call `addTabbedWindow(_:ordered:)` on a window
of that group with the new `window.window`.

### Popups

When a page in a `CefBrowserWindow` opens a popup (`window.open` with window
features, sign-in flows) and the delegate lets Chromium open it, the popup
arrives through `onPopup` as a hidden `CefBrowserWindow` of its own, still
connected to its opener. `popup.browser.popupFeatures` holds the origin and
size the page asked for, and `popup.browser.opener` is the opening browser.
Without `onPopup`, Chromium shows the popup in a window of its own design
with a location bar. With `.app` or `.disabled` passkeys the popup is a
browser CefKit created, not connected to the opener's page; see
[Passkeys](#passkeys).

```swift
window.onPopup = { [weak window] popup in
    guard let panel = popup.window, let parent = window?.window else { return popup.show() }
    if let size = popup.browser.popupFeatures?.size, size.width > 0, size.height > 0 {
        panel.setContentSize(size)
    }
    panel.tabbingMode = .disallowed
    parent.addChildWindow(panel, ordered: .above)   // layered over its opener
    popup.show()
}
```

A popup closes when its page calls `window.close()`. It stays open when its
opener closes unless you close it, for example from the opener's `onClose`.

### Chrome commands

`browser.execute(_:)` runs one of Chrome's own commands (`CefChromeCommand`):
`.find`, `.print`, `.showHistory`, `.showDownloads`, `.showSettings`,
`.createQRCode`, `.zoomIn`, `.bookmarkThisTab`, `.showDevTools` and more.
`canExecute(_:)` says whether one is available. Chrome-style browsers
only. `zoomLevel` follows `.zoomIn`, `.zoomOut` and `.resetZoom`, whether you
run them or the user chooses them in Chrome's UI.

Before Chrome runs a command chosen from its menus or keyboard shortcuts, it
calls the delegate's `browser(_:handleChromeCommand:disposition:)`. Return
`true` to handle the command yourself, for example `.newTab` or
`.focusLocation`.

`configuration.chromeToolbar` trims Chrome's own UI in Chrome-style windows:
`hiddenAppMenuCommands`, `disabledAppMenuCommands`, `showsToolbarButtons`
and `showsPageActionIcons`.

### Chromium's own interface

Chromium shows some of its interface over a `CefBrowserWindow` in windows
of its own: bubbles such as the QR code generator and Cast, the HTTP
sign-in dialog, the find bar, the status bubble with a hovered link's
address. These are surfaces, `CefChromiumSurface`, of a `Kind`. Without
Chrome's toolbar, Chromium hangs the toolbar's bubbles from the top right
of the page. `window.chromiumUI` decides, per kind, how each is presented:

| Presentation | Effect |
|---|---|
| `.native` (default) | Chromium draws it, under its anchor if it has one. |
| `.custom` | Chromium's is kept off screen; your interface shows instead. |
| `.hidden` | Nothing shows; a dialog that asks something is cancelled. |

Anchors put Chromium's surfaces under your controls:

```swift
window.chromiumUI.anchor = .view(addressField, alignment: .trailing)  // every toolbar surface
window.chromiumUI.anchors[.qrCode] = .view(qrButton, alignment: .trailing)
window.chromiumUI[.statusBubble] = .hidden
```

A status bubble or zoom bubble hidden in the window's configuration is
switched off in Chromium when the browser is created
(`cef_browser_settings_t`'s `chrome_status_bubble` and
`chrome_zoom_bubble`), so Chromium never creates its window, and
`browser.statusText` still follows the pointer. Hidden later, through
`window.chromiumUI`, Chromium's window is created and kept invisible:

```swift
var configuration = CefBrowserWindow.Configuration()
var ui = CefBrowserWindow.ChromiumUI()
ui[.statusBubble] = .hidden
configuration.chromiumUI = ui              // window.chromiumUI starts as this
let window = CefBrowserWindow(browser: browser, configuration: configuration)
```

In SwiftUI, mark the views in your toolbar:

```swift
AddressField(browser: browser)
    .chromiumSurfaceAnchor(alignment: .trailing)
Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
    .chromiumSurfaceAnchor([.qrCode])
```

- `CefChromiumSurface.Anchor` is `.view(_:alignment:spacing:)` or
  `.rect(_:alignment:spacing:)`, a rectangle in window coordinates. The
  surface hangs below it, `spacing` points away, lined up with its leading
  or trailing edge or centered, and kept inside the window. Surfaces follow
  their anchor as the window moves or resizes, and when Chromium lays them
  out again.
- `anchor` applies to the kinds that hang from Chrome's toolbar
  (`kind.hangsFromToolbar`). The find bar and the sign-in dialog belong to
  the page and move only with an anchor of their own in `anchors`.
  Untitled widgets attached to the page, such as autofill suggestions,
  never move.

Your own interface replaces a kind with `setCustomPresentation(for:_:)`.
The presenter receives the surface whenever Chromium would show it: from
its command (`.find`, `.createQRCode`, `.castMedia`, `.showSharingHub`),
its keyboard shortcut or menu item, or anything else, in which case
Chromium's window is hidden before it is seen. In SwiftUI:

```swift
window.setFindBar { session in FindBar(session: session) }      // under the toolbar, as in Safari
window.setStatusBubble { text in StatusBubble(text: text) }      // over the page
window.setCustomPresentation(for: .qrCode) { surface in         // in a panel at the kind's anchor
    CefQRCodeView(url: surface.url).frame(width: 200, height: 200).padding()
}
```

A surface carries what a replacement needs: `kind`, `title`, `browser`,
`url` (the address a QR code encodes, or the page's), `anchorRect`,
`position(_:)` to place a window of yours as Chromium would, and
`dismiss()`. A panel from the SwiftUI method closes on Esc, on a click
elsewhere, and when the surface is dismissed. `presentationForSurface`
decides per surface as it appears, `chromiumSurfaces` lists those on
screen, and `onChromiumSurface` hears about each one, custom ones without
a presenter included.

| Surface | Kind | Native | Custom: what you get | Notes |
|---|---|---|---|---|
| Find bar | `.findBar` | Yes | `browser.findSession`: `text`, `isCaseSensitive`, `matchCount`, `activeMatch`, `next()`, `previous()`, `end()` | ⌘G and ⇧⌘G move through the matches. |
| QR code | `.qrCode` | Yes | `url`; draw it with `CefQRCodeView` or `CefQRCode.image(for:size:)` | |
| Cast | `.cast` | Yes | `url`; `CefMediaRouter.shared` lists `sinks` and `routes` and casts Cast apps and presentation URLs | Mirroring a tab needs Chromium's dialog. |
| Share | `.share` | No: Chromium's share menu needs its toolbar | `url`, `title` | By default the command opens macOS's share menu at the anchor. |
| HTTP sign-in | `.signIn` | Yes | No: the credentials go to Chromium's dialog | Only with `authenticationPrompt = .chromium`; by default the delegate answers. Dismissing cancels the sign-in. |
| Status bubble | `.statusBubble` | Yes | `browser.statusText` | `setStatusBubble(_:)` or `statusBubbleView`. Not anchorable. |
| Fullscreen notice | `.fullscreenNotice` | Yes | `browser.isFullscreen` | |
| Downloads | `.downloads` | Yes | `browser.downloads` and the delegate's download decisions | |
| Permission prompt | `.permissionPrompt` | No | `browser(_:decidePermissionFor:)` | CefSwift answers every request through the delegate. |
| Translate, save password, bookmark, page info, zoom | `.translate`, `.savePassword`, `.bookmark`, `.pageInfo`, `.zoom` | Recognized if shown | No | CEF 156 does not show these without Chrome's toolbar. |
| Other bubbles (install app, …) | `.other(title)` | Yes | No | Identifiers are Chromium's. |
| Autofill and password suggestions | `.other(…)` | Yes | No | Attached to the page; left as Chromium places them. |

Other interface Chromium shows lives elsewhere: JavaScript dialogs, the
`beforeunload` question, HTTP authentication answers and certificate errors
go through the [delegate](#decisions); tooltips, `<select>` menus, date
pickers and the color panel are AppKit or page popups Chromium places at
the page element; crash pages and Safe Browsing warnings are pages.
### Tabs Chromium opens itself

Chromium opens some browsers in tabbed windows of its own design, with
Chrome's tab strip and toolbar:

| Path | Opener | Disposition |
|------|--------|-------------|
| A link from `chrome://settings`, such as Autofill and passwords → Passkeys | none | `.unknown` |
| Chrome commands such as `.newTab` and `.newWindow` that the delegate does not handle | none | `.unknown` |
| Tabs restored from an earlier session | none | `.unknown` |
| A ⌘-click (`.newBackgroundTab`) or ⇧-click (`.newWindow`) in a Chrome-style browser whose delegate answers `.allowNativePopup` | the clicked page's browser | as clicked |

`CefRuntime.shared.onOpenBrowser` decides what happens to each. The request
carries the browser Chromium created (live, and in `CefRuntime.shared.browsers`),
the URL it opens, its `CefProfile` (`nil` for one Chromium made itself,
such as its own incognito profile), the browser whose page asked for it,
and the disposition. Open the URL in your own UI and answer `.close`, or
answer `.showInChromium`:

```swift
CefRuntime.shared.onOpenBrowser = { request in
    // Your tab UI; open it in request.profile, next to request.opener.
    openTab(request.url, inBackground: request.disposition == .newBackgroundTab)
    return .close
}
```

Chromium's window, the one holding that browser's view, stays off screen
until the handler answers; other windows are left alone, and so is a
Chromium window already on screen that the tab joined. `.close` closes
the browser, and its window when that window shows no other tab;
`.showInChromium` shows the window and announces the browser through
`onBrowserCreated`. CEF cannot move a browser out of Chromium's tab strip,
so the tab you open is a new browser that starts from the URL: it has no
back-forward list, and a form submission opened in a new tab loads again
as a plain request. When `onOpenBrowser` is `nil`, Chromium shows these
browsers itself. Leave it `nil` in apps that use `openChromeWindow`, whose
new tabs Chromium opens the same way.

Popups and links with `target=_blank` from a `CefBrowserWindow` open in a
browser view of their own, which `CefBrowserWindow.onPopup` adopts with
its opener and history intact; they never reach `onOpenBrowser`.

Every other browser Chromium creates on its own, popups and DevTools
included, is passed to `CefRuntime.shared.onBrowserCreated`. Assign a
delegate there to manage it. Browsers that `onOpenBrowser` closes do not
reach `onBrowserCreated`. `CefRuntime.shared.browsers` lists every live
browser.

## Customizing Chromium's own pages

Chrome-style browsers show Chromium's internal pages, such as
`chrome://settings`, `chrome://history` and `chrome://downloads`. You can
rename, restyle and replace them.

**Names.** `productName` replaces "Chromium" in settings, `chrome://version`,
dialogs and the About page. `stringOverrides` replaces any other built-in
string by its `IDS_*` identifier, as a `CefRuntime.StringID`. The named constants are
`.productName`, `.shortProductName` and `.companyName`; other identifiers are
in the vendored `cef_pack_strings.h` and can change between CEF versions.

```swift
configuration.productName = "Orbit"
configuration.stringOverrides[.companyName] = "Orbit Software"
```

**Scripts and styles.** User scripts also run on `chrome://` pages; scope
them with a URL pattern:

```swift
browserConfiguration.userScripts = [
    .styleSheet("#about-menu { display: none !important }", matching: "chrome://settings/*"),
]
```

Internal pages are built from web components whose markup sits in shadow
roots. `styleSheet(_:matching:includingShadowRoots:)` reaches into them, but
a selector cannot cross a shadow boundary: write `#themeRow`, not
`settings-appearance-page #themeRow`, because the row lives in that
component's shadow root. Matching rows by the preference they edit
(`settings-toggle-button[pref-key="browser.show_home_button"]`) holds up
across Chromium updates better than matching by position. Scripts run
on `chrome://` pages as on any other, before the page's own scripts.

**Replacing a page.** Cancel the navigation and load a page of your own,
served from a [custom scheme](#serving-your-own-content):

```swift
func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
    guard navigation.url?.absoluteString.hasPrefix("chrome://settings/help") == true else { return .allow }
    browser.load(URL(string: "orbit://about/")!)
    return .cancel
}
```

The Browser example replaces Chromium's About page this way and trims
`chrome://settings` with a style sheet (`BrowserPages.swift`,
`BrowserController.swift`).

## Profiles

A `CefProfile` holds cookies, storage, cache, preferences, extensions and
theme. Browsers that share a profile share all of it.

| Profile | Storage |
|---|---|
| `CefProfile.default` | `cacheDirectory`, used when `CefBrowser.Configuration.profile` is `nil`. |
| `CefProfile.persistent(id:displayName:)` | `<root>/Profiles/<id>`, with characters other than lowercase letters, digits, `-` and `_` percent-encoded. The same identifier returns the same profile. |
| `CefProfile.incognito()` | In memory only; discarded with the profile. |

```swift
let profile = CefProfile.persistent(id: "work", displayName: "Work")
try profile.preferences.set(false, for: .savesPasswords)
let fontSize = profile.preferences[.defaultFontSize]
profile.setColorScheme(.dark, accentColor: .systemIndigo)

let cookies = await profile.cookies(for: url)
profile.setCookie(cookie)                        // an HTTPCookie
profile.deleteCookies(for: url, named: "session")
```

A profile's `id` is its identity and names its storage in both engines;
`displayName` is what to show, and can change without moving anything.
Store `id` to find the profile again. Identifiers map to directory names
one to one, also on a case-insensitive volume, so `"a/b"`, `"a_b"`,
`"Work"` and `"work"` are four profiles. `<root>` is
`CefRuntime.Configuration.resolvedRootCacheDirectory`: `rootCacheDirectory`, or
the parent of `cacheDirectory` when only that is set. `bookmarks`,
`history` and `autocomplete` hold their profile, so
`CefProfile.incognito().autocomplete` keeps its profile alive while you
use it; the profile does not hold them back, so neither keeps the other
alive forever.

`preferences.allValues(includingDefaults:)` returns every preference as one JSON
object. `setColorScheme(_:accentColor:)` themes Chrome-style UI and sets the
`prefers-color-scheme` pages see.

### Network maintenance

A profile clears what Chromium keeps for its connections, each `async`
and done when it returns:

```swift
await profile.clearHTTPCache()                       // cookies and site data stay
await profile.clearCertificateExceptions()           // certificate errors the user accepted
await profile.clearHTTPAuthenticationCredentials()
await profile.closeAllConnections()
let addresses = try await profile.resolveHost("example.com")   // ["93.184.215.14", …]
```

Clearing certificate exceptions does not close a connection that uses
one; close all connections too, or the browser keeps going without
asking. `resolveHost(_:)` uses the profile's DNS settings, Secure DNS
included, and throws when the name does not resolve.

### Requests through Chromium's network stack

A profile makes the app's own requests the way its pages make theirs:
with its cookies (sent, and stored from the response), HTTP cache, proxy
settings, client certificates, Secure DNS and `Accept-Language`, and
answered by your scheme handlers. `URLSession` shares none of that with
Chromium, so a request made with it is signed out of the sites the user
signed in to in a browser.

```swift
var request = URLRequest(url: URL(string: "https://intranet.example/api/me")!)
request.setValue("application/json", forHTTPHeaderField: "Accept")
let (data, response) = try await profile.data(for: request)
if response.statusCode == 200 { print(String(decoding: data, as: UTF8.self)) }

// The body as it arrives, then into a file.
let (body, head) = try await profile.bytes(for: URLRequest(url: url))
for try await chunk in body { print(head.statusCode, chunk.count) }
let saved = FileManager.default.temporaryDirectory.appending(path: "report.pdf")
_ = try await profile.download(for: URLRequest(url: url), to: saved)
```

The `URLRequest` says what it can: method, headers, `httpBody`,
`cachePolicy`, `timeoutInterval` (the longest wait for the next part of
the response), `httpShouldHandleCookies` (cookies and stored HTTP
credentials), and a `Referer` header, which becomes the referrer.
`RequestConfiguration` holds the rest:

```swift
var requestConfiguration = CefProfile.RequestConfiguration()
requestConfiguration.stopsAtRedirects = true            // a 3xx is the response
requestConfiguration.credential = { challenge in        // HTTP or proxy authentication
    challenge.host == "intranet.example" ? CefCredential(username: "ada", password: "…") : nil
}
requestConfiguration.uploadProgress = { progress in print(progress.fractionCompleted ?? 0) }   // on the IO thread
let (_, redirect) = try await profile.data(for: URLRequest(url: url), configuration: requestConfiguration)
print(redirect.value(forHTTPHeaderField: "Location") ?? "")
```

As with `URLSession`, an HTTP error status is a response. A request that
fails throws a `CefLoadError` with Chromium's network error (`code`
`-105`, `message` `net::ERR_NAME_NOT_RESOLVED`); its `urlError` is the
closest `URLError`. Cancelling the task cancels the request and throws
`CancellationError`; so does leaving a `bytes(for:)` loop early or
dropping its body. Without a `credential` closure a challenge is not
answered, and its 401 or 407 is the response. A request body is bytes
or a file (`bodyFile`, which Chromium reads itself): an
`httpBodyStream` cannot be sent.

Chromium hands a streamed body over as it reads it and cannot be paused.
A body from `bytes(for:)` keeps up to `streamMemoryLimit` bytes (16 MB)
the loop has not read in memory, and by default puts the rest in a
temporary file that the loop reads next, so a slow loop, even one on a
busy main actor, still gets every byte in order, then the end or the
request's error. The file is made in the profile's directory, or for an
incognito profile in the temporary directory; it is unlinked as soon as
it is opened, so a crash leaves nothing named on disk, and closed when
the body ends, is cancelled, or the app quits. `streamOverflow` chooses:

```swift
var streaming = CefProfile.RequestConfiguration()
streaming.streamOverflow = .spillToDisk(limit: 512 << 20)   // at most 512 MB waiting on disk
streaming.streamOverflow = .fail                            // never on disk: falling 16 MB behind fails
let (feed, _) = try await profile.bytes(for: URLRequest(url: url), configuration: streaming)
for try await chunk in feed { print(chunk.count) }
```

Past either limit the request fails with `ERR_INSUFFICIENT_RESOURCES`,
after the loop has read what arrived before. Chunks on their way to the
file are in memory until the disk takes them, which matters only when
the network is faster than the disk, as a local server can be. Use `.fail` for a body
that must not touch disk, such as sensitive data in an incognito
profile. `download(for:to:)` writes each chunk straight into its file
and never falls behind. `data(for:)` copies each chunk once, into a
`Data` sized from `Content-Length`.

Redirects are followed or, with `stopsAtRedirects`, returned; Chromium
does not report the ones it follows. Requests are the profile's, not a
page's: CEF can tie one to a frame (`cef_frame_t.create_urlrequest`),
which only routes it through that browser's request filter and
authentication delegate, so CefSwift does not offer it.

### Site settings

`profile.siteSettings` holds what each site may use, as Chrome's site
settings do: a `CefSitePermission` (`.camera`, `.microphone`,
`.geolocation`, `.notifications`, `.popups`, `.javaScript`, `.images`,
`.cookies`, `.sound`, `.automaticDownloads`, `.clipboard`, `.usbDevices`,
`.serialPorts`, `.hidDevices`, `.bluetoothDevices`, …) set to `.allow`,
`.block` or `.ask` for an origin:

```swift
let site = URL(string: "https://meet.example")!
let settings = profile.siteSettings
settings.set(.allow, for: .camera, origin: site)
settings.setting(for: .notifications, origin: site)      // .ask: the default applies
settings.setDefaultSetting(.block, for: .popups)         // for every site without its own
settings.reset(origin: site)                             // the defaults apply again

for await change in settings.changes {
    print(change.permission, change.origin)
}
```

`setting(for:origin:)` returns the value that applies: the site's own or
the profile's default. `supportedSettings` lists the values a permission
takes; Chromium has no `.ask` for content switches such as images and
JavaScript, and no `.allow` for device choosers, which ask for each
device. Cookies also take `.sessionOnly`. Settings belong to origins, so
every page of a site shares them.

`changes` reports every change for as long as you iterate it, including
those Chromium's own prompts and `chrome://settings` make.
`exceptions(for:)` lists the values sites have of their own. Chromium has
no call for that; it reads the profile's
`profile.content_settings.exceptions` preference, where Chromium keeps
them, so for an incognito profile, which keeps them in memory, it lists
none.

The settings and the permission delegate agree. Chromium does not ask
about a prompt-based permission (notifications, location, MIDI, window
management, …) that a site has `.allow` or `.block` for, and keeps the
answer the delegate gives, `.allow` or `.deny`, for the site as Chrome
does. Camera and microphone requests reach the delegate before Chromium
reads the settings, so CefSwift answers them from the settings itself, and
asks the delegate only about kinds that are still `.ask`. An answer there
applies to that request; `.alwaysAllow` and `.alwaysDeny` also store it.
Screen and system-audio capture (`.screenCapture`, `.systemAudioCapture`)
are kinds of their own, never answered by the camera's or microphone's
settings and never stored: granting one hands the page the screen without
Chromium's picker, so the delegate is asked on every request. Camera
movement (`.cameraPanTiltZoom`) is separate from `.camera` too, stored as
`CefSitePermission.cameraPanTiltZoom`:

```swift
func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
    let (allowed, remember) = await askUserRemembering(about: request.kinds, from: request.origin)
    switch (allowed, remember) {
    case (true, true): return .alwaysAllow
    case (true, false): return .allow
    case (false, true): return .alwaysDeny
    case (false, false): return .deny
    }
}
```

### Bookmarks, history and suggestions

A profile gives you the data behind Chrome's bookmarks, history and address
bar:

```swift
let bookmark = try await profile.bookmarks.add(url, title: "CefSwift")
let roots = try await profile.bookmarks.tree()
let recent = try await profile.bookmarks.recent(limit: 12)
for await _ in profile.bookmarks.changes { /* refresh your UI */ }

let visits = try await profile.history.search("swift", limit: 20)
let topSites = try await profile.history.mostVisited()
try await profile.history.remove(visits)

let suggestions = try await profile.autocomplete.suggestions(for: "cef")
```

- `bookmarks` also has `bookmark(_:)`, `children(of:)`, `search(_:)`,
  `bookmarks(for:)`, `addFolder(_:in:at:)`, `update(_:title:url:)`,
  `move(_:to:at:)` and `remove(_:)`. `changes` yields for edits made through
  this API and in Chrome's UI; edits made while the consumer is busy are
  reported once, as one signal to read again.
- `history` groups visits by day, as `chrome://history` does. It records
  only visits made in Chrome-style browsers. `mostVisited()` includes visits
  made up to the call and takes up to a second.
- `history.favicon(for:size:)` returns the icon Chromium keeps for a page
  that is not open, such as a history entry, bookmark or most-visited site,
  or `nil` when it has none. For an open page, use `browser.favicon`.
- An incognito profile keeps no history: its `history` methods throw. It
  shares the default profile's bookmarks, as Chrome's incognito windows do,
  so `incognito.bookmarks` is `CefProfile.default.bookmarks`.
- `autocomplete.suggestions(for:currentURL:allowsInlineCompletion:)` returns
  what Chrome's address bar would show, ranked, each with a `kind` (history,
  bookmark, open tab, search, …), `detail` (a page's title), `relevance`,
  `inlineCompletion` and `isBookmarked`. Call it on every keystroke: a newer
  query supersedes one still running, which then returns no suggestions.
  Search-engine suggestions come from the network; filter on `kind` to keep
  only local results.

CEF has no API for any of this. CefKit uses the services Chromium's own
pages use — `chrome.bookmarks`, and the Mojo handlers of the history, new
tab and `chrome://omnibox` pages — from hidden service hosts, one renderer
process each. A host starts on the first call that needs it, in about a
tenth of a second, and closes 30 seconds after its last call, when macOS
runs low on memory, and when its profile's last browser closes, which lets
an incognito profile and its data go. Its window stays invisible, even when
Chromium brings its windows forward. While the bookmarks host is closed,
`tree()`, `children(of:)`, `bookmark(_:)` and `recent(limit:)` read
Chromium's `Bookmarks` file, and `changes` watches it, so following
bookmarks costs no process; an edit made in Chrome's own UI reaches them
about 2.5 seconds later, when Chromium saves the file. Chromium does not
save while the app shows no page in a visible window; until it has, and
in a new profile that has no file yet, those reads start the host
([architecture](architecture.md#internal-page-services)).

These interfaces are internal to Chromium and more likely than the rest of
CefKit to change with a Chromium update; `chrome://omnibox` is a debugging
page, so `autocomplete` is experimental. SelfTest exercises all of them, so
a CEF update that breaks one fails CI.

What each host costs while it runs, measured with
[`Scripts/measure-services.py`](../Scripts/measure-services.py) on the
machine described under [Footprint](#footprint-and-launch-time): memory is
the growth of the whole app's physical footprint when the host starts,
latency the median of five calls.

| Service | Host | Memory | First call | Later calls |
|---|---|---|---|---|
| `bookmarks` reads, `changes` while the host is closed | none (Chromium's file) | 0 | – | – |
| `bookmarks` changes and searches | `chrome://bookmarks` | 21 MB | 137 ms | 1 ms |
| `history.search`, `remove` | `chrome://history` | 27 MB | 175 ms | 2 ms |
| `history.mostVisited()` | `chrome://new-tab-page-third-party` | 21 MB | 127 ms | 1 ms |
| `history.favicon(for:size:)` | `chrome://bookmarks` or `chrome://history`, whichever runs | 0 when one runs | 16 ms | 2 ms |
| `autocomplete` | `chrome://omnibox` | 23 MB | 234 ms | 9 ms |
| Discarding | `chrome://discards` | 22 MB | 122 ms | 1 ms |

The Browser example uses them for address-field suggestions
(`AddressSuggestions.swift`), a bookmark star, Bookmarks and History menus,
and a start page whose tiles come from `mostVisited()` and
`bookmarks.recent()` through a `CefBridge` (`BrowserLibrary.swift`). It
reads history when the menu bar opens, so at launch it starts no host.

## DevTools

`browser.devTools` speaks the
[Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
in-process, without a debugging port:

```swift
try await browser.devTools.send("Emulation.setDeviceMetricsOverride",
    ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true])
try await browser.devTools.send("Network.enable")
for await event in browser.devTools.events("Network.responseReceived") {
    print(event["response"]["url"].stringValue ?? "")
}
```

`send(_:_:)` waits for the browser to be created and returns the result as
`CefJSON`; `send(_:_:as:)` decodes it. A protocol error throws
`CefDevToolsError`. `events(_:bufferingPolicy:)` streams one event's
parameters until the browser closes or the consuming task is cancelled;
enable the event's domain first. A consumer that falls behind keeps the
newest 1,000 events (`CefDevTools.defaultEventBuffering`); pass
`.unbounded` to keep every one.

`browser.showDevTools()` opens the DevTools window, and
`showDevTools(inspecting:)` inspects the element at a point in view
coordinates.

## Compatibility with bot protection

Sites behind bot protection read what a page can observe about the browser
and compare it with what stock browsers show. A CefSwift browser is the
browser a person is using; this section lists what CefSwift itself adds
that a page can observe, the settings that decide how the app names itself,
and the differences from Google Chrome that come with CEF.
`Scripts/compat-matrix.py` measures all of it against local and public
test pages, in each kind of host, with each feature on by itself, and in
Chrome for comparison.

### What a page sees of CefSwift

Nothing, for a browser that uses no bridge, user script or DevTools
feature: no global, no injected script, no DevTools session, and
`navigator.webdriver` is `false`. No preset passes a switch that sets it
(`--enable-automation`, `--headless`, `--remote-debugging-pipe`,
`--remote-debugging-port=0`); `remoteDebuggingPort` does not either, but
it opens a debugging port to anything on the machine, so leave it `nil` in
shipping apps.

Bridges, user scripts and `evaluateJavaScript(_:)` run in the helper's
renderer code with the V8 API, without the DevTools Protocol. A page sees
a bridge's global, where `access` allows it, and what a user script or an
evaluated script does, and nothing else: the bridge's functions are native
functions, and scripts leave no `sourceURL`. A script that returns a
promise is awaited through the promise's `then`, which the page could
replace.

### Features that use the DevTools Protocol

These attach `devTools` to the browser. CEF keeps the session attached
until the browser closes. An enabled domain can be seen. A session with no
domain enabled showed no difference in what `Scripts/compat-matrix.py`'s
probe page reads (`Scripts/compat/probe.html`: whether `console` calls
read an `Error`'s properties, the time to log a large object, the time a
`debugger` statement takes, automation globals, `navigator.webdriver`,
window geometry, focus and visibility, animation frame rate, plugins,
client-hint brands, codecs, WebGL, permissions, voices, media devices),
measured with CEF 156.0.28 on 2026-11-13 in a windowed and an offscreen
browser. That is what those probes found, not a guarantee about every
measurement a page can make.

| Feature | What attaches | What a page can observe |
|---|---|---|
| `browser.devTools` | Whatever you send; CefKit's features share the session, and a domain stays enabled until every `X.enable` sent through it has had its `X.disable` | `Runtime.enable` makes every `console` call serialize its arguments: logging a large object takes 2–3 times as long. `Debugger.enable` stops the page at `debugger` statements. `Page.enable`, `Network.enable` and the like: nothing measured. |
| `CefBrowser.PasskeyPolicy.app` and `.disabled` | `WebAuthn`, `Debugger`, `Page` and `Runtime`, for the browser's lifetime | Each `debugger` statement takes about 10 ms (CefKit resumes at once), and `console` calls serialize their arguments as above. Use `.chromium` for browsers that show sites you do not control. |
| `evaluateJavaScript(_:userGesture: true)` | `Runtime.evaluate`, no domain | The gesture itself. |
| `snapshot()` of a windowed browser | `Page.captureScreenshot`, no domain | Nothing measured. An offscreen browser's snapshot is the frame its view shows, with an open `<select>` list or date picker drawn in, and uses no protocol. |
| `discard()` | `Runtime.evaluate` and `DOMDebugger.getEventListeners`, no domain | Nothing measured; the page is about to be unloaded. |
| Offscreen accessibility actions | `Accessibility` for the length of one lookup; `DOM.focus`, `DOM.scrollIntoViewIfNeeded`; `Input.insertText` only for a field that takes no input-method text | Nothing measured. Only an assistive app's actions use it. |

CefKit's own services (bookmarks, history, suggestions) run in hidden
browsers that show Chromium's own pages, and attach no DevTools session.

### How the app names itself

`CefRuntime.Configuration.userAgent` sets the `User-Agent` header and
`navigator.userAgent`:

| Choice | `User-Agent` | Client hints |
|---|---|---|
| `.chromium` (default) | `… AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36` | All |
| `.appendingProduct("MyApp/1.0")` | `… Chrome/156.0.0.0 MyApp/1.0 Safari/537.36` | All |
| `.replacingProduct("MyApp/1.0")` | `… (KHTML, like Gecko) MyApp/1.0 Safari/537.36` | All |
| `.custom("…")` | That string | Low-entropy ones only: `getHighEntropyValues()` returns no versions or architecture |

The client hints (`Sec-CH-UA` and `navigator.userAgentData`) name the
brands `Chromium` and a GREASE brand, as every Chromium build does; Chrome
adds `Google Chrome`. CEF has no setting for them. The DevTools Protocol's
`Emulation.setUserAgentOverride` changes them per browser, at the cost of
an attached session. Sites look for an engine they know in the
`User-Agent`, compare it with the client hints, and compare both with what
the page can measure; a `User-Agent` that names another browser than the
one running fails those comparisons.

### Offscreen browsers

An offscreen browser reports the window it is shown in: `screenX`,
`screenY`, `outerWidth` and `outerHeight` are the window's,
`screen.availWidth` and the like leave out the menu bar and the Dock,
`screen.colorDepth` and `devicePixelRatio` are the display's, and
`document.visibilityState` follows whether the view can be seen. Pages lose
focus when the view stops being first responder in the key window, as in a
browser window. `CefOffscreenViewInfo` carries these values; a custom
`CefOffscreenHost` should fill in all of them. Chromium times the frames
itself at the browser's frame rate (`.offscreen(frameRate:)`, 60 by
default), so `requestAnimationFrame` runs as often as in a window.

### Differences that stay

These come with CEF and Chromium as CefSwift uses them; no setting of
CefSwift's changes them, and some need a different Chromium build:

- **Client hint brands**: `Chromium` and no `Google Chrome`, as above.
- **Codecs**: CEF's standard builds have no H.264, AAC or HEVC, so
  `canPlayType('video/mp4; codecs="avc1.42E01E"')` returns `""` where Chrome
  returns `"probably"`. Adding them takes a CEF build with
  `proprietary_codecs` and the licenses that come with them.
- **Google services**: no Google network voices for speech synthesis
  (Chrome lists about 20 more), no Safe Browsing, sync or Google sign-in.
- **Alloy style** (`CefWebView`): CEF answers Chromium's media permission
  check with "allowed", so `navigator.mediaDevices.enumerateDevices()`
  lists every camera, microphone and speaker before the user grants
  anything, where Chrome lists one of each kind. Chrome-style browsers
  (`CefBrowserWindow`) list what Chrome lists. Browse the web in
  `CefBrowserWindow`.
- **The window**: `outerHeight - innerHeight` is your window's title bar
  and toolbar, not Chrome's; it is what the window is.

## Serving your own content

Declare the scheme in the configuration, then register a handler once
Chromium is running, before any page loads from it. In a `CefSwiftApp`, the
app's `init()` is the place:

```swift
@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        configuration.customSchemes = [CefCustomScheme(name: "app")]
        return configuration
    }

    init() {
        let webRoot = Bundle.main.resourceURL!.appending(path: "web")
        CefRuntime.shared.registerSchemeHandler(
            scheme: "app", handler: CefDirectorySchemeHandler(directory: webRoot))
    }

    var body: some Scene {
        WindowGroup { CefWebView(url: URL(string: "app://local/index.html")!) }
    }
}
```

`CefDirectorySchemeHandler` serves files from a folder, with MIME types from
file extensions, and never outside that folder: a symbolic link is followed
only when its target lies inside the folder. For generated content,
implement `CefSchemeHandler`:

```swift
struct Pages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data("<h1>\(request.urlString)</h1>".utf8))
    }
}
```

A registered handler serves every profile, including incognito and
persistent ones. The default `CefCustomScheme` options make the scheme
standard, secure, CORS-enabled and fetchable; pass `options:` to change
them.

### Where a handler runs

Chromium asks for responses on its IO thread and never waits there for
the handler: `response(for:)` runs with the handler's own isolation.

| Handler | Runs on | For |
|---|---|---|
| A `Sendable` type, as above | Swift's concurrent executor, many requests at once | Computing or looking up a response |
| Isolated to `CefIOActor` | Chromium's IO thread, without a hop | Quick answers from state kept there, such as a cache; never blocking |
| Isolated to `@MainActor` | The main thread | Reading your app's model |

```swift
@MainActor
final class LibraryPages: CefSchemeHandler {
    let library: Library
    init(library: Library) { self.library = library }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data(library.html.utf8))
    }
}
```

### Large and streamed bodies

A body is `.data(_:)`, `.file(_:)` or `.stream(_:length:)`. Chromium reads
a file or a stream as the page consumes it, never more than about a
megabyte ahead, so a 200 MB response costs about 12 MB of memory instead
of 200 MB. A file is read straight into Chromium's buffer as the page
asks for more, on Chromium's thread pool. A stream is any
`AsyncSequence` of `Data`; give its length when you know it.

```swift
struct Media: CefSchemeHandler {
    let library: MediaLibrary

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        guard let file = library.file(for: request.url) else { return .notFound() }
        return CefSchemeResponse(mimeType: "video/mp4", body: .file(file))
    }
}

struct Generated: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            Task {
                for part in 0..<100 { continuation.yield(Data("part \(part)\n".utf8)) }
                continuation.finish()
            }
        }
        return CefSchemeResponse(mimeType: "text/plain", body: .stream(chunks))
    }
}
```

A request with a single `Range` header, as `<video>` and `<audio>` send
when they seek, gets `206 Partial Content` with only those bytes, or `416`
past the end, for any body whose length is known; a file skips to the
range without reading what comes before. Responses with a known length
carry `Accept-Ranges: bytes`. A handler that sets a status other than 200
answers ranges itself.

## Playing streaming services

Streaming services protect their video with DRM, which browsers expose
through Encrypted Media Extensions (EME). A CefSwift app has two engines for
it:

| | Chromium (`CefBrowser`) | WebKit (`CefSystemBrowser`) |
|---|---|---|
| DRM | Widevine, downloaded from Google at run time; Clear Key | FairPlay Streaming; Clear Key |
| Widevine level | Software (L3), host not verified (no VMP) | — |
| Video codecs | VP8, VP9, AV1 (no H.264 or HEVC) | H.264, HEVC, VP9, AV1 |
| Audio codecs | Opus, MP3 and other open formats (no AAC) | AAC and the open formats |
| Needs | Nothing for test streams and services that accept L3 | Nothing: no entitlement, licence or signing |
| Plays Netflix-class services | No: they require VMP | Yes, as Safari does (see [Services](#services)) |

The short version: services that play in Safari play in a
`CefSystemBrowser`, and Chromium plays Widevine content that does not
require a verified host. Show streaming sites in WebKit and everything else
in Chromium.

### Widevine in Chromium

CEF does not ship Google's Widevine content decryption module (CDM).
Chromium's component updater downloads it from Google into the profile
directory, `<rootCacheDirectory>/WidevineCdm/`, on the user's Mac.
`configuration.services.protectedMedia` decides whether it does:

| `services.protectedMedia` | Effect |
|---|---|
| `.automatic` | The component updater runs and fetches Widevine, whatever `services.componentUpdates` says. The default, and the `.browser` preset's. |
| `.disabled` | CefSwift does not ask for the CDM. With `services.componentUpdates = .disabled`, as in the `.embedded` preset, Chromium registers no component, neither downloads the CDM nor loads one already on disk, and refuses `com.widevine.alpha`. With component updates on, Chromium registers Widevine with its other components, and its updater has no way to leave one out: it downloads the CDM at its first check, about a minute after start-up, and pages can use it from then on. |
| `.preinstalled(widevineDirectory:)` | As `.automatic`, and copies a CDM your app carries into the profile before Chromium starts, so protected media works on first launch and offline. Only for apps licensed by Google to distribute the CDM. |

With the updater on, CefSwift asks for Widevine as soon as the app creates
its first browser (Chromium's update service fetches nothing before that),
and the download takes from a few seconds to tens of seconds; left to
itself the updater would wait a minute. Clear Key (`org.w3.clearkey`) is built in and works in every mode.

```swift
var configuration = CefRuntime.Configuration.embedded
configuration.services.protectedMedia = .automatic

// Later, for example before showing a player:
switch await CefRuntime.shared.installWidevine() {
case .installed(let version): print("Widevine \(version)")
case .failed: print("Could not fetch Widevine; offline?")
default: break
}
```

`CefRuntime.shared.widevine` reports `.unavailable`, `.notInstalled`,
`.installing`, `.installed(version:)` or `.failed` at any time. Pages that
asked for `com.widevine.alpha` before it arrived ask again when reloaded.

What Chromium in CefSwift plays with Widevine is content that accepts a
software CDM on an unverified host, in VP9 or AV1 video with Opus audio:
Google's and Shaka Player's test streams, `browser://playground/` in the
Browser example, and services that do not require a verified host.

**Codecs.** CEF's official builds leave out H.264, HEVC and AAC: they are
patent-licensed, and Chromium includes them only in Google Chrome. Content
that offers only those codecs does not play in Chromium here, protected or
not. Enabling them takes a CEF built with `proprietary_codecs=true
ffmpeg_branding=Chrome`, which CefSwift does not use.

**Verified Media Path.** Widevine on desktop has a second requirement that
the major services enforce: the browser binary that hosts the CDM must carry
a Verified Media Path (VMP) signature from Widevine. The CDM reports to the
licence server whether its host is verified, and services such as Netflix
refuse licences to an unverified one (Netflix reports error M7121-1331).
Chrome has it (`Google Chrome Framework.sig`); CEF builds do not, and
CEF 156 passes the CDM no host binary to verify at all: with
`--vmodule=cdm_host_files=1`, the CDM process logs `InitVerification:
Calling VerifyCdmHost_0() with 1 files`, the CDM itself, where Chrome passes
its framework too. So no signing step on your side makes a stock CEF app
verified.

The routes to a verified host are a build of CEF patched to register its
framework's `.sig`, plus either castLabs' commercial VMP certification for
custom Chromium builds (castLabs' free EVS signing service covers its own
Electron builds only) or a licence agreement with Widevine
([widevine.com](https://www.widevine.com)). Both are outside what CefSwift
can do for you.

**Licensing.** The CDM is Google's proprietary software. Its `LICENSE`
reads: "You may not use, modify, sell, or otherwise distribute the Software
without a separate license agreement with Google." Copying it out of Google
Chrome, or bundling it, is distribution; letting Chromium's component
updater fetch it from Google on the user's Mac is the route that needs no
agreement. Pointing an app at the copy inside an installed Chrome gains
nothing either: it is the same CDM the component updater downloads (Chrome
157 and CEF 156 both use 4.10.3112.0), and the host is still unverified.
`.preinstalled(widevineDirectory:)` exists for apps that hold a Widevine
licence covering distribution.

**Signing.** The CDM runs in `<App> Helper.app` and is signed by Google's
team. Under the hardened runtime, library validation lets a process load
libraries from its own team only, so a team-signed helper refuses the CDM.
Add the `protectedMedia` capability to `cefapp.json`; it gives that helper
`com.apple.security.cs.disable-library-validation`. Ad hoc builds without
the hardened runtime need nothing. `CefRuntime.shared.capabilities.canLoadWidevine`
and `cef doctor` report the state. Chromium's sandbox, the mock keychain and
ad hoc signing do not affect Widevine.

### WebKit and FairPlay

`CefSystemBrowser` shows a page with the system's WebKit, the engine Safari
uses, which has FairPlay Streaming through EME. Any app can use it: FairPlay
in a `WKWebView` needs no entitlement, licence or signing, and the page
identifies as Safari, so services serve their Safari player.

It lives in its own library, `CefSystemEngine`, so that apps that never use
it do not link WebKit. Add the `CefSystemEngine` product to your target and
import it:

```swift
import CefSystemEngine

@State private var movie = CefSystemBrowser(url: URL(string: "https://www.netflix.com/")!)

var body: some View {
    CefSystemWebView(movie)
        .navigationTitle(movie.title)
}
```

It has the parts of `CefBrowser`'s surface WebKit offers:

| `CefSystemBrowser` | |
|---|---|
| `url`, `title`, `isLoading`, `estimatedProgress`, `canGoBack`, `canGoForward`, `hasOnlySecureContent` | Observable, as on `CefBrowser`. |
| `load(_:)`, `loadHTML(_:baseURL:)`, `goBack()`, `goForward()`, `reload(ignoringCache:)`, `stopLoading()`, `close()` | Navigation. |
| `evaluateJavaScript(_:)`, `evaluateJavaScript(_:as:)` | Awaits promises; throws `CefJavaScriptError`. |
| `configuration.userScripts` | `CefUserScript`s, with `urlPattern`, `injectionTime` and `frames`, in the page's content world. |
| `find(_:backwards:caseSensitive:)`, `pageZoom`, `snapshot()` | Find, zoom, a PNG of the page. |
| `decidePolicy`, `onOpenWindow` | Main-frame navigation decisions and new windows. |
| `configuration.identifiesAsSafari` | On by default: the User-Agent ends `Version/<Safari's version> Safari/605.1.15`. |
| `nativeView` | The `WKWebView`. |

Chromium's own features (the DevTools protocol, bridges, `chrome://` pages,
extensions, passkey modes, downloads, discarding) belong to `CefBrowser`
only. Element full screen is on and AirPlay is allowed; pages are not
offered picture in picture (`webkitSupportsPresentationMode('picture-in-picture')`
is false in a `WKWebView`).

**Choosing the engine.** `CefSystemBrowser.prefersSystemEngine(for:)` is true
for the hosts in `CefSystemBrowser.protectedStreamingHosts` (Netflix,
Disney+, Prime Video, Max, Hulu, Apple TV, Peacock, Paramount+ and others;
edit the set to suit your app). Hand such navigations over from your
`CefBrowserDelegate`:

```swift
import CefSystemEngine

func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
    guard let url = navigation.url, CefSystemBrowser.prefersSystemEngine(for: url) else { return .allow }
    let profile = browser.configuration.profile ?? .default
    let movie = CefSystemBrowser(configuration: .init(profile: profile))
    Task {
        await movie.importCookies(from: profile, for: url)   // optional: carry a sign-in over
        movie.load(url)
    }
    showInNewTab(movie)
    return .cancel
}
```

**Website data.** WebKit keeps its own cookies and storage, separate from
Chromium's. Each `CefProfile` maps to a WebKit data store: the default
profile to the app's default store, `.persistent(id:displayName:)` to a
persistent store derived from its identifier, and `.incognito()` to an in-memory store discarded with
the profile. `importCookies(from:for:)` copies the Chromium profile's
cookies for one site into the WebKit store, when you call it and not
otherwise.

The Browser example opens streaming services in WebKit tabs by itself
(Settings: "Play streaming services with WebKit"), marks them with a WebKit
badge in the address field, hands a tab back to Chromium when you follow a
link off the service, and has View › Open in WebKit for any page.

### Services

Status as of 2026-11-12, macOS 27.2.1. "Verified here" means tested on this
Mac without an account; signed-in playback could not be tested.

| Service or content | Chromium with Widevine | WebKit with FairPlay |
|---|---|---|
| Google's Widevine test stream (Shaka "Angel One", VP9) | Plays, licence granted (verified here) | — |
| Axinom's FairPlay test stream (H.264) | — | Plays, licence granted (verified here) |
| H.264 or AAC-only content, protected or not | Does not play: no codecs (verified here) | Plays (verified here) |
| Netflix | Refuses playback without VMP (verified by castLabs' and users' reports) | Player starts and is granted `com.apple.fps.3_0` (verified here); signed-in playback expected, unverified. Netflix lists Safari for up to 4K. |
| Hulu, Disney+, Max | Expected to refuse without VMP (reported, unverified here) | Expected to play as in Safari, unverified |
| Prime Video | Reported to fall back to SD without VMP, unverified here | Expected to play as in Safari, unverified |
| Apple TV (tv.apple.com) | Unverified | Expected to play as in Safari, unverified |
| Spotify web player | Expected to play, unverified | Expected to play, unverified |

macOS screenshots leave protected video out, so a captured frame of a
playing DRM video shows black or the page behind it.

**Other DRM.** FairPlay exists only in Apple's WebKit; Chromium on macOS has
no FairPlay. PlayReady exists only in Microsoft Edge and Chrome on Windows.
Firefox uses the same Widevine CDM, downloaded from Google under Mozilla's
own agreement; there is no other DRM a third-party macOS browser can adopt.

## Footprint and launch time

Measured on an Apple M3 MacBook with 16 GB of memory, macOS 27.2.1, CEF
156.0.28, on 2026-11-12, with
[`Scripts/measure-footprint.py`](../Scripts/measure-footprint.py). Each
figure is the median of five runs that relaunch the app on an existing
profile and load a static local page. Memory is the physical footprint of
the app and every helper process, read five seconds after the page
finished loading; it is the figure Activity Monitor shows, not resident
size; 1 MB here is 2^20 bytes. Launch time runs from starting the
executable to the page's `browser(_:didFinishLoadWithStatus:)`. These runs
predate the sandbox being on by default; it adds a few MB in the GPU and
network processes and some tens of milliseconds at launch
([design notes](design-notes.md#sandbox)).

| App | Processes | Memory | Launch |
|---|---|---|---|
| `CefWebView` with `.embedded` (the Minimal example) | 5 | 88 MB | 306 ms |
| The same with `processPolicy = .minimal` | 4 | 82 MB | 284 ms |
| Browser example, one tab, `.browser` | 7 | 166 MB | 551 ms |
| For comparison: a `WKWebView` app | 4 | 60 MB | 284 ms |
| For comparison: Chrome 157, empty profile, one tab | 12 | 286 MB | – |

Launch times vary by about 30 ms from run to run. The first launch after a
bundle is built or signed takes 2 to 3 s longer while macOS checks its signature. A first launch on
an empty profile measures within the same ranges, with up to 4 MB more
memory. The Browser example starts no service host at launch: its
bookmarks come from Chromium's `Bookmarks` file, and its history is read
when the menu bar opens. Measured on a build without the passkey and
Chromium-panel code, it uses:

| Browser example (`measure-services.py browser`, median of 3) | Processes | Memory |
|---|---|---|
| At launch | 6 | 143 MB |
| After typing in the address field, bookmarking the page and opening the menu bar | 9 | 217 MB |
| 40 s later, once the hosts have closed | 6 | 157 MB |

In the Minimal example, the 88 MB divide into the app process (39 MB), the
GPU process (21 MB), the page's renderer (16 MB), and Chromium's network
(8 MB) and storage (6 MB) services.

### What every bundle does

`swift package cef bundle` links the framework into the helper processes and
the app executable, so dyld loads it at launch instead of CefKit loading it
with `dlopen`. That keeps about 12 MB of the framework's data as shared,
clean memory in each process instead of private memory
([architecture](architecture.md#loading-the-framework-at-launch);
[design notes](design-notes.md#loading-the-framework-at-launch) record the
measurement).

### What the presets turn off

| | `Configuration()` | `.embedded` | `.browser` |
|---|---|---|---|
| Background networking, sync, default apps, domain reliability | On | Off | On |
| Component updates (`services.componentUpdates`), Widevine (`services.protectedMedia`) | On | Off | On |
| Translation, preloading, hyperlink auditing, password saving, autofill | On | Off | On |
| Media Router (Cast), optimization hints, Autofill server predictions, on-device model execution | On | Off | On |
| First-run and default-browser prompts | On | Off | Off |
| Spare renderer (`processPolicy`) | `.automatic` | `.onDemand` | `.automatic` |
| Session cookies across launches | Off | Off | On |

### Process policy

`processPolicy` decides how many helper processes Chromium keeps running:

```swift
var configuration = CefRuntime.Configuration.embedded
configuration.processPolicy = .minimal
```

| Policy | Saves | Costs |
|---|---|---|
| `.automatic` | – | Chromium keeps a spare renderer running for the next new site or browser. |
| `.onDemand` | 1 process, 13 MB | A page from a site without a renderer, and each new browser, waits for one to start: a navigation to a new site takes 52 ms instead of 14 ms (local server, median of 8). |
| `.minimal` | 2 processes, 19 MB | As `.onDemand`; and the network service runs in the app's process, so a crash in it ends the app instead of restarting the service, and code that parses network data shares the app's memory. |

The GPU process stays a process of its own in every policy, so that a GPU
driver crash cannot end the app. The
[design notes](design-notes.md#memory-settings-measured-and-not-used) list
the switches measured and not used.

## Known limits

- Chrome style (`chrome://` pages, extensions, history, the password manager)
  exists only in `CefBrowserWindow` and Chrome UI windows, a Chromium
  constraint on macOS. `CefWebView` uses the Alloy style.
- Each Chrome-style window holds one browser; build tabs from native window
  tabs.
- Only Chrome-style browsers record history. Pages shown in a `CefWebView`
  do not appear in `profile.history`.
- `authenticationPrompt` applies to the whole app: Chromium's sign-in
  dialog and the delegate cannot be chosen per browser. HTTP authentication
  requests without a browser, such as a service worker's, are refused.
- Chromium's own Memory Saver never discards a CefKit browser, since each
  is the active tab of its own Chromium window; call `discard()` from your
  own policy instead. A `CefWebView` browser loses its back/forward list
  when discarded, does not report playing audio or form input as blockers, and Chromium tells tabs apart only by
  address and title, so Chrome-style tabs showing the same page under the
  same title cannot be discarded (`.unknown`) until one of them moves on.
- DevTools opens in a window of its own; there is no docked DevTools.
- In offscreen browsers, assistive apps can focus elements inside frames
  only by clicking text fields, and press them only while they are in
  view; elements of the main frame have no such limit. The scroll
  position of scrolling elements other than the document reaches the
  accessibility tree only when Chromium next resends them.
- Offscreen browsers always use the Alloy style and cannot open native
  popup windows.
- `CefAutocomplete` is experimental, and `CefBookmarks`, `CefHistory` and
  `CefAutocomplete` depend on Chromium-internal WebUI hosts, and `CefBookmarks`
  on the format of Chromium's `Bookmarks` file.
- `chromiumUI` and swipe navigation in `CefBrowserWindow` depend on
  Chromium's AppKit classes and the view class names its accessibility
  reports ([architecture](architecture.md#chromiums-appkit-classes)). If a
  CEF update renames them, surfaces show as Chromium draws them, where it
  puts them, with unknown ones reported as `.other`, and browser windows
  swipe as Chrome does, with its arrow, whatever the options say. Commands
  that open surfaces (`.find`, `.createQRCode`, …) still reach custom
  presenters. SelfTest fails on such an update.
- Passkeys answered by the app (`CefBrowser.PasskeyPolicy.app`) are software keys the
  app keeps, not iCloud Keychain passkeys, and their attestation is
  "none". CEF offers no way to hand a request's options to
  AuthenticationServices and return its answer to the page, so iCloud
  Keychain passkeys are available only through Chromium's own
  authenticator (`.chromium`, with the entitlement). The app's
  authenticator is a platform authenticator: a request that asks for a
  cross-platform one (`authenticatorAttachment: "cross-platform"`) waits
  until its timeout. Calls from cross-site iframes, which run in a
  DevTools target of their own, also wait until their timeout without
  reaching the delegate. The app's mode uses the browser's DevTools `Debugger` and
  `WebAuthn` domains; do not use those domains yourself in such a browser.
- A registration in the app's mode is saved to the store after the page
  receives its credential; CefKit cannot withdraw it. A store that passes
  `checkAvailability()` and then fails to save leaves the site with a
  credential the app cannot use; `browser(_:passkeyStoreDidFail:)` gets
  the unsaved passkey.
- Chromium's profile passkey authenticator (Touch ID, `.chromium`) is not
  available: CEF 156 compiles in Chromium's keychain access group,
  `.org.chromium.Chromium.webauthn`, with an empty team identifier, and
  macOS lets a signed app claim only groups its provisioning profile
  authorizes, which start with the team identifier.
- The App Sandbox is not supported, so CefSwift apps do not ship in the
  Mac App Store ([bundling](bundling.md#app-sandbox)).
- Chromium plays Widevine only as an unverified software (L3) client and
  has no H.264, HEVC or AAC, so Netflix-class services do not play in it;
  `CefSystemBrowser` plays them with WebKit and FairPlay
  ([Playing streaming services](#playing-streaming-services)).
- `CefSystemBrowser` keeps website data apart from Chromium's; only
  `importCookies(from:for:)` carries cookies across.
