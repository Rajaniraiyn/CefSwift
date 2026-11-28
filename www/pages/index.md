---
title: "CefSwift"
description: "Build a Chromium browser, or embed Chromium, in a Mac app written in Swift and SwiftUI, on the official prebuilt CEF."
---

CefSwift embeds Chromium in macOS apps written in Swift, through the
official prebuilt [Chromium Embedded Framework](https://github.com/chromiumembedded/cef)
(CEF). You get Chromium's pages, tabs, profiles, extensions, bookmarks and
history as Swift types, without a Chromium checkout or a fork to rebase.

```swift
import CefSwiftUI
import SwiftUI

@main
struct MyApp: CefSwiftApp {
    var body: some Scene {
        WindowGroup {
            CefWebView(url: URL(string: "https://example.com")!)
        }
    }
}
```

Bundle it with `swift package cef bundle --product MyApp` and open
`dist/MyApp.app` ([Install](/start/install)). Gallery: [`ObservableStateDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ObservableStateDemo.swift).

## Where to go next

- [Your first browser in 10 minutes](/start/first-browser): a tabbed browser
  with your own SwiftUI tab strip over Chromium's tabs.
- [Choosing a host](/start/choosing-a-host): `CefWebView`, `CefWindow` or
  `CefChromeWindow`.
- [Build with an agent](/start/agents): skills, `AGENTS.md` and `llms.txt`.
- [Known limits](/reference/known-limits) before you commit to it.

## Pre-1.0

CefSwift uses the official prebuilt CEF at the version `CEF_VERSION.json`
pins; custom CEF builds are not supported. Its API can change between
minor releases, so depend on one minor version
(`.upToNextMinor(from: "0.2.0")`).

<!-- section docs/guide.md# -->

<!-- section docs/architecture.md# -->

<!-- section docs/architecture.md#modules -->
