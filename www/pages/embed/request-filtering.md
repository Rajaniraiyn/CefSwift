---
title: "Request filtering and the network"
description: "Block, redirect and rewrite requests on Chromium's IO thread, make requests through Chromium's network stack, and clear data."
---

```swift
profile.requestFilter = CefRequestFilter(
    hosts: ["ads.example", "tracker.example"], resourceTypes: [.script, .image, .fetch]
) { request in
    request.isThirdParty ? .block : .allow
}
```

Gallery: [`RequestsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/RequestsDemo.swift).

<!-- section docs/guide.md#request-filter -->

<!-- section docs/guide.md#requests-through-chromiums-network-stack -->

<!-- section docs/guide.md#network-maintenance -->

<!-- section docs/design-notes.md#request-filter-matching -->
