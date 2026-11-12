# Guide

Every snippet assumes `import CefSwiftUI` (which re-exports `CefKit`).

## Start-up

A SwiftUI app conforms to `CefSwiftApp`; `cefConfiguration` customizes Chromium:

```swift
@main
struct MyApp: CefSwiftApp {
    static var cefConfiguration: CefConfiguration {
        var configuration = CefConfiguration.embedded   // or .browser, or CefConfiguration()
        configuration.productName = "Orbit"             // replaces "Chromium" in Chromium's UI
        configuration.extensions = [extensionFolder]    // unpacked extensions
        configuration.enabledFeatures = ["SomeFeature"] // --enable-features
        configuration.extraCommandLineSwitches["proxy-server"] = "socks5://localhost:1080"
        return configuration
    }
    var body: some Scene { … }
}
```

AppKit apps call `try CefRuntime.shared.initialize(configuration:)` first
thing in `main`, before anything touches `NSApp`.

### Preferences

`preferences` sets Chromium preferences — the settings behind
`chrome://settings` — by dotted name, for every profile when it is first
used, or for the whole app when Chromium keeps the setting application-wide:

```swift
configuration.preferences["credentials_enable_service"] = false   // no password manager
configuration.preferences["webkit.webprefs.default_font_size"] = 18
configuration.preferences["browser.confirm_to_quit"] = false      // application-wide
```

Change them later per profile with `CefProfile.setPreference(_:to:)`
([Profiles](#profiles)), or application-wide with
`CefRuntime.shared.setPreference(_:to:)`.

## Browsers and views

`CefBrowser` is the model; views show it.

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

A browser you create stays alive until you call `close()`, so it survives its
view leaving and re-entering the hierarchy. `CefWebView(url:)` owns its
browser and closes it with the view.

Options are set at creation:

```swift
var options = CefBrowserOptions()
options.rendering = .offscreen                       // composited layer; native UI can overlap
options.profile = .persistent(name: "Work")
options.userScripts = [CefUserScript(source: "window.appVersion = '1.2'")]
options.requestFilter = { $0.url?.host() == "ads.example" ? .block : .allow }
let browser = CefBrowser(url: url, options: options)
```

In AppKit, assign the browser to a `CefWindowedBrowserView` or
`CefOffscreenBrowserView`.

### Offscreen rendering

Offscreen browsers draw into a layer, so SwiftUI can clip, animate and
overlap them. They need the runtime switch:

```swift
configuration.isOffscreenRenderingEnabled = true
```

```swift
var options = CefBrowserOptions()
options.rendering = .offscreen(frameRate: 120)
options.allowsBackForwardNavigationGestures = true   // two-finger swipe goes back and forward
let browser = CefBrowser(url: url, options: options)
```

Pinch and smart magnify change `browser.zoomLevel`. While a swipe is in
flight, `browser.navigationGestureProgress` runs from 0 toward -1 (back) or
1 (forward); there is no built-in indicator, so draw your own:

```swift
CefWebView(browser)
    .overlay(alignment: browser.navigationGestureProgress < 0 ? .leading : .trailing) {
        let progress = abs(browser.navigationGestureProgress)
        Image(systemName: browser.navigationGestureProgress < 0 ? "chevron.left" : "chevron.right")
            .padding(12)
            .background(.regularMaterial, in: .circle)
            .opacity(progress)
    }
```

`options.forwardsRawTouchEvents = true` sends trackpad touches to the page
instead of interpreting gestures.

To host offscreen frames in a view of your own, implement
`CefOffscreenHost` and call `browser.host(offscreenIn:size:)`. The view
drives the browser as AppKit drives a view: `hostViewDidResize()`,
`hostViewDidHide()`, `hostViewDidUnhide()`, `hostViewDidBecomeKey()` and
`hostViewDidResignKey()` as those happen, and `displayIfNeeded()` on every
display refresh. Input goes in through
`sendMouseDown(at:button:clickCount:modifiers:)`, `sendMouseExit(at:modifiers:)`,
`sendScrollWheel(at:delta:modifiers:)`,
`sendKeyEvent(_:)`, `sendTouchEvent(_:)`,
`setMarkedText(_:selectedRange:replacementRange:)`,
`insertText(_:replacementRange:)`, and `draggingEntered`, `draggingUpdated`,
`draggingExited` and `performDrop`, which mirror `NSDraggingDestination`.

## JavaScript

```swift
let count = try await browser.evaluateJavaScript("document.links.length").intValue
let size = try await browser.evaluateJavaScript("({w: innerWidth, h: innerHeight})", as: Size.self)
```

Promises are awaited; a thrown exception arrives as `CefJavaScriptError`.

### Bridge

```swift
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
app.on("themeChanged", theme => apply(theme));
```

`bridge.emit("themeChanged", theme)` delivers events. The global exists
before any page script runs. By default only the top-level page may call
(`bridge.access`); frames from other sites never receive the bridge.

## Decisions

Implement the `CefBrowserDelegate` methods you care about. The rest keep
their defaults — native sheets for JavaScript dialogs and sign-in, deny for
permissions, `~/Downloads` for downloads.

```swift
final class Policy: CefBrowserDelegate {
    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        await askUser(request) ? .allow : .deny
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard request.disposition == .newBackgroundTab, let url = request.targetURL else {
            return .default(for: request)
        }
        openTab(url)
        return .handled
    }

    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        dialog.kind == .alert ? .accept() : await CefDialogPresenter.present(dialog, in: browser.hostWindow)
    }
}
```

## Context menu

```swift
options.contextMenu.hiddenCommands = [.viewSource, .print]
options.contextMenu.showsInspectElement = true
options.contextMenu.items = [
    CefContextMenuItem("Search Notes", isVisible: { !$0.selectedText.isEmpty }) { _, target in
        search(target.selectedText)
    },
]
```

`options.contextMenu.isEnabled = false` removes the menu. For menus that
depend on app state, implement `browser(_:configureContextMenu:for:)`.

## Building a browser

```swift
let browser = CefBrowser(url: home, delegate: policy)
let window = CefBrowserWindow(browser: browser)
window.setToolbar {
    NavigationButtons(browser: browser)    // beside the window buttons
} principal: {
    AddressBar(browser: browser)           // centered
} trailing: {
    Button("New Tab", systemImage: "plus", action: openTab)
}
window.setTabAccessory { TabIcon(browser: browser) }   // favicon or spinner in the native tab
window.show()
```

The toolbar is a unified `NSToolbar` of SwiftUI views bound to the browser
as usual, with the window buttons centered beside it;
`setToolbar(principal:)` sets only the centered view. Installing it keeps the
window's frame.

Around the page:

```swift
window.topAccessory = statusBanner                         // an NSView between title bar and page
window.contentInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
window.contentCornerRadius = 10                            // page as an inset, rounded card
```

Popups a page opens (`window.open` with features, sign-in flows) arrive
through `onPopup` as hidden windows of their own, still connected to their
opener. `popup.browser.popupFeatures` holds the size and position the page
asked for. Without `onPopup`, Chromium shows them in a window of its design.

```swift
window.onPopup = { popup in
    guard let panel = popup.window, let parent = window.window else { return }
    if let size = popup.browser.popupFeatures?.size {
        panel.setContentSize(size)
    }
    panel.tabbingMode = .disallowed
    parent.addChildWindow(panel, ordered: .above)   // layered over its opener
    popup.show()
}
```

A popup closes itself when its page calls `window.close()`; it stays open
when its opener closes unless you close it.

- Give windows the same `configuration.tabbingIdentifier` and macOS groups
  them as native tabs.
- `browser.execute(.find)`, `.print`, `.createQRCode`, `.showHistory`, … run
  Chrome's own commands; `browser(_:handleChromeCommand:disposition:)`
  intercepts them.
- `CefConfiguration.chromeUI` hides Chrome app-menu entries, toolbar buttons
  and page-action icons.
- `CefRuntime.shared.openChromeWindow(url:)` opens a window drawn entirely by
  Chrome, tab strip included.

### Tabs Chromium opens itself

Chromium sometimes opens a tab on its own: following a link from
`chrome://settings` to the password manager, or restoring the previous
session after a crash. It would show it in a window with Chrome's own tab
strip and toolbar. A browser with its own tabs takes these over instead —
Chromium's window is closed before it is seen, and you get the URL:

```swift
CefRuntime.shared.onChromiumOpensTab = { url in openTab(url) }
```

Every browser Chromium creates, popups and DevTools included, is also
reported to `CefRuntime.shared.onBrowserCreated` and listed in
`CefRuntime.shared.browsers`. Leave `onChromiumOpensTab` unset when you use
`openChromeWindow`, whose new tabs Chromium also opens itself.

Chromium saves every Chrome-style window in its session, including the
hidden ones CefKit keeps for bookmarks, history and suggestions, and
reopens them after a crash. Those are recognized and closed, never handed
to `onChromiumOpensTab`.

## Customizing Chromium's own pages

Chrome-style browsers show Chromium's internal pages — `chrome://settings`,
`chrome://history`, `chrome://downloads`. You can rename, restyle and
replace them.

**Names.** `productName` replaces "Chromium" throughout; `stringOverrides`
replaces any other built-in string by its `IDS_*` identifier
(`CefStringID`):

```swift
configuration.productName = "Orbit"
configuration.stringOverrides[.companyName] = "Orbit Software"
```

**Scripts and styles.** User scripts run on internal pages too. Scope them
with a URL pattern, where `*` stands for any run of characters and the
pattern must match the whole URL:

```swift
options.userScripts = [
    CefUserScript(source: "document.title = 'Orbit Settings'", matching: "chrome://settings/*"),
    .styleSheet("#about-menu { display: none !important }", matching: "chrome://settings/*"),
]
```

Internal pages are built from web components whose markup sits in shadow
roots; `styleSheet(_:matching:includingShadowRoots:)` applies its rules
inside every shadow root as well (the default), so selectors for a
component's internals match — also in components that set their own
`adoptedStyleSheets`. A selector still cannot cross a shadow boundary:
write `#themeRow`, not `settings-appearance-page #themeRow`, since the row
lives in that component's shadow root. Matching rows by the preference
they edit (`settings-toggle-button[pref-key="browser.show_home_button"]`)
holds up better across Chromium updates than matching by position. On `chrome://` pages scripts run as the page
starts loading rather than before its own scripts, and scripts with an
`isolatedWorldName` do not run there. A scoped script runs inside a
function, so its top-level declarations are not global.

**Replacing a page.** Cancel the navigation and load your own page, served
from a custom scheme:

```swift
// configuration.customSchemes = [CefCustomScheme(name: "orbit")]
// CefRuntime.shared.registerSchemeHandler(scheme: "orbit", handler: OrbitPages())

func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
    guard navigation.url?.absoluteString.hasPrefix("chrome://settings/help") == true else { return .allow }
    browser.load(URL(string: "orbit://about/")!)
    return .cancel
}

struct OrbitPages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data(aboutPage.utf8))
    }
}
```

The Browser example replaces Chromium's About page this way
(`BrowserPages.swift`).

## Profiles

```swift
let profile = CefProfile.persistent(name: "Work")
try profile.setPreference("credentials_enable_service", to: false)
profile.setColorScheme(.dark, accentColor: .systemIndigo)
let cookies = await profile.cookies(for: url)
```

Preferences are the settings behind `chrome://settings`; browse them with
`profile.allPreferences()`.

### Bookmarks, history and suggestions

A profile gives you the data behind Chromium's own bookmarks, history and
address bar:

```swift
let bookmark = try await profile.bookmarks.add(url, title: "CefSwift")
let folders = try await profile.bookmarks.tree()
for await _ in profile.bookmarks.changes { /* refresh your UI */ }

let visits = try await profile.history.search("swift", limit: 20)
let topSites = try await profile.history.mostVisited()
try await profile.history.remove(visits)

let suggestions = try await profile.autocomplete.suggestions(for: "cef")
```

`suggestions(for:)` returns what Chrome's address bar would show, ranked,
with `relevance` and `inlineCompletion`. Call it on every keystroke: a
newer query supersedes one still running, which returns no suggestions.
The first query waits for the service to start; call
`autocomplete.prepare()` when your address field begins editing to start
it early. Each suggestion has a `kind` (history, bookmark, open tab,
search, …) for choosing an icon, `detail` for a page's title, and
`isBookmarked`.

The Browser example puts all three to use: suggestions under the address
field (`AddressSuggestions.swift`), a star and a Bookmarks menu, a History
menu, and a start page whose tiles come from `mostVisited()` and
`bookmarks.recent()` through a `CefBridge` (`BrowserLibrary.swift`).

CEF has no API for any of this. CefKit asks the same services Chromium's
own pages use, from a hidden browser that it opens on first use and closes
at quit: bookmarks through the `chrome.bookmarks` interface of the bookmarks
page, history and most-visited sites through those pages' Mojo handlers, and
suggestions through the handler of `chrome://omnibox`. The last is a
debugging interface and the likeliest to change between Chromium versions,
so `autocomplete` is marked experimental. The SelfTest example exercises all
of them, so a CEF update that breaks one fails CI.

## DevTools Protocol

```swift
try await browser.devTools.send("Emulation.setDeviceMetricsOverride",
    ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true])
try await browser.devTools.send("Network.enable")
for await event in browser.devTools.events("Network.responseReceived") {
    print(event["response"]["url"].stringValue ?? "")
}
```

`browser.showDevTools()` opens the DevTools window.

## Serving your own content

```swift
configuration.customSchemes = [CefCustomScheme(name: "app")]
// after start-up:
CefRuntime.shared.registerSchemeHandler(
    scheme: "app", handler: CefDirectorySchemeHandler(directory: webRoot))
// load app://local/index.html
```

A registered handler serves every profile, incognito and persistent ones
included.

## Known limits

- Chrome style (the `chrome://` pages, extensions) is only available in
  `CefBrowserWindow` and Chrome UI windows — a Chromium constraint on macOS.
  Views embedded with `CefWebView` use the lighter Alloy style.
- One Chrome-style browser per window; use native window tabs for tabbed UIs.
- Offscreen pages are exposed to VoiceOver as a single element.
- Only Chrome-style browsers (`CefBrowserWindow`) record history; pages in
  a `CefWebView` do not appear in `profile.history`.
- CEF 156 does not ask `browser(_:credentialFor:)` about HTTP authentication:
  Chrome-style browsers show Chromium's own sign-in dialog, and in
  `CefWebView` the request fails with `ERR_INVALID_AUTH_CREDENTIALS`.
