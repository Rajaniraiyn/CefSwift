---
title: "Multi-process sandboxing"
description: "Chromium's macOS sandbox for the helper processes: how it is sealed, what it needs, and running without it."
---

```swift
var configuration = CefRuntime.Configuration.embedded
configuration.isSandboxEnabled = true   // the default
```

The Minimal example runs its helpers outside the sandbox with `-sandbox NO`,
for comparison.

<!-- section docs/sandbox.md# -->

<!-- section docs/sandbox.md#evidence -->

<!-- section docs/sandbox.md#how-it-works -->

<!-- section docs/sandbox.md#requirements -->

<!-- section docs/sandbox.md#without-the-sandbox -->

<!-- section docs/design-notes.md#sandbox -->
