---
title: "Process model and helpers"
description: "Chromium's processes, the five helper apps, loading the framework, unresponsive pages, quitting and relaunching."
---

```swift
var configuration = CefRuntime.Configuration.embedded
configuration.processPolicy = .minimal   // .automatic, .onDemand or .minimal
```

Gallery: [`TaskManagerDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/TaskManagerDemo.swift).

<!-- section docs/guide.md#processes -->

<!-- section docs/architecture.md#processes -->

<!-- section docs/architecture.md#quitting -->

<!-- section docs/guide.md#relaunching -->

<!-- section docs/architecture.md#relaunching -->
