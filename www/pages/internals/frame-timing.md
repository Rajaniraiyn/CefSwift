---
title: "Frame timing and IOSurface"
description: "How offscreen frames arrive, who owns their IOSurface, and when they reach the screen."
---

```swift
page.offscreenFrameRate = 30   // 1 to 240; Low Power Mode can lower it
page.setNeedsDisplay()         // repaint the whole view with the next frame
```

Gallery: [`OffscreenOverlayDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/OffscreenOverlayDemo.swift), [`AnimationDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/AnimationDemo.swift).

<!-- section docs/architecture.md#frame-timing -->

<!-- section docs/architecture.md#frame-ownership -->
