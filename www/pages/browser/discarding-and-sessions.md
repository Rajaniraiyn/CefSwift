---
title: "Tab discarding and sessions"
description: "Put background tabs to sleep, follow page lifecycle and energy, and restore windows after a quit or a crash."
---

```swift
import CefChromium

let strip = CefProfile.default.tabs
if let session = strip.previousSession, case .clean = session.exit {
    try await strip.restorePreviousSession()
}
try await page.discard()   // frees the renderer; the page reloads when shown
```

Gallery: [`DiscardDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/DiscardDemo.swift).
Browser example: [`Features/TabDiscarding`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/TabDiscarding) is Memory Saver: tabs sleep after a while or under memory pressure.

<!-- section docs/guide.md#discarding-pages -->

<!-- section docs/guide.md#lifecycle-and-energy -->

<!-- section docs/guide.md#restoring-tabs-and-sessions -->

<!-- section docs/architecture.md#discarding -->

<!-- section docs/architecture.md#lifecycle -->

<!-- section docs/design-notes.md#tab-discarding-the-capability-not-a-policy -->
