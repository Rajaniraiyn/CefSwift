---
title: "Offscreen frames"
description: "Offscreen frames copied only where they changed, and what that costs."
---

```swift
var pageConfiguration = CefPage.Configuration()
pageConfiguration.rendering = .offscreen(frameRate: 60)
```

Gallery: [`OffscreenOverlayDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/OffscreenOverlayDemo.swift).

<!-- section docs/design-notes.md#offscreen-frames-copied-and-only-where-they-changed -->
