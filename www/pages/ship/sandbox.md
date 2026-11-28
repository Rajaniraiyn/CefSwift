---
title: "The App Sandbox"
description: "Why official CEF builds cannot run under the App Sandbox, and what confines the helpers instead."
---

```sh
# Both tracks refuse it; this reports whatever the bundle claims.
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef doctor dist/MyApp.app
```

Chromium's own sandbox still confines the helper processes:
[Multi-process sandboxing](/internals/sandboxing).

<!-- section docs/bundling.md#app-sandbox -->
