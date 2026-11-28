---
title: "Popups and permission UI"
description: "Answer permission requests, dialogs, sign-in and certificate questions with your own UI; handle new windows and popups."
---

```swift
final class Policy: CefPageDelegate {
    func page(_ page: CefPage, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        await askUser(about: request.kinds, from: request.origin.absoluteString) ? .allow : .deny
    }
}
```

Gallery: [`PermissionsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/PermissionsDemo.swift), [`ContextMenuDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ContextMenuDemo.swift).
Browser example: [`Features/PageInfo`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/PageInfo) asks for camera, location and the like and shows site permissions.

<!-- section docs/guide.md#decisions body -->

<!-- section docs/guide.md#permissions -->

<!-- section docs/guide.md#site-settings -->

<!-- section docs/guide.md#built-in-sheets -->

<!-- section docs/guide.md#http-authentication -->

<!-- section docs/guide.md#client-certificates -->

<!-- section docs/guide.md#navigation-and-new-windows -->

<!-- section docs/guide.md#popups -->

<!-- section docs/guide.md#links-to-other-apps -->
