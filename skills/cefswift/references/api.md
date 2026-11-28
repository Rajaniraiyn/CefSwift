# API cheat sheet

Snippets assume `import CefSwiftUI` (which re-exports `CefKit`) and, where
marked, `import CefChromium` or `import CefPasskeys`. Everything here is
`@MainActor`. The full reference is `docs/guide.md`.

## Runtime

```swift
@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.chrome   // or .embedded, or .init()
        configuration.productName = "My Browser"
        configuration.customSchemes = [CefCustomScheme(name: "app")]
        configuration.isOffscreenRenderingEnabled = false
        configuration.preferences["browser.confirm_to_quit"] = false
        return configuration
    }

    init() {
        // Chromium runs here: register scheme handlers before any page loads.
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

| Preset | For |
|---|---|
| `.embedded` | Your own or trusted content. Background services, component updates, Widevine, sync, translation and autofill off. |
| `.chrome` | Arbitrary sites with Chrome's services, Widevine included. Keeps session cookies. |
| `CefRuntime.Configuration()` | Chromium's defaults. |

Other options: `processPolicy` (`.automatic`, `.onDemand`, `.minimal`),
`enabledFeatures` / `disabledFeatures`, `extraCommandLineSwitches`,
`rootCacheDirectory`, `userAgent`, `localization`, `acceptLanguages`,
`services.protectedMedia`, `chromeToolbar.hiddenAppMenuCommands`,
`extensions` (`.webStore(id)`, `.package(at:id:version:)`, `.unpacked(at:)`),
`remoteDebuggingPort` (never in shipping apps).

`CefRuntime.shared`: `state`, `onPageCreated` (pages Chromium makes
itself), `onRelaunch` (a second launch of the app), `openChromeWindow(url:)`,
`registerSchemeHandler(scheme:handler:)`, `capabilities`.

## Pages and views

```swift
struct Reader: View {
    @State private var page = CefPage(url: URL(string: "https://swift.org")!)

    var body: some View {
        CefWebView(page)
            .navigationTitle(page.title)
            .toolbar {
                Button("Back", systemImage: "chevron.left", action: page.goBack)
                    .disabled(!page.canGoBack)
            }
    }
}
```

- `CefWebView(url:)` owns and closes its page; `CefWebView(page)` never
  closes the page you pass.
- `CefPage` is `@Observable`: `url`, `title`, `isLoading`,
  `estimatedProgress`, `canGoBack`, `canGoForward`, `favicon`, `zoomLevel`,
  `statusText`, `downloads`, `findSession`, `isDiscarded`, `state`.
- Commands: `load(_:)` (await the returned `CefNavigation`),
  `goBack()`, `goForward()`, `reload(ignoringCache:)`, `stopLoading()`,
  `waitUntilLoaded(timeout:)`, `zoom(.zoomIn)`, `find(_:)`, `print()`,
  `pdf(configuration:)`, `snapshot()`, `showDevTools()`, `discard()`,
  `close()`, `execute(.find)` (Chrome commands, Chrome-style pages only).
- `CefPage.Configuration`: `profile`, `rendering` (`.windowed`,
  `.offscreen(frameRate:)`), `bridges`, `userScripts`, `attachments`,
  `requestFilter`, `allowsBackForwardNavigationGestures`, `content`
  (`javaScript`, `images`, `clipboardAccess`, …).
- AppKit: `CefWindowedPageView(page:)`, `CefOffscreenPageView`.

## JavaScript

```swift
let count = try await page.evaluateJavaScript("document.links.length").intValue
let size = try await page.evaluateJavaScript("({w: innerWidth, h: innerHeight})", as: Size.self)

struct Person: Codable { var name: String }
let bridge = CefBridge(name: "app")
bridge.handle("greet") { (person: Person) in "Hello, \(person.name)!" }
pageConfiguration.bridges = [bridge]        // or profile.bridges for every page
bridge.emit("themeChanged", "dark")         // to app.on("themeChanged", …) in the page

profile.userScripts = [CefUserScript(source: "window.appVersion = '1.2'")]
pageConfiguration.userScripts = [.styleSheet("header { display: none }", matching: ["https://news.example/*"])]
```

In the page: `await app.greet({ name: "Ada" })`. Check `call.origin` in
handlers that take a `CefBridge.Call`.

## Decisions (CefPageDelegate)

Every method has a default; implement what you need. The page holds the
delegate weakly.

```swift
final class Policy: CefPageDelegate {
    func page(_ page: CefPage, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        await askUser(about: request.kinds, from: request.origin.absoluteString) ? .allow : .deny
    }
}
```

Others: `page(_:decidePolicyFor:)` (navigation), `page(_:decideWindowOpenFor:)`,
`page(_:runJavaScriptDialog:)`, `page(_:credentialFor:)`,
`page(_:shouldProceedDespite:)`, `page(_:runContextMenu:for:)`,
`page(_:handleChromeCommand:disposition:)`, `page(_:didFinishLoadWithStatus:)`.
Profile-wide: `CefProfileDelegate` (permissions, download destinations),
set with `profile.delegate = …` (also weak).

## Profiles, requests, schemes

```swift
let work = CefProfile.persistent(id: "work", displayName: "Work")
let privateProfile = CefProfile.incognito()
profile.downloadPolicy = .ask          // .downloadsFolder, .folder(url), .ask, .disabled
profile.requestFilter = CefRequestFilter(hosts: ["ads.example"]) { request in .block }
let cookies = try await profile.cookies(for: url)

CefRuntime.shared.registerSchemeHandler(
    scheme: "app", handler: CefDirectorySchemeHandler(directory: Bundle.main.resourceURL!.appending(path: "web")))
```

`CefSchemeHandler` for generated content:
`func response(for request: CefSchemeRequest) async -> CefSchemeResponse`.

## Windows

```swift
let page = CefPage(url: home)
let window = CefWindow(page: page)      // one Chrome-style page per window
window.setToolbar(principal: { Text(page.title) })
window.show()                           // starts hidden
```

`CefWindow.Configuration`: `toolbar` (`.none`, `.chrome`, `.location`),
`frame`, `tabbingIdentifier`, `isFrameless`. `window.setPageOverlay { … }`
draws over the page without taking events. `window.onPopup` receives popups.

## CefChromium: tabbed windows and Chromium's data

```swift
import CefChromium

let window = try await CefChromeWindow.open(url: URL(string: "https://swift.org")!)
window.showsChromeUI = false                    // cover Chrome's strip and toolbar
window.setTopBar { Text("My tab strip") }      // your SwiftUI over them; views that show tab state read it in their own body
let tab = try await window.openTab(URL(string: "https://developer.apple.com")!)
try await tab.select()
try await tab.pin()
let group = try await window.profile.tabs.group([tab])
try await group?.setTitle("Reading")
```

- `CefChromeWindow`: `tabs`, `groups`, `activeTab`, `profile`, `window`
  (the `NSWindow`), `topBarHeight`, `contentFrame`, `close()`,
  `setTopBar`, `setSidebar`, `setPageOverlay`, `setFindBar`,
  `setCustomPresentation(for:)`, `onClose`.
- `CefTab`: `title`, `url`, `favicon`, `isActive`, `isPinned`, `isAudible`,
  `isMuted`, `isLoading`, `isDiscarded`, `group`, `page`; `select()`,
  `close()`, `pin(_:)`, `move(to:in:)`, `duplicate()`,
  `moveToNewWindow()`, `setMuted(_:)`, `discard()`, `capturePreview()`.
- `profile.tabs` (`CefTabs`): `windows`, `onWindowOpened`, `layout =
  .vertical(width:)` (Chrome's vertical tabs, which `setSidebar` covers),
  `recentlyClosed`, `reopen(_:)`, `previousSession`,
  `restorePreviousSession()`, `observesChromiumEvents`.
- `profile.autocomplete.results(for:)`: an async throwing stream of
  results (`suggestions`, each with `text`, `detail`, `url`, `kind`,
  `inlineCompletion`); the latest query wins, so query on every keystroke.
- `profile.extensions`: `installed`, `refresh()`, `setEnabled(_:for:)`,
  `uninstall(_:)`, `loadUnpacked(at:)`, `changes`.

Signatures of the stores (all `async throws` unless marked):

```text
profile.bookmarks
  add(_ url: URL, title: String, in folder: CefBookmark.ID? = nil, at index: Int? = nil) -> CefBookmark
  tree() -> [CefBookmark]          recent(limit: Int = 10) -> [CefBookmark]
  search(_ query: String) -> [CefBookmark]    bookmarks(for url: URL) -> [CefBookmark]
  remove(_ id: CefBookmark.ID)     changes: AsyncStream<Void> (not async)
  CefBookmark: id, title, url: URL?
profile.history
  search(_ text: String = "", limit: Int = 100) -> [CefHistory.Entry]   (entry: url, title)
  entries(matching: String = "", pageSize: Int = 100) -> AsyncThrowingStream<[CefHistory.Entry], Error> (not async)
  topSites() -> [CefHistory.TopSite]
page.findSession (CefFindSession, @Observable; or the session setFindBar hands you)
  text: String (bind it: Bindable(session).text), next(), previous(), end(), matchCount
```

A find bar of your own in a `CefChromeWindow`:

```swift
import CefChromium
import SwiftUI

@MainActor
func addFindBar(to window: CefChromeWindow) {
    window.setFindBar { session in
        HStack {
            TextField("Find on Page", text: Bindable(session).text).onSubmit(session.next)
            Button("Previous", systemImage: "chevron.up", action: session.previous)
            Button("Next", systemImage: "chevron.down", action: session.next)
            Button("Done", action: session.end)
        }
        .padding(6)
    }
}
// ⌘F: window.activeTab?.page?.execute(.find) opens it.
```

## Passkeys

```swift
import CefPasskeys

let passkeys = CefPasskeyController(policy: .app(CefKeychainPasskeyStore()))
pageConfiguration.attachments.append(passkeys)
```

`.disabled` refuses every WebAuthn call. Without a controller Chromium
answers with its own dialog (security keys, phones).

## DevTools Protocol

```swift
try await page.devTools.send("Network.enable")
for await event in page.devTools.events("Network.responseReceived") {
    print(event["response"]["url"].stringValue ?? "")
}
```
