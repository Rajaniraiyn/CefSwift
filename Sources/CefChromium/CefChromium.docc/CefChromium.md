# ``CefChromium``

Chromium's own browser features: bookmarks, history, suggestions,
extensions, tabbed windows and their bubbles.

## Overview

CEF has no API for these, but Chromium's own pages reach them. CefChromium
calls those services from hidden pages and wraps them as profile stores
and window state, so a browser built on CefKit can use Chromium's
bookmarks, history, omnibox suggestions and extensions instead of keeping
its own.

```swift
import CefChromium

let profile = CefProfile.default
let recent = try await profile.history.search("swift", limit: 20)
for try await result in profile.autocomplete.results(for: "swi") {
    print(result.suggestions.map(\.text))
}
```

CefChromium is bound to the pinned CEF: it depends on Chromium-internal
pages and AppKit classes, which a CEF update can change. SelfTest's
checks fail when one does.

## Topics

### Bookmarks, history and suggestions

- ``CefBookmarks``
- ``CefBookmark``
- ``CefHistory``
- ``CefAutocomplete``

### Chromium's tabbed windows

- ``CefChromeWindow``
- ``CefTabs``
- ``CefTab``
- ``CefTabGroup``

### Chromium's bubbles and dialogs

- ``CefChromiumSurface``

### Extensions

- ``CefExtensions``
- ``CefExtension``
