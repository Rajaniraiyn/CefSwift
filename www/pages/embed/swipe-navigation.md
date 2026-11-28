---
title: "Swipe navigation"
description: "Two-finger swipes back and forward, your own indicator, and the back/forward list."
---

```swift
var pageConfiguration = CefPage.Configuration()
pageConfiguration.allowsBackForwardNavigationGestures = true
let page = CefPage(url: url, configuration: pageConfiguration)
// page.navigationGestureProgress runs from 0 toward -1 (back) or 1 (forward).
```

Gallery: [`SwipeNavigationDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/SwipeNavigationDemo.swift).
Browser example: [`Features/SwipeIndicator`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/SwipeIndicator) draws the browser's own indicator.

<!-- section docs/guide.md#swipe-navigation -->

<!-- section docs/guide.md#back-and-forward -->
