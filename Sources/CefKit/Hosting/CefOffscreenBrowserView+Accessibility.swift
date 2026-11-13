import AppKit

// The view is an `AXGroup` whose child is the page's `AXWebArea`. Chromium
// builds the page's tree only once an assistive app asks for it (see
// ``CefBrowser/Configuration/offscreenAccessibility``); until it arrives the group
// has no children.
extension CefOffscreenBrowserView {

    /// Posted on the main thread, with the view as the object, each time the
    /// view posts an accessibility notification for its page — for tests and
    /// diagnostics. `userInfo` holds the ``accessibilityNotificationKey``
    /// (an `NSAccessibility.Notification`) and the ``accessibilityElementKey``
    /// (the element it was posted for).
    public nonisolated static let didPostAccessibilityNotification = Notification.Name("CefOffscreenBrowserViewDidPostAccessibilityNotification")
    /// The `NSAccessibility.Notification` in a
    /// ``didPostAccessibilityNotification``.
    public nonisolated static let accessibilityNotificationKey = "notification"
    /// The element in a ``didPostAccessibilityNotification``.
    public nonisolated static let accessibilityElementKey = "element"

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .group }

    /// What VoiceOver calls the view: “Web content”, unless the app set
    /// a label with `setAccessibilityLabel(_:)`.
    public override func accessibilityLabel() -> String? {
        super.accessibilityLabel()
            ?? String(localized: "Web content", bundle: .cefKit, comment: "Accessibility label of an offscreen browser view: the web page it shows.")
    }

    public override func accessibilityChildren() -> [Any]? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.rootElement.map { [$0] } ?? []
        }
    }

    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.hitTest(screenPoint: point) ?? self
        }
    }

    public override var accessibilityFocusedUIElement: Any? {
        onMain {
            accessibilityBridge.requestTree()
            return accessibilityBridge.focusedElement ?? self
        }
    }

    public func offscreenAccessibilityTreeDidChange(_ changes: CefAccessibilityChanges) {
        accessibilityBridge.treeDidChange(changes)
    }
}
