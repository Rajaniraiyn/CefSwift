---
title: "Find bar and Chromium's bubbles"
description: "Replace Chromium's find bar, status bubble, QR code and other bubbles with SwiftUI, or anchor them under your controls."
---

```swift
import CefChromium
import SwiftUI

func addFindBar(to window: CefChromeWindow) {
    window.setFindBar { session in
        TextField("Find on Page", text: Bindable(session).text)
            .onSubmit(session.next)
            .padding(6)
    }
}
```

Gallery: [`FindInPageDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/FindInPageDemo.swift), [`ChromiumSurfacesDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ChromiumSurfacesDemo.swift).
Browser example: [`Features/FindBar`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/FindBar) is a whole find-bar feature; `Features/StatusBubble` and `Features/ChromiumPanels` replace the others.

<!-- section docs/guide.md#chromiums-own-interface -->
