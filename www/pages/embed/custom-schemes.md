---
title: "Custom schemes and protocols"
description: "Serve your app's own content from a scheme of your own, from files or generated, streamed or large."
---

```swift
@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        configuration.customSchemes = [CefCustomScheme(name: "app")]
        return configuration
    }

    init() {
        let webRoot = Bundle.main.resourceURL!.appending(path: "web")
        CefRuntime.shared.registerSchemeHandler(scheme: "app", handler: CefDirectorySchemeHandler(directory: webRoot))
    }

    var body: some Scene {
        WindowGroup { CefWebView(url: URL(string: "app://local/index.html")!) }
    }
}
```

Gallery: [`CustomSchemeDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/CustomSchemeDemo.swift).

<!-- section docs/guide.md#serving-your-own-content -->
