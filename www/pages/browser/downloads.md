---
title: "Downloads"
description: "Where downloads go, deciding per download, and the observable download list; file choosers."
---

```swift
profile.downloadPolicy = .ask   // .downloadsFolder (the default), .folder(url), .ask, .disabled
for download in profile.downloads {
    print(download.suggestedFilename, download.fractionCompleted)
}
```

Gallery: [`DownloadsDemo`](https://github.com/Rajaniraiyn/CefSwift/blob/main/Examples/Sources/Gallery/Demos/DownloadsDemo.swift).
Browser example: [`Features/Downloads`](https://github.com/Rajaniraiyn/CefSwift/tree/main/Examples/Sources/Browser/Features/Downloads) lists downloads from a toolbar button.

<!-- section docs/guide.md#downloads -->

<!-- section docs/guide.md#file-choosers -->
