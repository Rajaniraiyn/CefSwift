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
options.allowsBackForwardNavigationGestures = true   // swipe to navigate (offscreen)
options.userScripts = [CefUserScript(source: "window.appVersion = '1.2'")]
options.requestFilter = { $0.url?.host() == "ads.example" ? .block : .allow }
let browser = CefBrowser(url: url, options: options)
```

Offscreen rendering needs `configuration.windowlessRenderingEnabled = true`.

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
    func browser(_ browser: CefBrowser, decidePermission request: CefPermissionRequest) async -> CefPermissionDecision {
        await askUser(request) ? .allow : .deny
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        openTab(request.targetURL)
        return .handled
    }

    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJSDialog) async -> CefJSDialogResponse {
        dialog.kind == .alert ? .accept() : await CefDialogPresenter.present(dialog, in: browser.hostWindow)
    }
}
```

## Context menu

```swift
options.contextMenu.hiddenCommands = [.viewSource, .print]
options.contextMenu.showsInspectElement = true
options.contextMenu.items = [
    CefContextMenuItem("Search Notes", isVisible: { !$0.selectionText.isEmpty }) { _, target in
        search(target.selectionText)
    },
]
```

`options.contextMenu.isEnabled = false` removes the menu. For menus that
depend on app state, implement `browser(_:configureContextMenu:params:)`.

## Building a browser

```swift
let browser = CefBrowser(url: home, delegate: policy)
let window = CefBrowserWindow(browser: browser)
window.setToolbar { AddressBar(browser: browser) }   // SwiftUI, in the title bar
window.show()
```

- Give windows the same `configuration.tabbingIdentifier` and macOS groups
  them as native tabs.
- `browser.execute(.find)`, `.print`, `.createQRCode`, `.showHistory`, … run
  Chrome's own commands; `browser(_:handleChromeCommand:disposition:)`
  intercepts them.
- `CefConfiguration.chromeUI` hides Chrome app-menu entries, toolbar buttons
  and page-action icons.
- `CefRuntime.shared.openChromeWindow(url:)` opens a window drawn entirely by
  Chrome, tab strip included. Browsers Chromium creates by itself (tabs,
  popups) are reported through `CefRuntime.shared.onBrowserCreated`.

## Profiles

```swift
let profile = CefProfile.persistent(name: "Work")
try profile.setPreference("credentials_enable_service", to: false)
profile.setColorScheme(.dark, accentColor: .systemIndigo)
let cookies = await profile.cookies(for: url)
```

Preferences are the settings behind `chrome://settings`; browse them with
`profile.allPreferences()`.

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
    scheme: "app", handler: CefBundleSchemeHandler(directory: webRoot))
// load app://local/index.html
```

## Known limits

- Chrome style (the `chrome://` pages, extensions) is only available in
  `CefBrowserWindow` and Chrome UI windows — a Chromium constraint on macOS.
  Views embedded with `CefWebView` use the lighter Alloy style.
- One Chrome-style browser per window; use native window tabs for tabbed UIs.
- Offscreen pages are exposed to VoiceOver as a single element.
- CEF does not expose Chromium's history, bookmarks or omnibox ranking to
  embedders; keep those in your app.
