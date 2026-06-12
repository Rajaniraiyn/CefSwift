import AppKit
import CefKit
import Foundation

/// Baseline NSAccessibility bridge for the OSR web view.
///
/// CEF delivers the page's accessibility tree (Chromium's AXTree, serialized)
/// through ``CefOSRHost/osrAccessibilityTreeDidChange(_:)`` once accessibility
/// is enabled. This bridge decodes that tree into a flat node map and exposes
/// the web content as a child accessibility group of the host view, with one
/// `NSAccessibilityElement` proxy per node carrying role/title/value/frame.
///
/// HONEST SCOPE: this gives VoiceOver a navigable, labeled top-level view of
/// web content (role + name/value + frame for each mapped node). It does *not*
/// yet implement full hit-testing, live focus tracking, text-range navigation,
/// or actions. See docs/accessibility.md for the precise state.
@MainActor
final class CefOSRAccessibilityBridge {
    private weak var host: CefMetalHostView?
    /// Flat map of nodeId → proxy element.
    private var nodes: [Int: CefAXNodeElement] = [:]
    /// The synthetic root group element exposed as the host view's AX child.
    private(set) var rootElements: [CefAXNodeElement] = []

    init(host: CefMetalHostView) {
        self.host = host
    }

    /// Decodes a full AX-tree change and rebuilds the proxy elements.
    func applyTreeChange(_ value: CefAXValue) {
        guard let host else { return }
        let dict = value.dictionary
        guard let updates = dict?["updates"]?.list else { return }

        for update in updates {
            guard let nodeList = update["nodes"]?.list else { continue }
            for node in nodeList {
                guard let nodeDict = node.dictionary,
                      let id = nodeDict["id"]?.intValue else { continue }
                let role = nodeDict["role"]?.string ?? "group"
                let attrs = nodeDict["attributes"]?.dictionary
                let name = attrs?["name"]?.string ?? ""
                let valueStr = attrs?["value"]?.string ?? ""
                let childIDs = (nodeDict["child_ids"]?.list ?? []).compactMap { $0.intValue }
                let frame = Self.frame(from: nodeDict["location"], host: host)

                let element = nodes[id] ?? CefAXNodeElement(host: host)
                element.nodeID = id
                element.axRole = Self.nsRole(for: role)
                element.axTitle = name
                element.axValue = valueStr
                element.frameInView = frame
                element.childIDs = childIDs
                nodes[id] = element
            }
        }

        // Re-link parent/child and compute roots (nodes referenced by no one).
        var referenced = Set<Int>()
        for (_, el) in nodes {
            el.children = el.childIDs.compactMap { nodes[$0] }
            for el2 in el.children { referenced.insert(el2.nodeID) }
        }
        rootElements = nodes.values
            .filter { !referenced.contains($0.nodeID) }
            .sorted { $0.nodeID < $1.nodeID }

        host.lastMappedAXNodeCount = nodes.count
        // Notify AppKit the children changed.
        NSAccessibility.post(element: host, notification: .layoutChanged)
    }

    /// Updates node frames from a location change without rebuilding the tree.
    func applyLocationChange(_ value: CefAXValue) {
        guard let host, let list = value.list else { return }
        for entry in list {
            guard let dict = entry.dictionary,
                  let id = dict["id"]?.intValue,
                  let node = nodes[id] else { continue }
            node.frameInView = Self.frame(from: dict["new_location"], host: host)
        }
    }

    private static func frame(from location: CefAXValue?, host: CefMetalHostView) -> CGRect {
        guard let loc = location?.dictionary else { return .zero }
        let x = loc["x"]?.doubleValue ?? 0
        let y = loc["y"]?.doubleValue ?? 0
        let w = loc["width"]?.doubleValue ?? 0
        let h = loc["height"]?.doubleValue ?? 0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Maps a subset of Chromium AX roles to AppKit roles. Unmapped roles fall
    /// back to a group so VoiceOver can still traverse them.
    private static func nsRole(for role: String) -> NSAccessibility.Role {
        switch role {
        case "button", "popUpButton", "toggleButton": return .button
        case "link": return .link
        case "staticText", "inlineTextBox", "paragraph": return .staticText
        case "heading": return .staticText
        case "textField", "textFieldWithComboBox", "searchBox": return .textField
        case "checkBox": return .checkBox
        case "radioButton": return .radioButton
        case "image", "img": return .image
        case "list": return .list
        case "listItem", "listMarker": return .row
        case "comboBoxMenuButton", "menuListPopup": return .popUpButton
        default: return .group
        }
    }
}

/// One NSAccessibility proxy element for a CEF AX node.
///
/// AppKit only touches accessibility elements on the main thread, so the stored
/// state is plain (no actor isolation): the bridge mutates it on the main actor
/// and AppKit reads it on the main thread. Marked `@unchecked Sendable` to
/// satisfy the (main-thread-only) NSAccessibility protocol surface.
final class CefAXNodeElement: NSAccessibilityElement, @unchecked Sendable {
    weak var host: CefMetalHostView?
    var nodeID: Int = 0
    var axRole: NSAccessibility.Role = .group
    var axTitle: String = ""
    var axValue: String = ""
    var childIDs: [Int] = []
    var children: [CefAXNodeElement] = []
    /// Node frame in view DIP (top-left origin, as Chromium reports it).
    var frameInView: CGRect = .zero

    init(host: CefMetalHostView) {
        self.host = host
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { axRole }
    override func accessibilityTitle() -> String? { axTitle.isEmpty ? nil : axTitle }
    override func accessibilityValue() -> Any? { axValue.isEmpty ? nil : axValue }
    override func accessibilityChildren() -> [Any]? { children.isEmpty ? nil : children }
    override func accessibilityParent() -> Any? { host }

    override func accessibilityFrame() -> NSRect {
        guard let host, let window = host.window, frameInView != .zero else { return .zero }
        // Convert view DIP (top-left, view is flipped) → window → screen.
        let viewRect = NSRect(x: frameInView.minX, y: frameInView.minY,
                              width: frameInView.width, height: frameInView.height)
        let inWindow = host.convert(viewRect, to: nil)
        return window.convertToScreen(inWindow)
    }
}

private extension CefAXValue {
    var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }
}

// MARK: - Host view AX integration

extension CefMetalHostView {

    // CefOSRHost AX callbacks.
    public func osrAccessibilityTreeDidChange(_ value: CefAXValue) {
        axBridge.applyTreeChange(value)
    }

    public func osrAccessibilityLocationDidChange(_ value: CefAXValue) {
        axBridge.applyLocationChange(value)
    }

    /// Expose the host view as an accessibility group whose children are the
    /// mapped web-content nodes.
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { "Web content" }
    public override func accessibilityChildren() -> [Any]? {
        axBridge.rootElements.isEmpty ? nil : axBridge.rootElements
    }
    public override func isAccessibilityElement() -> Bool { true }
}
