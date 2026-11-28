---
title: "Streaming and DRM"
description: "Widevine in Chromium, FairPlay in WebKit tabs beside it, and which streaming services play where."
---

```swift
var configuration = CefRuntime.Configuration.chrome
configuration.services.protectedMedia = .automatic   // Chromium fetches Widevine (L3)
```

Netflix-class services need FairPlay, H.264 or AAC, which Chromium in
CefSwift does not have. Show them in a `WKWebView` tab, as the Browser
example does. Browser example: [`Features/WebKitTabs`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/WebKitTabs) opens streaming sites in WebKit windows (FairPlay), on `Sources/SystemEngine`.
There is no Gallery demo; the Browser's `browser://playground/` has Widevine
and FairPlay test streams.

<!-- section docs/guide.md#playing-streaming-services -->
