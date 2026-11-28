# Gallery demos

Each demo is one file of SwiftUI and CefSwift code you can copy:
`Examples/Sources/Gallery/Demos/<Name>.swift` in the CefSwift repository
(https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Gallery/Demos).
Pages come from a `gallery://` scheme handler or a server on `localhost`
(`Examples/Sources/Gallery/Support/`), so every demo works offline.

Run one:

```sh
swift package --package-path Examples --allow-writing-to-package-directory \
    --allow-network-connections all cef bundle --product Gallery
Examples/dist/Gallery.app/Contents/MacOS/Gallery -demo BridgeDemo
```

`-smoke` opens every demo in turn and exits with the number of failures.

| Want to | Demo |
|---|---|
| Bind a toolbar to page state; await a load | `ObservableStateDemo` |
| Offscreen page with SwiftUI over it | `OffscreenOverlayDemo` |
| Pages under spring resizes, transforms, matched geometry | `AnimationDemo` |
| Swipe back and forward with your own indicator | `SwipeNavigationDemo` |
| AppKit host view without CefSwiftUI | `AppKitHostingDemo` |
| Find in page | `FindInPageDemo` |
| Custom context menu | `ContextMenuDemo` |
| PDF and printing | `PDFDemo` |
| DevTools window and the DevTools Protocol | `DevToolsDemo` |
| Run JavaScript from Swift | `EvaluateJavaScriptDemo` |
| Typed JavaScript bridge both ways | `BridgeDemo` |
| User scripts and style sheets | `UserScriptsDemo` |
| Frames and per-frame evaluation | `FramesDemo` |
| Serve app resources from a custom scheme | `CustomSchemeDemo` |
| Requests through Chromium's network stack | `RequestsDemo` |
| Persistent and incognito profiles, cookies | `ProfilesDemo` |
| Permission prompts and site settings | `PermissionsDemo` |
| Downloads | `DownloadsDemo` |
| A `CefWindow` with a SwiftUI toolbar | `ChromeWindowDemo` |
| Replace Chromium's find bar, status bubble, QR bubble | `ChromiumSurfacesDemo` |
| Chromium's own tabs driven from SwiftUI | `TabStripDemo` |
| An app whose sections are Chromium tabs, no tab UI | `AppShellDemo` |
| Chromium's process list | `TaskManagerDemo` |
| Discard and restore a page | `DiscardDemo` |
| Cast and DIAL devices | `MediaRouterDemo` |
| Bookmarks, live | `BookmarksDemo` |
| History search | `HistoryDemo` |
| Address-bar suggestions | `SuggestionsDemo` |
| Extensions: list, toggle, load unpacked | `ExtensionsDemo` |
| Passkeys answered by the app | `PasskeysDemo` |

The Browser example (`Examples/Sources/Browser`) combines most of these
into a tabbed browser; see the `build-a-browser` skill.
