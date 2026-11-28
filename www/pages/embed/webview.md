---
title: "CefWebView and AppKit hosts"
description: "Show a page in SwiftUI or AppKit: the observable CefPage, loads, PDF, attachments, focus, tooltips and the context menu."
---

```swift
struct Reader: View {
    @State private var page = CefPage(url: URL(string: "https://swift.org")!)

    var body: some View {
        CefWebView(page)
            .navigationTitle(page.title)
            .toolbar {
                Button("Back", systemImage: "chevron.left", action: page.goBack)
                    .disabled(!page.canGoBack)
            }
    }
}
```

Gallery: [`ObservableStateDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ObservableStateDemo.swift), [`AppKitHostingDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/AppKitHostingDemo.swift), [`PDFDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/PDFDemo.swift), [`ContextMenuDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ContextMenuDemo.swift).

<!-- section docs/guide.md#pages -->

<!-- section docs/guide.md#in-appkit -->

<!-- section docs/guide.md#keyboard-focus -->

<!-- section docs/guide.md#tooltips -->

<!-- section docs/guide.md#context-menu -->
