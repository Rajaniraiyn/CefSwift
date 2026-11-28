---
title: "Bookmarks and history"
description: "Chromium's own bookmark, history and top-sites stores, read and changed from Swift."
---

```swift
import CefChromium

_ = try await profile.bookmarks.add(url, title: "Example")
let recent = try await profile.bookmarks.recent(limit: 12)
let visits = try await profile.history.search("swift", limit: 20)
let topSites = try await profile.history.topSites()
print(recent.count, visits.count, topSites.count)
```

Gallery: [`BookmarksDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/BookmarksDemo.swift), [`HistoryDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/HistoryDemo.swift).
Browser example: [`Features/Bookmarks`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/Bookmarks) adds the star and Bookmarks menu; `Features/History` the History menu; `Features/StartPage` a start page of top sites.

<!-- section docs/guide.md#bookmarks-history-and-suggestions -->
