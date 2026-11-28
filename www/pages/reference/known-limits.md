---
title: "Known limits"
description: "What CEF, official CEF builds and CefSwift cannot do, and the workaround where there is one."
---

```swift
// Netflix-class streaming needs FairPlay: show it in WebKit beside Chromium.
// See Streaming and DRM.
let preset = CefRuntime.Configuration.chrome
print(preset.services.protectedMedia)
```

<!-- section docs/guide.md#known-limits -->
