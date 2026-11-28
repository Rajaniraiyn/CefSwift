---
title: "Install"
description: "Add CefSwift to a SwiftPM package or an Xcode project and bundle your first app."
---

An app that embeds Chromium is an app bundle with Chromium's framework and
five helper apps inside. Both tracks run the same `cefswift` tool to add
them, sign them and check the result, so the bundles are the same.

```swift
import CefSwiftUI
import SwiftUI

@main
struct MyApp: CefSwiftApp {
    var body: some Scene {
        WindowGroup { CefWebView(url: URL(string: "https://example.com")!) }
    }
}
```

Gallery: [`ObservableStateDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ObservableStateDemo.swift). The smallest complete app is the
[Minimal example](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Minimal).

## With SwiftPM

1. Depend on CefSwift in `Package.swift`:

   ```swift
   // swift-tools-version: 6.0
   import PackageDescription

   let package = Package(
       name: "MyApp",
       platforms: [.macOS(.v14)],
       dependencies: [
           .package(url: "https://github.com/Rajaniraiyn/CefSwift", .upToNextMinor(from: "0.2.0")),
       ],
       targets: [
           .executableTarget(name: "MyApp", dependencies: [
               .product(name: "CefSwiftUI", package: "CefSwift"),
           ]),
       ]
   )
   ```

2. Put the app above in `Sources/MyApp/MyApp.swift`.
3. Bundle and open it with the package's `cef` command plugin:

   ```sh
   swift package --allow-writing-to-package-directory --allow-network-connections all \
       cef bundle --product MyApp
   open dist/MyApp.app
   ```

The first run downloads the pinned CEF build (about 135 MB) into `.cef/`.
Add `.cef/` and `dist/` to `.gitignore`. `swift run` cannot start
Chromium, which runs only from the bundle. Settings go in a `cefapp.json`
beside the sources ([Bundling](/ship/bundling)).

## With Xcode

1. In an app project (File › New › Project › macOS › App, SwiftUI), add the
   package: File › Add Package Dependencies…, enter
   `https://github.com/Rajaniraiyn/CefSwift`, and add `CefSwiftUI` to the
   app target.
2. In the target's Signing & Capabilities, remove App Sandbox. Official CEF
   builds do not run under it, and the build phase stops with an error if
   it is on ([why](/ship/sandbox)).
3. Copy [`Examples/Xcode/CefSwift.xcconfig`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Xcode/CefSwift.xcconfig)
   into the project and choose it as the target's configuration file
   (Project › Info › Configurations). For a local package, set its
   `CEFSWIFT_PACKAGE_DIR` to the package's path.
4. In Build Phases, add a Run Script phase at the end, turn off "Based on
   dependency analysis", and run:

   ```sh
   "$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh"
   ```

5. Write the app, then Run.

The first build downloads CEF into `.cef/` beside the project.
[The Xcode and SwiftPM tracks](/ship/tracks) covers both in full.

## Requirements

- macOS 14 or later (the examples need macOS 15), Apple silicon or Intel.
- A Swift 6 toolchain. An Xcode project needs Xcode 16 or later.
