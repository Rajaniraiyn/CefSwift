---
title: "The Xcode and SwiftPM tracks"
description: "Build the app bundle with the cef command plugin (Command Line Tools only) or with Xcode's build phase: one tool, equal tracks."
---

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp
```

| Track | Needs | Build |
|---|---|---|
| SwiftPM package | The Command Line Tools | `swift build`, then `swift package cef bundle` |
| Hand-written SwiftUI app, plain SwiftPM | The Command Line Tools | Your own `@main CefSwiftApp` in `Sources/`, the same two commands |
| Xcode project | Xcode 16 or later | Xcode's build, with CefSwift's Run Script phase |

The Command Line Tools are enough for both SwiftPM tracks; Xcode is
needed only for an Xcode project.

<!-- section docs/bundling.md# -->

<!-- section docs/bundling.md#the-cef-command -->

<!-- section docs/bundling.md#xcode -->

<!-- section docs/bundling.md#settings -->

<!-- section docs/bundling.md#where-cef-comes-from -->

<!-- section docs/design-notes.md#building-with-swiftpm-and-with-xcode-one-tool-two-front-ends -->
