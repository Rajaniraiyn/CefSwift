---
title: "Address bar and suggestions"
description: "Chrome's ranked address-bar suggestions for your own field, and the connection security the field shows."
---

```swift
import CefChromium

for try await result in profile.autocomplete.results(for: "swift") {
    print(result.suggestions.map(\.text), result.isComplete)
}
```

Gallery: [`SuggestionsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/SuggestionsDemo.swift).
Browser example: [`Features/AddressBar`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/AddressBar) is a full address field: inline completion, ↑ ↓ selection, Return and Esc.

Suggestions come from `profile.autocomplete`, which
[Bookmarks and history](/browser/bookmarks-history#bookmarks-history-and-suggestions)
documents with the stores it ranks from. The field's security badge and
page info come from the page's connection security, below.

<!-- section docs/guide.md#connection-security -->
