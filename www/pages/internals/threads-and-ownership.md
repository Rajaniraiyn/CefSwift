---
title: "Threads and object ownership"
description: "Which thread runs what, who owns each CEF object, and how pages and their clients fit together."
---

```swift
// Request filters run on Chromium's IO thread (CefIOActor): never block there.
profile.requestFilter = CefRequestFilter(hosts: ["example.com"]) { request in
    request.method == "POST" ? .block : .allow
}
```

<!-- section docs/architecture.md#object-ownership -->

<!-- section docs/architecture.md#threads -->

<!-- section docs/architecture.md#pages-and-clients body -->
