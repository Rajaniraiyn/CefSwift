import Foundation

/// What one accessibility update from Chromium changed, as a host needs it
/// to post platform notifications.
public struct CefAccessibilityChanges: Sendable, Equatable {
    /// Nodes that appeared.
    public var insertedNodes: Set<CefAccessibilityNode.ID> = []
    /// Nodes that went away. Their identifiers are never reused for another
    /// node.
    public var removedNodes: Set<CefAccessibilityNode.ID> = []
    /// Nodes whose role, states, attributes or children changed.
    public var updatedNodes: Set<CefAccessibilityNode.ID> = []
    /// Nodes whose value changed: a text field's text, a checkbox's state,
    /// a slider's position.
    public var valueChangedNodes: Set<CefAccessibilityNode.ID> = []
    /// Text fields whose selection or caret moved.
    public var selectedTextChangedNodes: Set<CefAccessibilityNode.ID> = []
    /// Containers whose selected children changed, such as a list box or a
    /// tab list.
    public var selectedChildrenChangedNodes: Set<CefAccessibilityNode.ID> = []
    /// Whether ``CefAccessibilityTree/focusedNode`` changed.
    public var focusDidChange = false
    /// Whether the main frame's document finished loading.
    public var didFinishLoading = false
    /// Whether nodes moved, resized, appeared or went away.
    public var layoutDidChange = false
    /// Text that live regions on the page ask to have announced.
    public var announcements: [CefAccessibilityChanges.Announcement] = []
    /// Chromium's own events, such as `"focus"`, `"loadComplete"` or
    /// `"valueChanged"`, in the order they arrived.
    public var events: [CefAccessibilityChanges.Event] = []

    /// Creates an empty set of changes.
    public init() {}

    /// Whether nothing changed.
    public var isEmpty: Bool { self == CefAccessibilityChanges() }
}

extension CefAccessibilityChanges {
    /// Text a live region asks assistive technology to announce.
    public struct Announcement: Sendable, Equatable {
        /// The text to announce.
        public var text: String
        /// Whether the region is `assertive`, interrupting current speech,
        /// rather than `polite`.
        public var isAssertive: Bool

        /// Creates an announcement.
        public init(text: String, isAssertive: Bool) {
            self.text = text
            self.isAssertive = isAssertive
        }
    }
}

extension CefAccessibilityChanges {
    /// An event Chromium reported with an accessibility update.
    public struct Event: Sendable, Equatable {
        /// Chromium's event name, such as `"focus"` or `"loadComplete"`.
        public var type: String
        /// The node the event is about.
        public var node: CefAccessibilityNode.ID?
    }
}
