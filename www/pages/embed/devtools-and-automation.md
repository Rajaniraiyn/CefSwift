---
title: "DevTools and automation"
description: "The DevTools window, the DevTools Protocol in-process, and what a page can tell about CefSwift."
---

```swift
try await page.devTools.send("Emulation.setDeviceMetricsOverride",
    ["width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true])
page.showDevTools()
```

Gallery: [`DevToolsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/DevToolsDemo.swift).

<!-- section docs/guide.md#devtools -->

<!-- section docs/guide.md#compatibility-with-bot-protection -->
