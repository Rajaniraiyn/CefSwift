---
title: "Customizing chrome:// pages"
description: "Rename, restyle and replace Chromium's internal pages such as chrome://settings."
---

```swift
configuration.productName = "Orbit"
configuration.stringOverrides[.companyName] = "Orbit Software"
pageConfiguration.userScripts = [
    .styleSheet("#about-menu { display: none !important }", matching: ["chrome://settings/*"]),
]
```

Gallery: [`ChromeWindowDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ChromeWindowDemo.swift).
Browser example: [`Features/ChromiumPages`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/ChromiumPages) trims `chrome://settings` and adds its own About page.

<!-- section docs/guide.md#customizing-chromiums-own-pages -->
