# Examples

Three apps built on CefSwift. Bundle and run one from the repository root:

```sh
swift package --package-path Examples \
    --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product Browser --output dist
open Examples/dist/Browser.app
```

| App | Shows |
|---|---|
| **Browser** | A tabbed browser: Chrome-style `CefBrowserWindow`s grouped as native tabs, a three-part SwiftUI toolbar and tab icons, the page as an inset card, popups as panels over their opener, private tabs, downloads, a customized context menu, restyled settings and an About page of its own in place of Chromium's, and windows Chromium opens itself reopened as tabs. |
| **Showcase** | Embedding in SwiftUI with the lean `.embedded` configuration: observable browser state, native UI over an offscreen page with a swipe-to-navigate indicator, the JavaScript bridge, content from a custom scheme. Launch with `-demo "JavaScript Bridge"` to open a specific demo. |
| **SelfTest** | End-to-end checks against the real Chromium runtime. Prints one line per check and exits with the number of failures; CI runs it. |
