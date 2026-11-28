---
title: "Choosing a host"
description: "CefWebView, the AppKit views, CefWindow, CefChromeWindow or Chrome's own window: which host shows your pages, and what each gives you."
---

```swift
// One Chrome-style page in a window of its own, with a SwiftUI toolbar.
let page = CefPage(url: URL(string: "https://swift.org")!)
let window = CefWindow(page: page)
window.setToolbar(principal: { Text(page.title) })
window.show()
```

Gallery: [`ChromeWindowDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ChromeWindowDemo.swift), [`AppShellDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/AppShellDemo.swift), [`TabStripDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/TabStripDemo.swift).

| You want | Configuration | Host |
|---|---|---|
| Your own or trusted content inside your views | `.embedded` | `CefWebView`, or `CefWindowedPageView` and `CefOffscreenPageView` in AppKit |
| One page in a window, Chrome's pages and extensions working | `.chrome` | `CefWindow` |
| Several tabs Chromium knows, with your own tab interface | `.chrome` | `CefChromeWindow` (CefChromium) with `showsChromeUI = false` and a `topBar` |
| Chrome's complete UI | `.chrome` | `CefRuntime.shared.openChromeWindow(url:)` |
| Pages without a window: rendering, automation | `.embedded` + offscreen | `CefWebView` offscreen |

| | Your own or trusted content | Arbitrary sites, with Chrome's services |
|---|---|---|
| `chrome://` pages, extensions, history | No | Yes |
| Background services | Off | On |

<!-- section docs/guide.md#showing-a-page body -->

<!-- section docs/guide.md#chrome-style-windows -->

<!-- section docs/guide.md#toolbar-and-window -->

<!-- section docs/architecture.md#hosting -->
