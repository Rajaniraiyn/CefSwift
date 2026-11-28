---
title: "Notarization and distribution"
description: "Local, development and Developer ID builds, notarized and stapled, with SwiftPM or Xcode."
---

```sh
xcrun notarytool store-credentials notary
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp --sign "Developer ID Application: Example Corp (A1B2C3D4E5)" \
    --notarize --keychain-profile notary
```

<!-- section docs/bundling.md#distribution -->
