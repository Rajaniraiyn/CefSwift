---
title: "Chromium's services over Mojo"
description: "How CefChromium reaches bookmarks, history, suggestions, tabs and discarding through Chromium's own WebUI handlers in hidden service hosts."
---

```swift
import CefChromium

// Starts the history host (about 0.1 s), which closes 30 s after its last call.
let topSites = try await profile.history.topSites()
print(topSites.count)
```

Gallery: [`HistoryDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/HistoryDemo.swift).

<!-- section docs/architecture.md#internal-page-services -->

<!-- section docs/design-notes.md#service-hosts-mojo-handlers-not-the-webui-apps -->

<!-- section docs/design-notes.md#chromiums-own-features-a-module-not-cefkit -->
