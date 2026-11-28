---
title: "Animation"
description: "Pages under SwiftUI springs, transforms, matched geometry and transitions, in both renderings."
---

```swift
struct Card: View {
    let page: CefPage
    @State private var isExpanded = false

    var body: some View {
        CefWebView(page)
            .frame(width: isExpanded ? 900 : 320, height: isExpanded ? 600 : 220)
            .clipShape(.rect(cornerRadius: isExpanded ? 0 : 16))
            .onTapGesture { withAnimation(.spring) { isExpanded.toggle() } }
    }
}
```

Gallery: [`AnimationDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/AnimationDemo.swift).

<!-- section docs/guide.md#animating-a-page -->

<!-- section docs/architecture.md#animating-pages -->
