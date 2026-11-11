import AppKit
import CefKit

// Offscreen pages are exposed to assistive technology as a single "web
// content" group. Bridging Chromium's accessibility tree node by node is not
// implemented; use windowed rendering where VoiceOver support matters.
extension CefOffscreenBrowserView {
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { "Web content" }
    public override func isAccessibilityElement() -> Bool { true }
}
