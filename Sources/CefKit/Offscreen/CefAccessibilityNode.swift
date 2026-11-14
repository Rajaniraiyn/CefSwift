import CoreGraphics
import Foundation

/// One node of an offscreen page's accessibility tree, as Chromium reports
/// it.
///
/// Roles, states and attribute names are Chromium's own (`ax::mojom`
/// names such as `"button"`, `"focusable"` or `"textSelStart"`); the typed
/// properties cover the ones a platform bridge needs, and ``attributes``
/// holds everything Chromium sent.
public struct CefAccessibilityNode: Identifiable, Sendable, Equatable {

    /// Identifies a node across the page's frames: Chromium keeps one tree
    /// per frame, and node numbers are only unique within a tree.
    public struct ID: Hashable, Sendable, CustomStringConvertible {
        /// The identifier of the frame's tree.
        public var tree: String
        /// The node's number within its tree.
        public var node: Int32

        /// Creates an identifier.
        public init(tree: String, node: Int32) {
            self.tree = tree
            self.node = node
        }

        public var description: String { "\(node)@\(tree.prefix(8))" }
    }

    /// Whether a checkbox, radio button, switch or toggle button is on.
    public enum CheckedState: String, Sendable, Equatable {
        /// Off.
        case unchecked = "false"
        /// On.
        case checked = "true"
        /// Partly on, as for a checkbox whose children are partly checked.
        case mixed
    }

    /// The node's identifier.
    public let id: ID
    /// Chromium's role, such as `"rootWebArea"`, `"heading"` or `"textField"`.
    public internal(set) var role: String
    /// Chromium's state flags, such as `"focusable"`, `"expanded"` or
    /// `"ignored"`.
    public internal(set) var states: Set<String>
    /// The attributes Chromium sent, keyed by Chromium's attribute name.
    /// Styling (colors, fonts) and word boundaries are left out to save
    /// memory.
    public internal(set) var attributes: [String: CefJSON]
    /// The actions Chromium reports the node supports, such as `"focus"`.
    public internal(set) var actions: Set<String>
    /// The node's children within its own tree, in order.
    public internal(set) var childIDs: [ID]
    /// The node's parent within its own tree; `nil` for a tree's root.
    public internal(set) var parentID: ID?

    /// The bounds relative to ``offsetContainer``, in Chromium's physical
    /// pixels. ``CefAccessibilityTree/frame(of:)`` resolves them.
    public internal(set) var relativeBounds: CGRect
    /// The node ``relativeBounds`` is relative to; `nil` for the tree's root.
    public internal(set) var offsetContainer: ID?
    /// A transform applied to ``relativeBounds`` before the container's
    /// offset, such as from a CSS transform.
    public internal(set) var transform: CGAffineTransform?

    init(id: ID, role: String) {
        self.id = id
        self.role = role
        self.states = []
        self.attributes = [:]
        self.actions = []
        self.childIDs = []
        self.relativeBounds = .zero
    }
}

// MARK: - Typed attributes

extension CefAccessibilityNode {
    /// The node's accessible name: a button's title, an image's alt text,
    /// a text run's characters.
    public var name: String? { string("name") }
    /// The node's value, such as a text field's contents.
    public var value: String? { string("value") }
    /// The accessible description, from `aria-describedby` or a `title`.
    public var accessibleDescription: String? { string("description") }
    /// A text field's placeholder.
    public var placeholder: String? { string("placeholder") }
    /// The address of a link or image.
    public var url: URL? { string("url").flatMap(URL.init(string:)) }
    /// A role description the page set with `aria-roledescription`.
    public var roleDescription: String? { string("roleDescription") }
    /// The HTML tag, such as `"input"`.
    public var htmlTag: String? { string("htmlTag") }
    /// An `<input>`'s type, such as `"password"`.
    public var inputType: String? { string("inputType") }
    /// How the name was computed, such as `"contents"` or `"attribute"`.
    public var nameFrom: String? { string("nameFrom") }
    /// Keyboard shortcuts from `aria-keyshortcuts`.
    public var keyShortcuts: String? { string("keyShortcuts") }
    /// For an `<iframe>`, the identifier of the frame's own tree.
    public var childTreeID: String? { string("childTreeId") }
    /// The DOM node's identifier — the DevTools protocol's `backendNodeId`.
    public var domNodeID: Int? {
        attributes["domNodeId"]?.intValue ?? attributes["domNodeIdDeprecated"]?.intValue
    }

    /// The checked state of a checkbox, radio button, switch or toggle.
    public var checkedState: CheckedState? { string("checkedState").flatMap(CheckedState.init(rawValue:)) }
    /// A heading's level, 1 to 6, or a tree item's nesting level.
    public var hierarchicalLevel: Int? { int("hierarchicalLevel") }
    /// Whether a disclosure is expanded: `nil` when the node does not expand.
    public var isExpanded: Bool? {
        if states.contains("expanded") { return true }
        if states.contains("collapsed") { return false }
        return nil
    }
    /// Whether an option, tab, row or cell is selected; `nil` when the node
    /// cannot be selected.
    public var isSelected: Bool? { attributes["selected"]?.boolValue }
    /// Whether the node is disabled.
    public var isDisabled: Bool { string("restriction") == "disabled" }
    /// Whether the node is read-only.
    public var isReadOnly: Bool { string("restriction") == "readOnly" }
    /// Whether the page left the node out of the accessible tree.
    public var isIgnored: Bool { states.contains("ignored") }
    /// Whether the node is hidden.
    public var isInvisible: Bool { states.contains("invisible") }
    /// Whether the node can take focus.
    public var isFocusable: Bool { states.contains("focusable") }
    /// Whether the node's text can be edited.
    public var isEditable: Bool { states.contains("editable") }
    /// Whether the node is a rich-text (`contenteditable`) region.
    public var isRichlyEditable: Bool { states.contains("richlyEditable") }
    /// Whether a text field takes several lines.
    public var isMultiline: Bool { states.contains("multiline") }
    /// Whether a text field hides its contents, as password fields do.
    public var isProtected: Bool { states.contains("protected") || inputType == "password" }
    /// Whether a field must be filled in.
    public var isRequired: Bool { states.contains("required") }
    /// Whether a link was visited.
    public var isVisited: Bool { states.contains("visited") }
    /// Whether a list box or grid allows several selected items.
    public var isMultiselectable: Bool { states.contains("multiselectable") }
    /// Whether the node is busy updating (`aria-busy`).
    public var isBusy: Bool { attributes["busy"]?.boolValue == true }
    /// Whether the node is a modal dialog.
    public var isModal: Bool { attributes["modal"]?.boolValue == true }

    /// The selection in a text field, as UTF-16 offsets into ``value``;
    /// an offset before the start, as a renderer may send, is the start.
    public var textSelection: NSRange? {
        guard let start = int("textSelStart"), let end = int("textSelEnd") else { return nil }
        let lower = max(0, min(start, end))
        return NSRange(location: lower, length: max(0, max(start, end) - lower))
    }

    /// The current, minimum, maximum and step values of a slider, progress
    /// indicator, meter or spin button.
    public var rangeValue: Double? { double("valueForRange") }
    /// The minimum of ``rangeValue``.
    public var minimumRangeValue: Double? { double("minValueForRange") }
    /// The maximum of ``rangeValue``.
    public var maximumRangeValue: Double? { double("maxValueForRange") }
    /// The step of ``rangeValue``.
    public var rangeStep: Double? { double("stepValueForRange") }

    /// The live-region politeness that applies to this node: `"polite"`,
    /// `"assertive"`, or `nil` outside live regions.
    public var liveStatus: String? {
        guard let status = string("containerLiveStatus") ?? string("liveStatus"), status != "off" else { return nil }
        return status
    }
    /// Whether the node is the root of a live region.
    public var isLiveRoot: Bool { string("liveStatus").map { $0 != "off" } ?? false }
    /// Whether the live region announces as a whole.
    public var isLiveAtomic: Bool {
        attributes["containerLiveAtomic"]?.boolValue == true || attributes["liveAtomic"]?.boolValue == true
    }

    /// The horizontal and vertical scroll offsets of a scrollable node, in
    /// Chromium's physical pixels.
    public var scrollOffset: CGPoint? {
        guard int("scrollX") != nil || int("scrollY") != nil else { return nil }
        return CGPoint(x: int("scrollX") ?? 0, y: int("scrollY") ?? 0)
    }

    /// A table's row count.
    public var tableRowCount: Int? { int("tableRowCount") ?? int("ariaRowCount") }
    /// A table's column count.
    public var tableColumnCount: Int? { int("tableColumnCount") ?? int("ariaColumnCount") }
    /// A row's index within its table.
    public var tableRowIndex: Int? { int("tableRowIndex") }
    /// A cell's row index and span.
    public var tableCellRowRange: NSRange? {
        int("tableCellRowIndex").map { NSRange(location: $0, length: int("tableCellRowSpan") ?? 1) }
    }
    /// A cell's column index and span.
    public var tableCellColumnRange: NSRange? {
        int("tableCellColumnIndex").map { NSRange(location: $0, length: int("tableCellColumnSpan") ?? 1) }
    }
    /// The item's position in its set, from 1, and the set's size.
    public var positionInSet: (position: Int, size: Int)? {
        guard let position = int("posInSet"), let size = int("setSize") else { return nil }
        return (position, size)
    }

    /// For an inline text box: where each character ends, in pixels from the
    /// box's start.
    public var characterOffsets: [Int] { attributes["characterOffsets"]?.arrayValue?.compactMap(\.intValue) ?? [] }

    /// A string attribute.
    public func string(_ name: String) -> String? {
        guard let value = attributes[name]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// An integer attribute.
    public func int(_ name: String) -> Int? { attributes[name]?.intValue }

    /// A floating-point attribute.
    public func double(_ name: String) -> Double? { attributes[name]?.doubleValue }

    /// An integer-list attribute of node numbers, as node identifiers in the
    /// same tree.
    public func nodeIDs(_ name: String) -> [ID] {
        attributes[name]?.arrayValue?.compactMap(\.intValue).map { ID(tree: id.tree, node: Int32(truncatingIfNeeded: $0)) } ?? []
    }
}

// MARK: - Parsing

extension CefAccessibilityNode {
    /// Reads a node from Chromium's serialized `AXNodeData`.
    init?(json: CefJSON, tree: String) {
        guard let number = json["id"].intValue else { return nil }
        let id = ID(tree: tree, node: Int32(truncatingIfNeeded: number))
        self.init(id: id, role: json["role"].stringValue ?? "unknown")
        // CEF pads the list with empty names.
        states = Set(json["state"].arrayValue?.compactMap(\.stringValue).filter { !$0.isEmpty } ?? [])
        actions = Set(json["actions"].arrayValue?.compactMap(\.stringValue) ?? [])
        attributes = (json["attributes"].objectValue ?? [:]).filter { !Self.droppedAttributes.contains($0.key) }
        childIDs = json["child_ids"].arrayValue?.compactMap(\.intValue).map {
            ID(tree: tree, node: Int32(truncatingIfNeeded: $0))
        } ?? []
        applyLocation(
            bounds: json["location"],
            offsetContainer: json["offset_container_id"].intValue,
            transform: json["transform"].stringValue)
    }

    /// Applies serialized relative bounds.
    mutating func applyLocation(bounds: CefJSON, offsetContainer: Int?, transform: String?) {
        relativeBounds = CGRect(
            x: bounds["x"].doubleValue ?? 0, y: bounds["y"].doubleValue ?? 0,
            width: bounds["width"].doubleValue ?? 0, height: bounds["height"].doubleValue ?? 0)
        self.offsetContainer = offsetContainer.flatMap { $0 < 0 ? nil : ID(tree: id.tree, node: Int32(truncatingIfNeeded: $0)) }
        self.transform = transform.flatMap(Self.parseTransform)
    }

    /// Attributes no platform bridge reads, which make up much of a large
    /// page's tree.
    static let droppedAttributes: Set<String> = [
        "color", "backgroundColor", "fontFamily", "fontWeight", "wordStarts", "wordEnds",
        "notUserSelectableStyle", "hasAriaAttribute", "text-align",
    ]

    /// Parses `gfx::Transform::ToString()`: a 4×4 matrix written row by row.
    static func parseTransform(_ text: String) -> CGAffineTransform? {
        let numbers = text.split(whereSeparator: { !"0123456789+-.eE".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 16 else { return nil }
        let transform = CGAffineTransform(
            a: numbers[0], b: numbers[4], c: numbers[1], d: numbers[5], tx: numbers[3], ty: numbers[7])
        return transform.isIdentity ? nil : transform
    }
}
