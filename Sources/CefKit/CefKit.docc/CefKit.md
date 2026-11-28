# ``CefKit``

Embed Chromium in a Mac app through the official prebuilt CEF.

## Overview

CefKit wraps CEF's C API, and the Chromium behavior an embedder has to work
with or around, in Swift: the runtime, pages and profiles, the AppKit views
that host a page, Chrome-style windows, the delegate that answers a page's
questions, and offscreen rendering with its accessibility. It needs no
SwiftUI; ``CefSwiftUI`` builds on it.

```swift
import CefKit

try CefRuntime.shared.initialize(configuration: .chrome)
let page = CefPage(url: URL(string: "https://example.com")!)
let view = CefWindowedPageView(page: page)
```

The API is `@MainActor`: Chromium's UI thread is the app's main
thread. The few callbacks Chromium makes on other threads (a request
filter, a scheme handler) say so in their types (``CefIOActor``,
``CefFileActor``).

The guide (`docs/guide.md` in the repository) explains each feature at
length, and `docs/architecture.md` how they work. CefSwiftUI's "Build a
browser" article puts the pieces together.

## Topics

### Essentials

- ``CefRuntime``
- ``CefApplication``
- ``CefPage``
- ``CefProfile``
- ``CefError``

### Showing a page

- ``CefWindowedPageView``
- ``CefOffscreenPageView``
- ``CefWindow``
- ``CefOffscreenHost``
- ``CefOffscreenViewInfo``
- ``CefOffscreenFrame``

### Loading and navigation

- ``CefNavigation``
- ``CefLoadResult``
- ``CefLoadError``
- ``CefNavigationAction``
- ``CefNavigationDecision``
- ``CefNavigationTransition``
- ``CefWindowOpenRequest``
- ``CefWindowOpenDecision``
- ``CefWindowOpenDisposition``
- ``CefPopupFeatures``

### Answering a page

- ``CefPageDelegate``
- ``CefProfileDelegate``
- ``CefPermissionRequest``
- ``CefPermissionDecision``
- ``CefJavaScriptDialog``
- ``CefJavaScriptDialogResponse``
- ``CefFileDialog``
- ``CefAuthenticationChallenge``
- ``CefCredential``
- ``CefExternalProtocolRequest``
- ``CefExternalProtocolDecision``
- ``CefUnresponsivePageDecision``
- ``CefTerminationReason``
- ``CefConsoleMessage``

### Built-in sheets

- ``CefDialogPresenter``
- ``CefFileDialogPresenter``
- ``CefExternalProtocolPresenter``
- ``CefUnresponsivePagePresenter``
- ``CefClientCertificatePresenter``
- ``CefDownloadPresenter``
- ``CefContextMenuPresenter``

### JavaScript

- ``CefBridge``
- ``CefUserScript``
- ``CefFrame``
- ``CefJSON``
- ``CefJavaScriptError``

### Requests and content

- ``CefRequestFilter``
- ``CefResourceRequest``
- ``CefResourceRequestAction``
- ``CefSchemeHandler``
- ``CefSchemeRequest``
- ``CefSchemeResponse``
- ``CefDirectorySchemeHandler``
- ``CefCustomScheme``

### Security

- ``CefConnectionSecurity``
- ``CefCertificate``
- ``CefCertificateStatus``
- ``CefCertificateError``
- ``CefClientCertificateRequest``

### Downloads

- ``CefDownload``
- ``CefDownloadDecision``

### Settings

- ``CefPreferences``
- ``CefSiteSettings``
- ``CefSitePermission``
- ``CefCommandLine``
- ``CefLogSeverity``
- ``CefAppCapabilities``

### Context menus and commands

- ``CefContextMenu``
- ``CefContextMenuTarget``
- ``CefContextMenuCommand``
- ``CefChromeCommand``
- ``CefChromeTabRequest``
- ``CefChromeTabDecision``

### Finding and media

- ``CefFindSession``
- ``CefMediaRouter``
- ``CefMediaRouteError``

### DevTools

- ``CefDevTools``
- ``CefDevToolsError``

### Input and accessibility of offscreen pages

- ``CefKeyEvent``
- ``CefEventModifiers``
- ``CefMouseButton``
- ``CefTouchEvent``
- ``CefDragData``
- ``CefDragOperation``
- ``CefCursorType``
- ``CefOffscreenPaintDetails``
- ``CefOffscreenPaintElement``
- ``CefAccessibilityTree``
- ``CefAccessibilityNode``
- ``CefAccessibilityChanges``
- ``CefAccessibilityAction``

### Processes

- ``CefTaskManager``

### Threads

- ``CefIOActor``
- ``CefFileActor``

### Extending CefKit

- ``CefPageAttachment``
