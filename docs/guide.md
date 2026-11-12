# Guide

Task-oriented reference for CefSwift. Snippets assume `import CefSwiftUI`,
which re-exports `CefKit`. The runtime, browser, window and profile APIs
are `@MainActor`.

- [Starting Chromium](#starting-chromium)
  - [Configuration](#configuration)
  - [Keychain access](#keychain-access)
  - [Preferences](#preferences)
  - [Relaunching](#relaunching)
- [Browsers](#browsers)
- [Showing a browser](#showing-a-browser)
  - [Offscreen rendering](#offscreen-rendering)
  - [Swipe navigation](#swipe-navigation)
  - [Offscreen accessibility](#offscreen-accessibility)
- [Discarding browsers](#discarding-browsers)
- [JavaScript](#javascript)
  - [User scripts and style sheets](#user-scripts-and-style-sheets)
  - [Bridge](#bridge)
- [Decisions](#decisions)
  - [Navigation and new windows](#navigation-and-new-windows)
  - [Downloads](#downloads)
  - [Passkeys](#passkeys)
- [Context menu](#context-menu)
- [Building a browser](#building-a-browser)
  - [Toolbar and window](#toolbar-and-window)
  - [Tabs](#tabs)
  - [Popups](#popups)
  - [Chrome commands](#chrome-commands)
  - [Chromium's own interface](#chromiums-own-interface)
  - [Tabs Chromium opens itself](#tabs-chromium-opens-itself)
- [Customizing Chromium's own pages](#customizing-chromiums-own-pages)
- [Profiles](#profiles)
  - [Bookmarks, history and suggestions](#bookmarks-history-and-suggestions)
- [DevTools](#devtools)
- [Serving your own content](#serving-your-own-content)
- [Known limits](#known-limits)

## Starting Chromium

A SwiftUI app conforms to `CefSwiftApp` instead of `App`. Before SwiftUI
starts, it installs the `NSApplication` subclass Chromium needs
(`CefApplication`) and calls `CefRuntime.shared.initialize(configuration:)`
with `cefConfiguration`:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration.embedded
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
can run `beforeunload` handlers, and then shuts Chromium down. You do not call
`CefRuntime.shared.shutdown()` yourself.

### Configuration

Start from a preset and change what you need:

| Preset | Use |
|---|---|
| `CefConfiguration.embedded` | Showing your own or trusted web content. Turns off background networking, component updates, sync, translation, first-run and default-browser prompts, and starts renderer processes only when a page needs one. |
| `CefConfiguration.browser` | A general-purpose browser. Keeps session cookies across launches and skips first-run and default-browser prompts. |
| `CefConfiguration()` or `.default` | Chromium's defaults. |

Common options:

| Property | Effect |
|---|---|
| `isOffscreenRenderingEnabled` | Required for `.offscreen` browsers. Off by default. |
| `customSchemes` | URL schemes of your own, registered in every Chromium process. See [Serving your own content](#serving-your-own-content). |
| `preferences` | Chromium preferences by dotted name. See [Preferences](#preferences). |
| `productName`, `stringOverrides` | Your product name, and replacements for other built-in strings. See [Customizing Chromium's own pages](#customizing-chromiums-own-pages). |
| `chromeUI` | Hides Chrome app-menu commands, toolbar buttons and page-action icons in Chrome-style windows. |
| `extensions` | Unpacked extension folders (each with a `manifest.json`) to load. Extensions run in Chrome-style browsers. |
| `memoryPolicy` | How many helper processes Chromium keeps running. See [Footprint and launch time](#footprint-and-launch-time). |
| `enabledFeatures`, `disabledFeatures` | Chromium feature names, passed as `--enable-features` and `--disable-features`. |
| `safeStorage` | Whether Chromium uses the keychain. See [Keychain access](#keychain-access). |
| `rootCacheDirectory`, `cacheDirectory` | Where profile data lives. Defaults to `~/Library/Application Support/<bundle ID>/CefSwift`. |
| `persistsSessionCookies` | Whether session cookies survive a relaunch. |
| `locale`, `acceptLanguages` | UI locale and `Accept-Language` list. |
| `userAgent`, `userAgentProduct` | The whole User-Agent string, or its product part. |
| `logSeverity`, `logFile` | Chromium's log. |
| `remoteDebuggingPort` | Exposes the DevTools Protocol on a localhost port. Leave it `nil` in shipping apps. |
| `defaultRuntimeStyle` | Chrome or Alloy style for browsers that do not choose. |
| `isSandboxEnabled` | Chromium's macOS sandbox. See [Sandbox](sandbox.md). |
| `extraCommandLineSwitches`, `onBeforeCommandLineProcessing` | Any other Chromium switch, such as `["proxy-server": "socks5://localhost:1080"]`. |
| `frameworkDirectory`, `helperExecutableURL` | Override where the framework and helper are found. Rarely needed. |

### Keychain access

Chromium encrypts cookies and saved passwords with a key it keeps in the
user's keychain as "Chromium Safe Storage". The first time an app reads that
item, macOS asks the user to allow it. Choosing Always Allow records the
app's code signature, so the question does not come back while the signature
stays the same. An ad hoc signature changes with every build, so ad hoc
signed builds are asked again after each rebuild.

`configuration.safeStorage` chooses the behavior:

| Policy | Behavior |
|---|---|
| `.automatic` (default) | `.keychain` when the app is signed with a team identity, such as an Apple Development or Developer ID certificate; `.mockKeychain` when it is unsigned or ad hoc signed. |
| `.keychain` | Always use the keychain, as Chrome does. |
| `.mockKeychain` | Use a fixed key and never touch the keychain (`--use-mock-keychain`). Nothing is protected at rest; use it for development, demos and tests. |

`cef bundle` signs with your Apple Development or Developer ID identity
when the keychain has one; [bundling](bundling.md#distribution) lists what
each kind of signature allows.

### Signing and capabilities

`CefRuntime.shared.capabilities` (also `CefAppCapabilities.current`)
describes what the running app's signature, entitlements and Info.plist let
Chromium do, so the app can adapt its UI:

```swift
let capabilities = CefRuntime.shared.capabilities
if !capabilities.passkeyAuthenticators.contains(.iCloudKeychain) {
    // Offer the app's own passkeys (CefPasskeyMode.app) instead.
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

To read or change them later, use `CefProfile.preference(_:)` and
`setPreference(_:to:)` for per-profile settings ([Profiles](#profiles)), and
the runtime for application-wide ones:

```swift
let confirms = CefRuntime.shared.preference("browser.confirm_to_quit")?.boolValue
try CefRuntime.shared.setPreference("browser.confirm_to_quit", to: false)
```

`preference(_:)` returns `nil` for an unknown name. `setPreference(_:to:)`
throws `CefError.operationFailed` for an unknown name or a value of the wrong
type, and restores the default when passed `nil`. Values are `CefJSON`,
which accepts Swift literals.

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
| Navigation | `load(_:)`, `goBack()`, `goForward()`, `reload(ignoringCache:)`, `stopLoading()` |
| Page | `isAudioMuted`, `find(_:backwards:caseSensitive:)`, `stopFinding(clearingSelection:)`, `findSession` (an observable find-bar model), `print()`, `printToPDF(at:)`, `snapshot()` |
| JavaScript | `evaluateJavaScript(_:)`, `evaluateJavaScript(_:as:)`, `executeJavaScript(_:)`, `addUserScript(_:)` |
| DevTools | `devTools`, `showDevTools(inspecting:)`, `closeDevTools()`, `isShowingDevTools` |
| Lifetime | `ready()`, `close(force:)` |
| Memory | `isDiscarded`, `discard()`, `restore()`, `discardBlockers()`, `allowsDiscarding`, `discardSnapshot` ([discarding](#discarding-browsers)) |
| Relations | `delegate`, `options`, `opener`, `popupFeatures`, `hostWindow` |

Options are fixed at creation:

```swift
var options = CefBrowserOptions()
options.profile = .persistent(name: "Work")
options.backgroundColor = .windowBackgroundColor
options.requestFilter = { request in
    request.url?.host() == "ads.example" ? .block : .allow
}
let browser = CefBrowser(url: URL(string: "https://swift.org")!, options: options, delegate: policy)
```

A `requestFilter` sees every network request and returns `.allow`, `.block`,
`.redirect(_:)` or `.setHeaders(_:)`. It runs on Chromium's IO thread, so it
must be fast and must not touch main-actor state.

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
another view. `CefWebView(url:options:)` creates and owns its browser,
loads a new URL when `url` changes, and closes the browser when the view
goes away.

`options.rendering` picks how the page draws:

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
var options = CefBrowserOptions()
options.rendering = .offscreen(frameRate: 120)
options.allowsBackForwardNavigationGestures = true
let browser = CefBrowser(url: url, options: options)
```

Pinch and smart magnify change `zoomLevel`. Set
`options.forwardsRawTouchEvents = true` to send trackpad touches to the
page instead of interpreting them as gestures.

Offscreen browsers cannot open native popup windows: a request that would
open one loads in the same browser instead (see
[Navigation and new windows](#navigation-and-new-windows)).

To draw offscreen frames in a view of your own, adopt `CefOffscreenHost` and
call `browser.host(offscreenIn:size:)`. The host receives frames, cursors,
IME ranges, context menus and drags. In return it drives the browser as
AppKit drives a view:

- Lifecycle: `hostViewDidResize()`, `hostViewDidHide()`,
  `hostViewDidUnhide()`, `hostViewDidBecomeKey()`, `hostViewDidResignKey()`,
  `hostViewDidChangeBackingProperties()`, and `displayIfNeeded()` on every
  display refresh.
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

With `options.allowsBackForwardNavigationGestures`, a two-finger swipe that
starts sideways (when the system's "Swipe between pages" setting allows it)
and the dedicated navigation swipe go back and forward, in `CefWebView`,
both renderings, and in `CefBrowserWindow`, where Chrome's own swipe
handling does the work. It is off by default everywhere.

While a swipe is in progress, `browser.navigationGestureProgress` moves from
0 toward -1 (back) or 1 (forward); at ±1 and beyond, releasing navigates.
`options.navigationGestureIndicator` chooses what is drawn over the page:

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
options.offscreenAccessibility = .enabled
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

Discard one browser yourself, or let CefKit do it:

```swift
do {
    try await tab.discard()
} catch .blocked(let blockers) {
    print("kept loaded:", blockers)          // [.visible], [.playingAudio], …
}

CefRuntime.shared.memorySaver = .after(.minutes(30))   // hidden 30 minutes, or memory is low
CefRuntime.shared.memorySaver = .underMemoryPressure    // only when macOS runs low on memory
```

Only a browser that is off screen can be discarded: a window tab that is
not selected, a hidden or minimized window, or a `CefWebView` that is
hidden or out of a visible window. `discardBlockers()` lists what keeps a
browser loaded, and `discard()` throws `CefDiscardError.blocked` with the
same set:

| Blocker | When |
|---|---|
| `.visible` | The browser is on screen. |
| `.exempt` | `allowsDiscarding` is `false` (pinned tabs, say), or an extension protects the tab. |
| `.notLoaded` | The browser is not open yet, is loading, or shows DevTools itself. |
| `.playingAudio` | The page plays sound, or did in the last minute. |
| `.capturingMedia` | The page uses the camera, microphone or screen capture, or is cast. |
| `.formInteraction` | The user typed into the page. |
| `.beforeUnloadHandler` | The page has a `beforeunload` handler. |
| `.devToolsOpen` | The browser's DevTools window is open. |
| `.downloading` | A download it started is in progress. |
| `.pictureInPicture`, `.connectedToDevice` | Picture in picture; a Bluetooth or USB device. |

In a `CefWebView`, audio and form input are read from the main frame's
`<audio>`, `<video>`, `<input>` and `<textarea>` elements; Chrome-style
browsers use Chromium's own signals, which cover every frame and Web Audio.

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

## JavaScript

```swift
let count = try await browser.evaluateJavaScript("document.links.length").intValue
let size = try await browser.evaluateJavaScript("({w: innerWidth, h: innerHeight})", as: Size.self)
```

`evaluateJavaScript(_:)` runs in the main frame, waits for a returned
promise, and returns the value as `CefJSON`. The `as:` form decodes it into
any `Decodable` type. An exception thrown by the script arrives as
`CefJavaScriptError`. `executeJavaScript(_:)` runs a script without waiting
for a result.

### User scripts and style sheets

User scripts run in every document the browser loads, before the page's own
scripts:

```swift
options.userScripts = [
    CefUserScript(source: "window.appVersion = '1.2'"),
    CefUserScript(source: "document.body.dataset.app = 'yes'", matching: "https://*.example.com/*"),
    .styleSheet("header { display: none }", matching: "https://news.example/*"),
]
```

- `matching:` limits a script to URLs that match the pattern as a whole,
  where `*` stands for any run of characters. A matched script runs inside a
  function, so its top-level declarations are not global.
- `isolatedWorldName:` runs the script in an isolated world the page cannot
  see.
- `CefUserScript.styleSheet(_:matching:includingShadowRoots:)` adds CSS. With
  `includingShadowRoots` (the default) its rules also apply inside every
  shadow root, including roots whose component sets its own
  `adoptedStyleSheets`.
- `browser.addUserScript(_:)` adds a script after creation; it applies from
  the next document on.

A selector cannot cross a shadow boundary, even when the rules reach inside
shadow roots. If `#row` lives in the shadow root of `settings-section`, the
selector `settings-section #row` matches nothing; write `#row`.

### Bridge

`CefBridge` exposes Swift methods to JavaScript as functions that return
promises. Arguments and results travel as JSON, so any `Codable` type works.

```swift
struct Person: Codable { var name: String }

let bridge = CefBridge(name: "app")
bridge.handle("greet") { (person: Person) in "Hello, \(person.name)!" }
bridge.handle("save") { (document: Document, call: CefBridgeCall) in
    guard call.origin == "https://app.example.com" else { throw AppError.forbidden }
    try store.save(document)
}

var options = CefBrowserOptions()
options.bridges = [bridge]
```

```js
const reply = await app.greet({ name: "Ada" });
const stop = app.on("themeChanged", theme => apply(theme));
```

- The global exists before any page script runs.
- A handler that throws rejects the promise.
- `bridge.emit("themeChanged", theme)` delivers an event to `app.on`
  listeners, in every browser the bridge is attached to or in one
  (`to: browser`).
- `CefBridgeCall` describes the caller: `browser`, `method`, `origin` and
  `isMainFrame`. Chromium reports the origin and frame, so a page cannot
  forge them.

Handlers run with your app's privileges, so `bridge.access` decides where
the global exists:

| Access | Documents that get the bridge |
|---|---|
| `.mainFrame` (default) | Top-level documents. |
| `.origins(["https://app.example.com"])` | Documents from the listed origins, in any frame. |
| `.anyFrame` | Every document. Use it only for browsers that show nothing but your own content. |

A document outside `access` has no global and no way to reach the bridge's
underlying binding. Calls are checked again in Swift against the origin and
frame Chromium reports. A change to `access` applies to calls at once and to
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
| `browser(_:decidePermissionFor:) async` | `.deny` |
| `browser(_:credentialFor:) async` (HTTP authentication) | Native sign-in sheet. CEF 156 does not call it; see [Known limits](#known-limits) |
| `browser(_:shouldProceedDespite:) async` (certificate errors) | `false`: the load is cancelled |
| `browser(_:decideDestinationFor:suggestedName:) async` | `.allow(destination: nil)`: `~/Downloads` |
| `browser(_:decidePasskeyRequest:) async` | Native passkey sheet; see [Passkeys](#passkeys) |
| `browser(_:decidePolicyFor:)` | `.allow` |
| `browser(_:decideWindowOpenFor:)` | `CefWindowOpenAction.default(for:)` |
| `browser(_:handleKeyEvent:isBeforePage:)` | `false` |
| `browser(_:configureContextMenu:for:)`, `browser(_:handleContextMenuCommand:for:)` | No change |
| `browser(_:handleChromeCommand:disposition:)` | `false`: Chrome runs the command |

Events: `browserDidCreate(_:)`, `browserDidClose(_:)`, `browser(_:didOpen:)`
(a popup or DevTools browser opened on this browser's behalf, which inherits
the delegate), `browser(_:didFinishLoadWithStatus:)`,
`browser(_:didFailLoad:)`, `browser(_:didLog:)`,
`browser(_:renderProcessDidTerminate:)` and
`browser(_:downloadDidUpdate:)`.

`CefDialogPresenter` provides the native sheets behind the defaults, so your
delegate can keep them for some cases.

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

`CefWindowOpenAction.default(for:)`, the default, chooses
`.allowNativePopup` for Chrome-style browsers; for other browsers it loads
the URL in place, and allows a blank popup only when the browser is not
offscreen. Return it for requests you do not handle:

```swift
func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
    guard request.disposition != .newPopup, let url = request.targetURL else { return .default(for: request) }
    openTab(url, inBackground: !request.disposition.prefersForeground)
    return .handled
}
```

### Downloads

`browser.downloads` lists the browser's downloads, oldest first, as
`CefDownload` values with `receivedBytes`, `totalBytes`, `isComplete`,
`isCancelled` and `destinationURL`. Control them with
`pauseDownload(_:)`, `resumeDownload(_:)` and `cancelDownload(_:)`, and start
one with `startDownload(_:)`.

Each download asks the delegate where to save:

```swift
func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision {
    guard let folder = await chooseFolder() else { return .deny }
    return .allow(destination: folder.appending(path: suggestedName))
}
```

### Passkeys

`options.passkeys` chooses who answers a page's WebAuthn calls,
`navigator.credentials.create()` and `.get()`:

| Mode | Who answers |
|---|---|
| `.chromium` (default) | Chromium, with its own dialog and authenticators. |
| `.app(store)` | Your app, from a `CefPasskeyStore`, through the delegate. Chromium's dialog and authenticators are not used. |
| `.disabled` | Nobody: every call rejects with `NotAllowedError`. |

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
var options = CefBrowserOptions()
options.passkeys = .app(CefKeychainPasskeyStore())

func browser(_ browser: CefBrowser, decidePasskeyRequest request: CefPasskeyRequest) async -> CefPasskeyDecision {
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
- The default, `CefPasskeyPresenter.present(_:in:)`, ignores requests
  without a user gesture, shows a sheet naming the site (with an account
  menu when several passkeys fit), and verifies the user with Touch ID or
  the account password through `LAContext` before answering.

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

Adopt `CefPasskeyStore` (`passkeys()`, `save(_:)`, `remove(_:)`) to keep
them elsewhere, such as in a password manager.

Chrome's settings link to Chromium's password manager from Autofill and
passwords → Passkeys. That tab arrives through
[`onChromiumOpensTab`](#tabs-chromium-opens-itself) like the other
password-manager links.

The Browser example has a Passkeys setting (Chromium or the browser
itself) and lists and removes saved passkeys in its Settings window
(`BrowserPasskeys.swift`).

## Context menu

Shape the menu without a delegate through `options.contextMenu`:

```swift
options.contextMenu.hiddenCommands = [.viewSource, .print]
options.contextMenu.showsInspectElement = true
options.contextMenu.items = [
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
| `titleFollowsPage` | Keeps the window title in sync with the page title. On by default. |
| `isFrameless` | Removes the title bar and window buttons. |

`CefRuntime.shared.openChromeWindow(url:frame:options:delegate:)` opens a
window drawn entirely by Chrome instead, with its tab strip, omnibox and
menus.

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
with a location bar.

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

`configuration.chromeUI` trims Chrome's own UI in Chrome-style windows:
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

In SwiftUI, mark the views in your toolbar:

```swift
AddressField(browser: browser)
    .chromiumSurfaceAnchor(alignment: .trailing)
Button("QR Code", systemImage: "qrcode") { browser.execute(.createQRCode) }
    .chromiumSurfaceAnchor([.qrCode])
```

- `CefSurfaceAnchor` is `.view(_:alignment:spacing:)` or
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
| HTTP sign-in | `.signIn` | Yes | No: the credentials go to Chromium's dialog | Dismissing cancels the sign-in. |
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

Chromium sometimes opens a tab on its own, without an opener: following a
link from `chrome://settings` to the password manager, or restoring the
previous session after a crash. It would show that tab in a window with
Chrome's tab strip and toolbar. An app with its own tabs takes these over:

```swift
CefRuntime.shared.onChromiumOpensTab = { url in openTab(url) }
```

Chromium's window is closed before it appears, and your handler receives the
URL it was opening. Popups and DevTools, which have an opener, are not
affected. Leave `onChromiumOpensTab` unset in apps that use
`openChromeWindow`, whose new tabs Chromium also opens itself.

Every other browser Chromium creates on its own, popups and DevTools
included, is passed to `CefRuntime.shared.onBrowserCreated`. Assign a
delegate there to manage it. Tabs that `onChromiumOpensTab` takes over do
not reach `onBrowserCreated`. `CefRuntime.shared.browsers` lists every live
browser.

## Customizing Chromium's own pages

Chrome-style browsers show Chromium's internal pages, such as
`chrome://settings`, `chrome://history` and `chrome://downloads`. You can
rename, restyle and replace them.

**Names.** `productName` replaces "Chromium" in settings, `chrome://version`,
dialogs and the About page. `stringOverrides` replaces any other built-in
string by its `IDS_*` identifier, as a `CefStringID`. The named constants are
`.productName`, `.shortProductName` and `.companyName`; other identifiers are
in the vendored `cef_pack_strings.h` and can change between CEF versions.

```swift
configuration.productName = "Orbit"
configuration.stringOverrides[.companyName] = "Orbit Software"
```

**Scripts and styles.** User scripts also run on `chrome://` pages; scope
them with a URL pattern:

```swift
options.userScripts = [
    .styleSheet("#about-menu { display: none !important }", matching: "chrome://settings/*"),
]
```

Internal pages are built from web components whose markup sits in shadow
roots. `styleSheet(_:matching:includingShadowRoots:)` reaches into them, but
a selector cannot cross a shadow boundary: write `#themeRow`, not
`settings-appearance-page #themeRow`, because the row lives in that
component's shadow root. Matching rows by the preference they edit
(`settings-toggle-button[pref-key="browser.show_home_button"]`) holds up
across Chromium updates better than matching by position. On `chrome://`
pages, scripts run as the page starts loading rather than before its own
scripts, and scripts with an `isolatedWorldName` do not run.

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
| `CefProfile.default` | `cacheDirectory`, used when `options.profile` is `nil`. |
| `CefProfile.persistent(name:)` | `<rootCacheDirectory>/Profiles/<name>`. The same name returns the same profile. |
| `CefProfile.incognito()` | In memory only; discarded with the profile. |

```swift
let profile = CefProfile.persistent(name: "Work")
try profile.setPreference("credentials_enable_service", to: false)
let fontSize = profile.preference("webkit.webprefs.default_font_size")?.intValue
profile.setColorScheme(.dark, accentColor: .systemIndigo)

let cookies = await profile.cookies(for: url)
profile.setCookie(cookie)                        // an HTTPCookie
profile.deleteCookies(for: url, named: "session")
```

`allPreferences(includingDefaults:)` returns every preference as one JSON
object. `setColorScheme(_:accentColor:)` themes Chrome-style UI and sets the
`prefers-color-scheme` pages see.

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
  this API and in Chrome's UI.
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
  query supersedes one still running, which then returns no suggestions. The
  first query waits for the service to start; call
  `await autocomplete.prepare()` when your address field begins editing to
  start it early. Search-engine suggestions come from the network; filter on
  `kind` to keep only local results.

CEF has no API for any of this. CefKit uses the services Chromium's own
pages use, from hidden browsers that it opens on first use:
`chrome.bookmarks` on the bookmarks page, and the Mojo handlers of the
history, new tab and `chrome://omnibox` pages. Their windows stay
invisible, even when Chromium brings its windows forward. The default
profile's hidden browsers stay open until the app quits. Those of any other
profile close when the profile's last browser closes, which lets an
incognito profile and its data go, and start again on the next call. These interfaces are internal
to Chromium and more likely than the rest of CefKit to change with a
Chromium update; `chrome://omnibox` is a debugging page, so `autocomplete`
is experimental. SelfTest exercises all three, so a CEF update that breaks
one fails CI.

The Browser example uses them for address-field suggestions
(`AddressSuggestions.swift`), a bookmark star, Bookmarks and History menus,
and a start page whose tiles come from `mostVisited()` and
`bookmarks.recent()` through a `CefBridge` (`BrowserLibrary.swift`).

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
`CefDevToolsError`. `events(_:)` streams one event's parameters until the
browser closes or the consuming task is cancelled; enable the event's domain
first.

`browser.showDevTools()` opens the DevTools window, and
`showDevTools(inspecting:)` inspects the element at a point in view
coordinates.

## Serving your own content

Declare the scheme in the configuration, then register a handler once
Chromium is running, before any page loads from it. In a `CefSwiftApp`, the
app's `init()` is the place:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration.embedded
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
file extensions, and never outside that folder. For generated content,
implement `CefSchemeHandler`:

```swift
struct Pages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data("<h1>\(request.urlString)</h1>".utf8))
    }
}
```

Requests arrive off the main thread, so handlers are `Sendable`. A
registered handler serves every profile, including incognito and persistent
ones. The default `CefCustomScheme` options make the scheme standard,
secure, CORS-enabled and fetchable; pass `options:` to change them.

## Footprint and launch time

Measured on an Apple M3 MacBook with 16 GB of memory, macOS 27.2.1, CEF
156.0.28, on 2026-11-12, with
[`Scripts/measure-footprint.py`](../Scripts/measure-footprint.py). Each
figure is the median of five runs that relaunch the app on an existing
profile and load a static local page. Memory is the physical footprint of
the app and every helper process, read five seconds after the page
finished loading; it is the figure Activity Monitor shows, not resident
size; 1 MB here is 2^20 bytes. Launch time runs from starting the
executable to the page's `didFinishLoad`.

| App | Processes | Memory | Launch |
|---|---|---|---|
| `CefWebView` with `.embedded` (the Minimal example) | 5 | 88 MB | 306 ms |
| The same, before the changes below | 6 | 185 MB | 276 ms |
| The same with `memoryPolicy = .minimal` | 4 | 82 MB | 284 ms |
| Browser example, one tab, `.browser` | 8 | 260 MB | 527 ms |
| The same, before the changes below | 8 | 371 MB | 559 ms |
| For comparison: a `WKWebView` app | 4 | 60 MB | 284 ms |
| For comparison: Chrome 157, empty profile, one tab | 12 | 286 MB | – |

Launch times vary by about 30 ms from run to run, so none of the changes
measurably changes them. The first launch after a bundle is built or signed
takes 2 to 3 s longer while macOS checks its signature. A first launch on
an empty profile measures within the same ranges, with up to 4 MB more
memory. The Browser example has four renderers: the tab, the spare
renderer, and the hidden pages behind `profile.bookmarks` and
`profile.history`, which the example reads at launch for its menus.

In the Minimal example, the 88 MB divide into the app process (39 MB), the
GPU process (21 MB), the page's renderer (16 MB), and Chromium's network
(8 MB) and storage (6 MB) services.

### What every bundle does

`swift package cef bundle` links the framework into the helper processes and
the app executable, so dyld loads it at launch instead of CefKit loading it
with `dlopen`. That keeps about 12 MB of the framework's data as shared,
clean memory in each process instead of private memory, and is most of the
difference between the "before" rows and the rest
([architecture](architecture.md#loading-the-framework-at-launch)).

### What the presets turn off

| | `.default` | `.embedded` | `.browser` |
|---|---|---|---|
| Background networking, component updates, sync, domain reliability, phishing detection, pings, crash reporting | On | Off | On |
| Translate, Media Router (Cast), optimization hints, Autofill server, feed suggestions | On | Off | On |
| First-run and default-browser prompts | On | Off | Off |
| Spare renderer (`memoryPolicy`) | `.standard` | `.reduced` | `.standard` |
| Session cookies across launches | Off | Off | On |

### Memory policy

`memoryPolicy` decides how many helper processes Chromium keeps running:

```swift
var configuration = CefConfiguration.embedded
configuration.memoryPolicy = .minimal
```

| Policy | Saves | Costs |
|---|---|---|
| `.standard` | – | Chromium keeps a spare renderer running for the next new site or browser. |
| `.reduced` | 1 process, 13 MB | A page from a site without a renderer, and each new browser, waits for one to start: a navigation to a new site takes 52 ms instead of 14 ms (local server, median of 8). |
| `.minimal` | 2 processes, 19 MB | As `.reduced`; and the network service runs in the app's process, so a crash in it ends the app instead of restarting the service, and code that parses network data shares the app's memory. |

### Measured and left out

These changes were measured on the Minimal example and left out, because
they saved nothing on an idle page, cost more than they saved, or save the
same as `.reduced`:

- `--js-flags=--lite-mode` and `--js-flags=--optimize-for-size`: no
  difference while idle; both slow JavaScript down.
- `--disable-extensions`, `--disable-spell-checking`, and turning off
  optimization-guide model downloads, Safe Browsing real-time lookups,
  certificate-transparency updates and preloading: no difference.
- `--disable-gpu-compositing`: 10 MB more.
- `--renderer-process-limit=1` and `--disable-site-isolation-trials`: save
  the spare renderer, as `.reduced` does; the second also gives up site
  isolation.
- `--enable-low-end-device-mode`: saves the spare renderer and 3 MB more in
  the GPU process, and lowers rendering quality.

The GPU process stays a process of its own in every policy, so that a GPU
driver crash cannot end the app.

## Known limits

- Chrome style (`chrome://` pages, extensions, history, the password manager)
  exists only in `CefBrowserWindow` and Chrome UI windows, a Chromium
  constraint on macOS. `CefWebView` uses the Alloy style.
- Each Chrome-style window holds one browser; build tabs from native window
  tabs.
- Only Chrome-style browsers record history. Pages shown in a `CefWebView`
  do not appear in `profile.history`.
- CEF 156 does not call `browser(_:credentialFor:)` for HTTP
  authentication. Chrome-style browsers show Chromium's own sign-in dialog
  over the page. In a `CefWebView` the load fails with
  `ERR_INVALID_AUTH_CREDENTIALS`, reported to `browser(_:didFailLoad:)`, and
  Chromium shows its sign-in dialog in a window of its own; closing the
  browser leaves the page first, which dismisses that window.
- Chromium's own Memory Saver never discards a CefKit browser, since each
  is the active tab of its own Chromium window; use
  `CefRuntime.shared.memorySaver` instead. A `CefWebView` browser loses its
  back/forward list when discarded, and Chromium tells tabs apart only by
  address and title, so of two hidden Chrome-style tabs showing the same
  page, discarding one may briefly reload the other.
- DevTools opens in a window of its own; there is no docked DevTools.
- In offscreen browsers, assistive apps can focus elements inside frames
  only by clicking text fields, and press them only while they are in
  view; elements of the main frame have no such limit. The scroll
  position of scrolling elements other than the document reaches the
  accessibility tree only when Chromium next resends them.
- Offscreen browsers always use the Alloy style and cannot open native
  popup windows.
- `CefAutocomplete` is experimental, and `CefBookmarks`, `CefHistory` and
  `CefAutocomplete` depend on Chromium-internal pages.
- `chromiumUI` and swipe navigation in `CefBrowserWindow` depend on
  Chromium's AppKit classes and the view class names its accessibility
  reports ([architecture](architecture.md#chromiums-appkit-classes)). If a
  CEF update renames them, surfaces show as Chromium draws them, where it
  puts them, with unknown ones reported as `.other`, and browser windows
  swipe as Chrome does, with its arrow, whatever the options say. Commands
  that open surfaces (`.find`, `.createQRCode`, …) still reach custom
  presenters. SelfTest fails on such an update.
- Passkeys answered by the app (`CefPasskeyMode.app`) are software keys the
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
- Chromium's profile passkey authenticator (Touch ID, `.chromium`) is not
  available: CEF 156 compiles in Chromium's keychain access group,
  `.org.chromium.Chromium.webauthn`, with an empty team identifier, and
  macOS lets a signed app claim only groups its provisioning profile
  authorizes, which start with the team identifier.
- The App Sandbox is not supported, so CefSwift apps do not ship in the
  Mac App Store ([bundling](bundling.md#app-sandbox)).
