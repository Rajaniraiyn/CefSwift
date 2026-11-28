# Showcase

What people build with CefSwift, and the pictures and video that show it.

## Built with CefSwift

| Project | What it is | Source |
|---|---|---|
| Browser (example) | A tabbed browser on Chromium's own windows and tabs, with a SwiftUI tab rail, toolbar, address bar suggestions, find bar, extensions from the Chrome Web Store, Memory Saver, passkeys and WebKit tabs for streaming | [`Examples/Sources/Browser`](../Examples/Sources/Browser) |
| Gallery (example) | 30 small demos, one capability each: offscreen rendering under SwiftUI, animation, the JavaScript bridge, custom schemes, Chrome-style windows, passkeys | [`Examples/Sources/Gallery`](../Examples/Sources/Gallery) |
| Minimal (example) | The smallest CefSwift app: one window, one `CefWebView` | [`Examples/Sources/Minimal`](../Examples/Sources/Minimal) |
| Xcode example | A SwiftUI app built by Xcode rather than SwiftPM | [`Examples/Xcode`](../Examples/Xcode) |
| *Unnamed browser by Assim-Genshi* | A browser built on CefSwift, shown in [#22](https://github.com/Rajaniraiyn/CefSwift/issues/22) | TODO |

<!-- TODO(owner): ask Assim-Genshi in #22 whether they want the project
listed, under what name and link, and whether one of their screenshots can
be used here. Until they answer, keep this row as a placeholder. -->

Built something with CefSwift? Open a pull request that adds a row.

## Assets

Every picture below is a real capture of an example app built from this
repository (CEF 158, Chromium 158.0.8127.89) on macOS 27, with a fresh
profile and public pages only. The cards and thread images put those
captures on a plain background with type; nothing in them is drawn to
look like UI.

### Screenshots (`docs/images/`)

| File | What it shows | Meant for |
|---|---|---|
| [`browser-hero-light.png`](images/browser-hero-light.png) | The Browser example in light mode: seven Chromium tabs in the SwiftUI tab rail, the address field editing "swiftui" with Chromium's autocomplete suggestions (search and history) open | README hero, docs home, HN link preview |
| [`browser-hero-dark.png`](images/browser-hero-dark.png) | The same window in dark mode, swift.org in dark, address field idle | README hero (dark, with `<picture>`), docs home in dark mode |
| [`browser-find-bar.png`](images/browser-find-bar.png) | The browser's SwiftUI find bar ("browser", 1 of 69) over a Chromium page (Wikipedia), and the SwiftUI status bubble showing a hovered link | Docs: Chrome-style windows / find bar; X thread post 3 |
| [`browser-web-store-install.png`](images/browser-web-store-install.png) | The Chrome Web Store opened in the Browser, with Chromium's own "Add uBlock Origin Lite?" install prompt | Docs: extensions; X thread post 4 |
| [`browser-chrome-extensions.png`](images/browser-chrome-extensions.png) | Chromium's own `chrome://extensions` page in a Browser tab (no extensions installed yet) | Docs: extensions, Chromium pages |
| [`browser-chrome-history.png`](images/browser-chrome-history.png) | Chromium's own `chrome://history` page, listing the session's visits | Docs: history and bookmarks; X thread post 4 |
| [`browser-webkit-streaming.png`](images/browser-webkit-streaming.png) | tv.apple.com in a WebKit tab (`SystemEngine`), with the toolbar's WebKit badge; cropped at the bottom to drop the site's region banner | Docs: media and DRM; X thread post 5 |
| [`gallery-offscreen-overlay.png`](images/gallery-offscreen-overlay.png) | Gallery › Offscreen Rendering: an offscreen Chromium page clipped to a rounded card, with native SwiftUI controls drawn over it | Docs: offscreen rendering; X thread post 6 |
| [`gallery-passkeys.png`](images/gallery-passkeys.png) | Gallery › Passkeys: the demo page and the app's (empty) passkey list, before a passkey is created | Docs: passkeys; X thread post 5 |
| [`browser.png`](images/browser.png) | The existing README screenshot (unchanged) | README |

### Cards (`docs/images/`)

| File | Size | What it is | Meant for |
|---|---|---|---|
| [`social-preview.png`](images/social-preview.png) | 1280×640 | Name, "Build Chromium browsers and apps for macOS in Swift", and the light hero | GitHub social preview (Settings › Social preview), HN and Slack unfurls |
| [`x-article-cover.png`](images/x-article-cover.png) | 1600×900 | "How to build a Chromium browser without building Chromium" over the dark hero | X Article cover |

### X thread (`docs/images/x-thread/`, 1600×900 each)

| File | Post |
|---|---|
| [`x-1-hero.png`](images/x-thread/x-1-hero.png) | 1. The hook; attach `docs/media/browser-demo-1080p.mp4` and use this as the fallback image or quote card |
| [`x-2-code.png`](images/x-thread/x-2-code.png) | 2. The code: the whole SwiftUI app from the README, and the Browser's `FindBar` feature |
| [`x-3-tabs.png`](images/x-thread/x-3-tabs.png) | 3. Real Chromium tabs under a SwiftUI tab rail, toolbar and find bar |
| [`x-4-extensions.png`](images/x-thread/x-4-extensions.png) | 4. The Chrome Web Store install prompt and `chrome://history` |
| [`x-5-passkeys-streaming.png`](images/x-thread/x-5-passkeys-streaming.png) | 5. Passkeys (Gallery demo) and a streaming site in a WebKit tab |
| [`x-6-offscreen.png`](images/x-thread/x-6-offscreen.png) | 6. Offscreen rendering under SwiftUI (pages render at up to 120 fps with `.offscreen(frameRate: 120)`) |
| [`x-7-open-source.png`](images/x-thread/x-7-open-source.png) | 7. Open source: MIT, the repository URL, the dark hero |

### Video (`docs/media/`)

| File | Size | What it is | Meant for |
|---|---|---|---|
| [`browser-demo-1080p.mp4`](media/browser-demo-1080p.mp4) | 1920×1080, 29 s, H.264, no audio, 1.5 MB | Title card; new tabs and tab switching; address bar suggestions; the SwiftUI find bar; the Web Store install prompt; `chrome://extensions` and `chrome://history`; a streaming site opening in a WebKit tab; the Gallery's offscreen card; end card | X thread post 1 (16:9), docs home, HN comment link |
| [`browser-demo.mp4`](media/browser-demo.mp4) | 1280×720, 0.6 MB | The same cut, smaller | README (`<video>` in a GitHub comment or release, or linked from the hero) |
| [`browser-demo.gif`](media/browser-demo.gif) | 800 px, 9 s loop, 0.3 MB | The tab switching and suggestions part, looping | README hero where video does not play |
| [`browser-demo-poster.jpg`](media/browser-demo-poster.jpg) | 1920×1080 | A frame of the cut | `poster` for the video on the docs site |

The tab switching, `chrome://` pages and WebKit parts of the video are
screen recordings of the running app (ScreenCaptureKit, the app's own
windows only). The suggestions, find bar, Web Store and Gallery parts are
real screenshots held for a few seconds each, because those states needed
the app in front while the machine was in use.

### Not captured yet

- **An installed extension.** The Web Store's install prompt is real, but
  the capture could not click "Add extension", so `chrome://extensions`
  is still empty. Install one by hand and retake
  `browser-chrome-extensions.png`.
- **A discarded tab.** `CefPage.discard()` on a background tab of a
  `CefChromeWindow` threw `not discardable: visible` in this run, so the
  rail's asleep indicator is not shown.
- **The passkey sheet.** Creating a passkey needs a click in the page and
  the app in front; `gallery-passkeys.png` shows the demo before that.
- **Bookmarks and History menus**, the Manage Extensions window and the
  Gallery's animation scenes while they move.

### Reproducing the captures

The screenshots and video frames came from the Browser and Gallery
examples, bundled with `swift package --package-path Examples … cef bundle`,
and captured window by window (`screencapture -l`, the app's own windows
only). The cards and thread images are HTML rendered by a headless
Chromium at their exact size.
