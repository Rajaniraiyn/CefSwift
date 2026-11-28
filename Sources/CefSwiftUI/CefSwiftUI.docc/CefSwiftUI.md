# ``CefSwiftUI``

Show Chromium pages in SwiftUI.

## Overview

CefSwiftUI is SwiftUI on top of CefKit, which it re-exports: an app type
that starts Chromium before SwiftUI does, a view that hosts a page, and
modifiers for Chrome-style windows.

```swift
import CefSwiftUI

@main
struct MyApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration { .embedded }

    var body: some Scene {
        WindowGroup { CefWebView(url: URL(string: "https://example.com")!) }
    }
}
```

A page is a `CefPage`, an `@Observable` model: keep it in your own state
and bind controls to its `url`, `title`, `isLoading` and
`estimatedProgress`, or let ``CefWebView/init(url:configuration:)`` own
one.

## Topics

### Essentials

- <doc:BuildABrowser>
- ``CefSwiftApp``
- ``CefWebView``

### Offscreen pages

- ``SwiftUI/View/offscreenResizePolicy(_:)``
- ``SwiftUI/View/offscreenFramePlacement(_:)``
- ``SwiftUI/View/offscreenPageSize(_:)``
