---
title: "Accessibility"
description: "VoiceOver, Voice Control and UI tests reading offscreen pages as they read windowed ones."
---

```swift
var pageConfiguration = CefPage.Configuration()
pageConfiguration.rendering = .offscreen
pageConfiguration.offscreenAccessibility = .automatic   // built when something reads it
```

Gallery: [`OffscreenOverlayDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/OffscreenOverlayDemo.swift). SelfTest's `accessibility` group checks the tree.

<!-- section docs/guide.md#offscreen-accessibility -->

<!-- section docs/architecture.md#offscreen-accessibility -->

<!-- section docs/design-notes.md#offscreen-accessibility-updates -->
