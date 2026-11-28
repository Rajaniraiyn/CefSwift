---
title: "Where bookmarks, history and settings live"
description: "Chromium's data directory, each profile's files, and the settings, task and certificate stores."
---

```swift
print(CefProfile.default.storageDirectory?.path ?? "not loaded")
// ~/Library/Application Support/<bundle ID>/CefSwift/Default
```

<!-- section docs/architecture.md#data-paths -->

<!-- section docs/architecture.md#settings-tasks-and-certificates -->
