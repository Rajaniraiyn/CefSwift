---
title: "The JavaScript bridge"
description: "Evaluate scripts, call typed Swift functions from the page, send events back, and add user scripts and style sheets."
---

```swift
struct Person: Codable { var name: String }

let bridge = CefBridge(name: "app")
bridge.handle("greet") { (person: Person) in "Hello, \(person.name)!" }
var pageConfiguration = CefPage.Configuration()
pageConfiguration.bridges = [bridge]
let page = CefPage(url: url, configuration: pageConfiguration)
let count = try await page.evaluateJavaScript("document.links.length").intValue
```

In the page: `const reply = await app.greet({ name: "Ada" })`.
Gallery: [`BridgeDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/BridgeDemo.swift), [`EvaluateJavaScriptDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/EvaluateJavaScriptDemo.swift), [`UserScriptsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/UserScriptsDemo.swift), [`FramesDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/FramesDemo.swift).

<!-- section docs/guide.md#javascript -->

<!-- section docs/architecture.md#page-facing-features -->

<!-- section docs/design-notes.md#bridge-and-evaluation-transport -->
