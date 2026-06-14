import AppKit
import CefKit

// ponytail: AX tree bridge not implemented; enabled so VoiceOver gets basic NSView role.
extension CefMetalHostView {
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { "Web content" }
    public override func isAccessibilityElement() -> Bool { true }
}
