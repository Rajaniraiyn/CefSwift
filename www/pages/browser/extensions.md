---
title: "Extensions"
description: "Chrome's extension system: the Web Store, the profile's extensions, extensions the app ships, and their toolbar actions."
---

```swift
import CefChromium

for item in try await profile.extensions.refresh() {
    print(item.name, item.version, item.isEnabled)
}
```

Gallery: [`ExtensionsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ExtensionsDemo.swift).
Browser example: [`Features/Extensions`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/Extensions) shows pinned actions, their popups and a Manage Extensions window.

<!-- section docs/guide.md#extensions -->

<!-- section docs/design-notes.md#extensions-chromiums-own-through-chromeextensions -->

<!-- section docs/architecture.md#extensions -->
