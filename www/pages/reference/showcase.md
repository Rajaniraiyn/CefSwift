---
title: "Built with CefSwift"
description: "Apps built on CefSwift."
---

```sh
swift package --package-path Examples --allow-writing-to-package-directory \
    --allow-network-connections all cef bundle --product Browser
open Examples/dist/Browser.app
```

![The Browser example: a tab rail and toolbar over Chromium's tabs](/images/browser.png)

- **[CefSwift Browser](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser)**: the example browser in this
  repository. A core and a folder per feature: Chromium's tabbed windows
  under a SwiftUI tab rail, address suggestions, bookmarks, history,
  extensions, Memory Saver, passkeys and WebKit tabs for streaming.

Built something with CefSwift? Open a pull request that adds it to
[`www/pages/reference/showcase.md`](https://github.com/Rajaniraiyn/CefSwift/blob/main/www/pages/reference/showcase.md).
