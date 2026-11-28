---
title: "Offscreen rendering and overlays"
description: "Pages drawn into your own layer, so SwiftUI content, effects and transforms go over and around them."
---

```swift
// With runtimeConfiguration.isOffscreenRenderingEnabled = true:
var pageConfiguration = CefPage.Configuration()
pageConfiguration.rendering = .offscreen(frameRate: 120)
let page = CefPage(url: url, configuration: pageConfiguration)
let card = CefWebView(page)
    .clipShape(.rect(cornerRadius: 16))
    .overlay(alignment: .bottomTrailing) { Button("Close") { page.close() }.padding() }
```

Gallery: [`OffscreenOverlayDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/OffscreenOverlayDemo.swift).

<!-- section docs/guide.md#offscreen-rendering -->
