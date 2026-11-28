---
title: "Configuration, flags and features"
description: "Starting Chromium: presets, Chromium feature and switch overrides, preferences, languages, services, privacy and policies."
---

```swift
var configuration = CefRuntime.Configuration.chrome
configuration.disabledFeatures.formUnion(["WebUIOmniboxPopup"])
configuration.extraCommandLineSwitches = ["proxy-server": "socks5://localhost:1080"]
configuration.preferences["browser.confirm_to_quit"] = false
```

<!-- section docs/guide.md#starting-chromium -->

<!-- section docs/guide.md#configuration -->

<!-- section docs/guide.md#languages -->

<!-- section docs/guide.md#services-and-privacy -->

<!-- section docs/guide.md#preferences -->

<!-- section docs/guide.md#enterprise-policies -->
