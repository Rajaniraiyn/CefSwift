# Accessibility

## VoiceOver and the native a11y tree

CefSwift v1 embeds Chromium in **windowed mode**: CEF creates a real `NSView`
(child of your SwiftUI hosting view) and Chromium renders into it natively.
That means accessibility largely comes for free — Chromium exposes its own
native macOS accessibility tree under that view, the same machinery Chrome
itself uses:

- **VoiceOver works.** Page content, headings, links, form controls, and live
  regions are navigable; web ARIA semantics map to NSAccessibility the way
  they do in Chrome.
- The web a11y tree integrates into your app's tree at the point where the
  `CefWebView` sits, so VO users move between your native SwiftUI controls and
  page content continuously.
- Standard a11y inspection tools (Accessibility Inspector) see the full tree.

Chromium enables full web accessibility support lazily when an assistive
technology is detected, so there is no steady-state cost for non-AT users.

### Contrast with OSR (roadmap)

Off-screen rendering — planned, see the README roadmap — draws Chromium into
a texture, which severs the native a11y tree. An OSR view is just pixels until
the embedder implements CEF's accessibility handler
(`cef_accessibility_handler_t`) and rebuilds the tree as native accessibility
elements from CEF's serialized a11y events. That work is part of the OSR
roadmap item; until then, windowed mode is the accessible mode, and we treat
that as a feature of the v1 design rather than a limitation.

## Keyboard

- Tab/Shift-Tab, arrow keys, and standard web focus traversal work inside the
  page (Chromium handles them natively in windowed mode).
- Focus hand-off between SwiftUI controls and the CEF view follows normal
  AppKit first-responder behavior: clicking or tabbing into the web view gives
  Chromium key focus; Cmd-shortcuts handled by your app's menu bar still fire
  because CefSwift's `CEFApplication` participates in normal `sendEvent:`
  dispatch (it wraps, not replaces, event delivery).
- Full-keyboard-access users: ensure your surrounding SwiftUI chrome
  (omnibox, tab strip) is reachable — the Browser example keeps every control
  in a focusable toolbar.

## IME (input methods)

Windowed Chromium hosts its own NSTextInputClient machinery, so CJK and other
composition-based input methods work in form fields: inline composition,
candidate windows positioned at the caret, and marked-text handling are
Chromium's native implementations.

Known caveats in v1:

- Composition near the edge of a small embedded view can place the candidate
  window suboptimally.
- Rapid focus switches between native SwiftUI text fields and web fields
  while a composition is active can drop the composition.

"IME polish" on the roadmap tracks both. If you hit an IME issue, file it
with the input source name and a reproduction page — these are very
fixable but need concrete cases.
