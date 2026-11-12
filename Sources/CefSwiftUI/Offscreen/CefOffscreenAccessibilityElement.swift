import AppKit
import CefKit

/// Runs `body` on the main actor. AppKit serves accessibility requests on
/// the main thread, but its accessibility methods are not annotated.
func onMain<T>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated { UncheckedSendable(value: body()) }.value
}

/// Carries a value out of `MainActor.assumeIsolated`, which only returns
/// `Sendable` values; it never leaves the main thread.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// One node of an offscreen page, as an AppKit accessibility element.
///
/// Elements hold only the node's identifier and read the node from the
/// browser's ``CefAccessibilityTree`` on every query, so they always report
/// the page as it is. An element whose node has gone away reports itself
/// as an empty group until assistive apps let go of it.
///
/// `NSAccessibilityElement` is not `Sendable`, so the main-actor work lives
/// in ``Content`` and each override hops to it.
final class CefOffscreenAccessibilityElement: NSAccessibilityElement {
    let nodeID: CefAccessibilityNode.ID
    private let content: Content

    @MainActor
    init(nodeID: CefAccessibilityNode.ID, bridge: CefOffscreenAccessibilityBridge) {
        self.nodeID = nodeID
        self.content = Content(nodeID: nodeID, bridge: bridge)
        super.init()
    }

    // MARK: Identity

    override func isAccessibilityElement() -> Bool { onMain { [content] in content.node != nil } }
    override func accessibilityRole() -> NSAccessibility.Role? { onMain { [content] in content.mapped?.role ?? .group } }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { onMain { [content] in content.mapped?.subrole } }
    override func accessibilityRoleDescription() -> String? { onMain { [content] in content.roleDescription() } }
    override func accessibilityIdentifier() -> String { onMain { [content] in content.node?.string("htmlId") ?? "" } }

    // MARK: Text attributes

    override func accessibilityLabel() -> String? { onMain { [content] in content.label() } }
    override func accessibilityTitle() -> String? { onMain { [content] in content.title() } }
    override func accessibilityValue() -> Any? { onMain { [content] in content.value() } }
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let text = accessibilityValue as? String ?? (accessibilityValue as? NSAttributedString)?.string else { return }
        onMain { [content] in content.perform(.setValue(text)) }
    }
    override func accessibilityHelp() -> String? { onMain { [content] in content.node?.accessibleDescription } }
    override func accessibilityPlaceholderValue() -> String? { onMain { [content] in content.node?.placeholder } }
    override func accessibilityURL() -> URL? { onMain { [content] in content.url() } }
    override func accessibilityMinValue() -> Any? {
        onMain { [content] in content.node?.minimumRangeValue.map { NSNumber(value: $0) } }
    }
    override func accessibilityMaxValue() -> Any? {
        onMain { [content] in content.node?.maximumRangeValue.map { NSNumber(value: $0) } }
    }

    // MARK: States

    override func isAccessibilityEnabled() -> Bool { onMain { [content] in !(content.node?.isDisabled ?? false) } }
    override func isAccessibilityFocused() -> Bool { onMain { [content] in content.isFocused } }
    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard accessibilityFocused else { return }
        onMain { [content] in content.perform(.focus) }
    }
    override func isAccessibilitySelected() -> Bool { onMain { [content] in content.node?.isSelected ?? false } }
    override func isAccessibilityExpanded() -> Bool { onMain { [content] in content.node?.isExpanded ?? false } }
    override func isAccessibilityRequired() -> Bool { onMain { [content] in content.node?.isRequired ?? false } }
    override func isAccessibilityProtectedContent() -> Bool { onMain { [content] in content.node?.isProtected ?? false } }

    // MARK: Hierarchy

    override func accessibilityChildren() -> [Any]? { onMain { [content] in content.children() } }
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        accessibilityChildren() as? [NSAccessibilityElementProtocol]
    }
    override func accessibilitySelectedChildren() -> [Any]? { onMain { [content] in content.selectedChildren() } }
    override func accessibilityParent() -> Any? { onMain { [content] in content.parent() } }
    override func accessibilityWindow() -> Any? { onMain { [content] in content.bridge?.view?.window } }
    override func accessibilityTopLevelUIElement() -> Any? { onMain { [content] in content.bridge?.view?.window } }

    // MARK: Geometry

    override func accessibilityFrame() -> NSRect { onMain { [content] in content.frame() } }
    override func accessibilityActivationPoint() -> NSPoint {
        let frame = accessibilityFrame()
        return NSPoint(x: frame.midX, y: frame.midY)
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let hit: Any? = onMain { [content] in content.bridge?.hitTest(screenPoint: point) }
        return hit ?? self
    }
    override var accessibilityFocusedUIElement: Any {
        onMain { [content] in content.bridge?.focusedElement } ?? self
    }

    // MARK: Text

    override func accessibilityNumberOfCharacters() -> Int { onMain { [content] in (content.text as NSString?)?.length ?? 0 } }
    override func accessibilitySelectedText() -> String? { onMain { [content] in content.selectedText() } }
    override func accessibilitySelectedTextRange() -> NSRange {
        onMain { [content] in content.selectedRange ?? NSRange(location: 0, length: 0) }
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }
    override func accessibilityInsertionPointLineNumber() -> Int { onMain { [content] in content.insertionPointLine() } }
    override func accessibilityLine(for index: Int) -> Int {
        onMain { [content] in content.tree?.lineIndex(ofCharacterAt: index, in: content.nodeID) ?? 0 }
    }
    override func accessibilityString(for range: NSRange) -> String? { onMain { [content] in content.string(for: range) } }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        onMain { [content] in content.frame(for: range) } ?? accessibilityFrame()
    }

    // MARK: Tables

    override func accessibilityRows() -> [Any]? { onMain { [content] in content.rowElements() } }
    override func accessibilityRowCount() -> Int { onMain { [content] in content.node?.tableRowCount ?? content.rows().count } }
    override func accessibilityColumnCount() -> Int { onMain { [content] in content.node?.tableColumnCount ?? 0 } }
    override func accessibilityIndex() -> Int { onMain { [content] in content.node?.tableRowIndex ?? 0 } }
    override func accessibilityRowIndexRange() -> NSRange {
        onMain { [content] in content.node?.tableCellRowRange ?? NSRange(location: 0, length: 0) }
    }
    override func accessibilityColumnIndexRange() -> NSRange {
        onMain { [content] in content.node?.tableCellColumnRange ?? NSRange(location: 0, length: 0) }
    }
    override func accessibilityDisclosureLevel() -> Int { onMain { [content] in content.disclosureLevel() } }

    // MARK: Actions

    override func accessibilityPerformPress() -> Bool { onMain { [content] in content.performIfSupported(.press) } }
    override func accessibilityPerformIncrement() -> Bool { onMain { [content] in content.performIfSupported(.increment) } }
    override func accessibilityPerformDecrement() -> Bool { onMain { [content] in content.performIfSupported(.decrement) } }
    override func accessibilityPerformShowMenu() -> Bool { onMain { [content] in content.performIfSupported(.showMenu) } }

    /// `AXScrollToVisible`, which the NSAccessibility protocol has no method
    /// for, arrives through the informal protocol, so every action is listed
    /// and dispatched here.
    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        onMain { [content] in content.actionNames() }
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        switch action {
        case .press: _ = accessibilityPerformPress()
        case .increment: _ = accessibilityPerformIncrement()
        case .decrement: _ = accessibilityPerformDecrement()
        case .showMenu: _ = accessibilityPerformShowMenu()
        case Self.scrollToVisible: _ = onMain { [content] in content.performIfSupported(.scrollToVisible) }
        default: break
        }
    }

    override func accessibilityActionDescription(_ action: NSAccessibility.Action) -> String? {
        switch action {
        case .press: "press"
        case .increment: "increment"
        case .decrement: "decrement"
        case .showMenu: "show menu"
        case Self.scrollToVisible: "scroll to visible"
        default: nil
        }
    }

    static let scrollToVisible = NSAccessibility.Action(rawValue: "AXScrollToVisible")
}

// MARK: - Content

extension CefOffscreenAccessibilityElement {
    /// What an element reports, read from the tree on the main actor.
    @MainActor
    final class Content {
        let nodeID: CefAccessibilityNode.ID
        weak var bridge: CefOffscreenAccessibilityBridge?

        init(nodeID: CefAccessibilityNode.ID, bridge: CefOffscreenAccessibilityBridge) {
            self.nodeID = nodeID
            self.bridge = bridge
        }

        var tree: CefAccessibilityTree? { bridge?.tree }
        var node: CefAccessibilityNode? { tree?.node(nodeID) }
        var mapped: (role: NSAccessibility.Role, subrole: NSAccessibility.Subrole?)? {
            node.map(CefAccessibilityRoleMapping.role(for:))
        }

        func roleDescription() -> String? {
            guard let node, let mapped else { return nil }
            if let custom = node.roleDescription { return custom }
            switch node.role {
            case "rootWebArea", "webArea": return "HTML content"
            case "heading": return "heading"
            case "listMarker": return "list marker"
            default: return mapped.role.description(with: mapped.subrole)
            }
        }

        func label() -> String? {
            guard let node, node.role != "staticText" else { return nil }
            guard let name = node.name, !CefAccessibilityRoleMapping.nameIsTitle(node) else { return nil }
            return name
        }

        func title() -> String? {
            guard let node, node.role != "staticText" else { return nil }
            if node.role == "rootWebArea" { return node.name ?? "" }
            guard let name = node.name, CefAccessibilityRoleMapping.nameIsTitle(node) else { return nil }
            return name
        }

        func value() -> Any? {
            guard let node, let tree else { return nil }
            return CefAccessibilityRoleMapping.value(for: node) { tree.textContent(of: node.id) }
        }

        func url() -> URL? {
            guard let node else { return nil }
            switch node.role {
            case "link", "image", "rootWebArea", "webArea": return node.url
            default: return nil
            }
        }

        var isFocused: Bool { tree?.focusedNode?.id == nodeID }

        func children() -> [Any] {
            guard let bridge, let tree else { return [] }
            return tree.children(of: nodeID).map { bridge.element(for: $0.id) }
        }

        func selectedChildren() -> [Any]? {
            guard let bridge, let tree else { return nil }
            return tree.children(of: nodeID).filter { $0.isSelected == true }.map { bridge.element(for: $0.id) }
        }

        func parent() -> Any? {
            guard let bridge else { return nil }
            if let parent = tree?.parent(of: nodeID) { return bridge.element(for: parent.id) }
            return bridge.view
        }

        func frame() -> NSRect {
            guard let bridge, let frame = tree?.frame(of: nodeID) else { return .zero }
            return bridge.screenRect(forViewRect: frame)
        }

        // Text

        var text: String? {
            guard let node, CefAccessibilityRoleMapping.isTextRole(node) || node.role == "staticText" else { return nil }
            return CefAccessibilityRoleMapping.value(for: node) { tree?.textContent(of: node.id) ?? "" } as? String
        }

        var selectedRange: NSRange? {
            guard let text, let selection = node?.textSelection else { return nil }
            let length = (text as NSString).length
            let location = min(selection.location, length)
            return NSRange(location: location, length: min(selection.length, length - location))
        }

        func selectedText() -> String? {
            guard let text, let range = selectedRange else { return nil }
            return (text as NSString).substring(with: range)
        }

        func insertionPointLine() -> Int {
            guard let tree, let range = selectedRange else { return 0 }
            return tree.lineIndex(ofCharacterAt: range.location + range.length, in: nodeID) ?? 0
        }

        func string(for range: NSRange) -> String? {
            guard let text else { return nil }
            let string = text as NSString
            guard range.location >= 0, range.length >= 0, range.location + range.length <= string.length else { return nil }
            return string.substring(with: range)
        }

        func frame(for range: NSRange) -> NSRect? {
            guard let bridge, let frame = tree?.frame(ofCharacterRange: range, in: nodeID) else { return nil }
            return bridge.screenRect(forViewRect: frame)
        }

        // Tables

        func rows() -> [CefAccessibilityNode] {
            guard let tree else { return [] }
            var rows: [CefAccessibilityNode] = []
            func collect(_ id: CefAccessibilityNode.ID, depth: Int) {
                guard depth < 8 else { return }
                for child in tree.children(of: id) {
                    if child.role == "row" || child.role == "treeItem" || child.role == "layoutTableRow" {
                        rows.append(child)
                    } else if child.role == "rowGroup" || child.role == "genericContainer" || child.role == "group" {
                        collect(child.id, depth: depth + 1)
                    }
                }
            }
            collect(nodeID, depth: 0)
            return rows
        }

        func rowElements() -> [Any]? {
            guard let bridge, let role = mapped?.role, role == .table || role == .outline else { return nil }
            return rows().map { bridge.element(for: $0.id) }
        }

        func disclosureLevel() -> Int {
            guard let node, node.role == "treeItem" else { return 0 }
            return max((node.hierarchicalLevel ?? 1) - 1, 0)
        }

        // Actions

        func actionNames() -> [NSAccessibility.Action] {
            guard let node else { return [] }
            var names: [NSAccessibility.Action] = []
            if CefAccessibilityRoleMapping.isPressable(node) || node.isFocusable { names.append(.press) }
            if CefAccessibilityRoleMapping.isAdjustable(node) { names += [.increment, .decrement] }
            names += [.showMenu, CefOffscreenAccessibilityElement.scrollToVisible]
            return names
        }

        func performIfSupported(_ action: CefAccessibilityAction) -> Bool {
            guard let node else { return false }
            switch action {
            case .press:
                guard CefAccessibilityRoleMapping.isPressable(node) || node.isFocusable else { return false }
            case .increment, .decrement:
                guard CefAccessibilityRoleMapping.isAdjustable(node) else { return false }
            default:
                break
            }
            perform(action)
            return true
        }

        func perform(_ action: CefAccessibilityAction) {
            bridge?.perform(action, on: nodeID)
        }
    }
}
