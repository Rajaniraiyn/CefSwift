---
title: "Layering SwiftUI over and under pages"
description: "The page's canvas, title bars in web content, Chromium's AppKit classes and what Chromium draws over a Chrome-style window."
---

```swift
window.setPageOverlay {
    ZStack {
        LinkStatus(page: window.page)   // over the page, never taking its clicks
        MyIndicator(page: window.page)
    }
}
```

Gallery: [`ChromiumSurfacesDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ChromiumSurfacesDemo.swift), [`OffscreenOverlayDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/OffscreenOverlayDemo.swift).

<!-- section docs/guide.md#background -->

<!-- section docs/guide.md#title-bars-in-web-content -->

<!-- section docs/architecture.md#chromiums-appkit-classes -->

<!-- section docs/design-notes.md#what-chromium-shows-over-a-chrome-style-window -->

<!-- section docs/design-notes.md#chrome-style-and-a-dark-pages-canvas -->
