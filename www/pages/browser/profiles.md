---
title: "Profiles and private windows"
description: "Default, persistent and incognito profiles: what each keeps, how they load, and private windows."
---

```swift
import CefChromium

let work = CefProfile.persistent(id: "work", displayName: "Work")
_ = try await CefChromeWindow.open(url: url, profile: work)
_ = try await CefChromeWindow.open(url: url, profile: .incognito())   // a private window
```

Google sign-in works in a profile like any site's (verified by hand).
Gallery: [`ProfilesDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/ProfilesDemo.swift).
Browser example: [`Features/PrivateTabs`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/PrivateTabs) opens private windows on the incognito profile.

<!-- section docs/guide.md#profiles body -->

<!-- section docs/guide.md#what-is-configured-where -->

<!-- section docs/guide.md#profile-settings -->

<!-- section docs/guide.md#loading-a-persistent-profile -->

<!-- section docs/architecture.md#profile-policy -->

<!-- section docs/architecture.md#profiles-and-their-request-contexts -->

<!-- section docs/design-notes.md#persistent-profiles-directly-in-the-root-and-loaded-before-use -->
