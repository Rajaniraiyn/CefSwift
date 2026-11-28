---
title: "Passkeys"
description: "WebAuthn answered by Chromium, by your app from its own store, or refused."
---

```swift
import CefPasskeys

let passkeys = CefPasskeyController(policy: .app(CefKeychainPasskeyStore()))
var pageConfiguration = CefPage.Configuration()
pageConfiguration.attachments.append(passkeys)
```

Gallery: [`PasskeysDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/PasskeysDemo.swift).
Browser example: [`Features/Passkeys`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/Passkeys) answers passkeys with Chromium or itself, and lists saved ones in Settings.

<!-- section docs/guide.md#passkeys -->

<!-- section docs/architecture.md#passkeys -->

<!-- section docs/design-notes.md#passkeys-a-module-on-an-attachment-not-a-cefkit-option -->
