---
title: "Tabs and the tab strip"
description: "Chromium's own tabbed windows, tabs and groups under a tab strip you draw in SwiftUI."
---

```swift
import CefChromium

let window = try await CefChromeWindow.open(url: URL(string: "https://swift.org")!)
window.showsChromeUI = false
let tab = try await window.openTab(URL(string: "https://developer.apple.com")!)
try await tab.pin()
let group = try await window.profile.tabs.group([tab])
try await group?.setTitle("Reading")
```

Gallery: [`TabStripDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/TabStripDemo.swift), [`AppShellDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/AppShellDemo.swift).
Browser example: [`Core/TabRail`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Core/TabRail) is a complete tab rail: pinned tabs, groups, dragging, overflow, keyboard and VoiceOver.

<!-- section docs/guide.md#chromiums-tabs-windows-tabs-and-groups -->

<!-- section docs/guide.md#tabs -->

<!-- section docs/guide.md#tabs-chromium-opens-itself -->

<!-- section docs/guide.md#chrome-commands -->

<!-- section docs/design-notes.md#tabs-chromiums-tab-strip-under-the-apps-own -->
