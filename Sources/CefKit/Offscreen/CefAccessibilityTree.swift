import CoreGraphics
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
    public var announcements: [CefAccessibilityAnnouncement] = []
    /// Chromium's own events, such as `"focus"`, `"loadComplete"` or
    /// `"valueChanged"`, in the order they arrived.
    public var events: [CefAccessibilityEvent] = []

    /// Creates an empty set of changes.
    public init() {}

    /// Whether nothing changed.
    public var isEmpty: Bool { self == CefAccessibilityChanges() }
}

/// Text a live region asks assistive technology to announce.
public struct CefAccessibilityAnnouncement: Sendable, Equatable {
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

/// An event Chromium reported with an accessibility update.
public struct CefAccessibilityEvent: Sendable, Equatable {
    /// Chromium's event name, such as `"focus"` or `"loadComplete"`.
    public var type: String
    /// The node the event is about.
    public var node: CefAccessibilityNode.ID?
}

/// The accessibility tree of an offscreen browser's page, kept up to date
/// from the updates Chromium sends while
/// ``CefBrowser/isAccessibilityEnabled`` is on.
///
/// Chromium keeps one tree per frame; this object joins them, so that an
/// `<iframe>` node's children are the root of its frame's tree. Two views
/// of the tree are offered: the raw nodes Chromium sent (``node(_:)``,
/// ``CefAccessibilityNode/childIDs``), and the platform view a screen reader
/// should see (``children(of:)``, ``parent(of:)``), which skips ignored nodes
/// and the insides of leaves such as buttons and text fields.
///
/// Frames are in the host view's points with a top-left origin, like every
/// other offscreen coordinate.
@MainActor
public final class CefAccessibilityTree {
    /// One frame's tree.
    struct FrameTree {
        var nodes: [Int32: CefAccessibilityNode] = [:]
        var rootID: Int32?
        var parentTreeID: String?
        var focusID: Int32?
        var focusedTreeID: String?
        var isLoaded = false
        var selection: [String: CefJSON] = [:]
    }

    private(set) var trees: [String: FrameTree] = [:]
    /// The tree of the main frame's document.
    public private(set) var mainTreeID: String?

    /// The ratio of Chromium's pixels to the host view's points. The browser
    /// keeps it in step with its host.
    public internal(set) var deviceScaleFactor: CGFloat = 1 {
        didSet { if deviceScaleFactor != oldValue { frameCache = [:] } }
    }

    private var frameCache: [CefAccessibilityNode.ID: CGRect] = [:]
    /// The `<iframe>` node hosting each child tree.
    private var hosts: [String: CefAccessibilityNode.ID] = [:]

    init() {}

    // MARK: Reading

    /// Whether the tree has a root yet.
    public var isEmpty: Bool { root == nil }

    /// The root of the main frame's document, a `rootWebArea` node.
    public var root: CefAccessibilityNode? {
        guard let mainTreeID, let tree = trees[mainTreeID], let rootID = tree.rootID else { return nil }
        return tree.nodes[rootID]
    }

    /// The node with identifier `id`, if it is in the tree.
    public func node(_ id: CefAccessibilityNode.ID) -> CefAccessibilityNode? {
        trees[id.tree]?.nodes[id.node]
    }

    /// The number of nodes, ignored ones included, across all frames.
    public var nodeCount: Int { trees.values.reduce(0) { $0 + $1.nodes.count } }

    /// Whether the main frame's document has finished loading.
    public var isLoaded: Bool { mainTreeID.flatMap { trees[$0]?.isLoaded } ?? false }

    /// The node with keyboard focus, descending into focused frames. Ignored
    /// nodes resolve to their nearest exposed ancestor.
    public var focusedNode: CefAccessibilityNode? {
        guard let mainTreeID, let main = trees[mainTreeID] else { return nil }
        var treeID = mainTreeID
        if let focusedTree = main.focusedTreeID, trees[focusedTree] != nil { treeID = focusedTree }
        guard let tree = trees[treeID], let focus = tree.focusID ?? tree.rootID else { return nil }
        var id = CefAccessibilityNode.ID(tree: treeID, node: focus)
        var visited = Set<String>()
        while let current = node(id), let childTree = current.childTreeID, visited.insert(childTree).inserted,
              let child = trees[childTree], let next = child.focusID ?? child.rootID {
            id = .init(tree: childTree, node: next)
        }
        return exposedNode(atOrAbove: id)
    }

    /// The children a screen reader sees: ignored nodes are replaced by
    /// their own children, an `<iframe>`'s child is its frame's root, and
    /// leaves (text, images, buttons, plain text fields and the like) have
    /// none.
    public func children(of id: CefAccessibilityNode.ID) -> [CefAccessibilityNode] {
        guard let node = node(id), !isLeaf(node) else { return [] }
        var result: [CefAccessibilityNode] = []
        appendExposedChildren(of: node, to: &result, depth: 0)
        return result
    }

    /// The nearest exposed ancestor, crossing out of a frame into the
    /// `<iframe>` node that hosts it; `nil` for the main root.
    public func parent(of id: CefAccessibilityNode.ID) -> CefAccessibilityNode? {
        var current = rawParent(of: id)
        while let candidate = current {
            if !candidate.isIgnored { return candidate }
            current = rawParent(of: candidate.id)
        }
        return nil
    }

    /// Whether a screen reader sees the node: it is not ignored and no
    /// ancestor is a leaf.
    public func isExposed(_ id: CefAccessibilityNode.ID) -> Bool {
        guard let node = node(id), !node.isIgnored else { return false }
        var current = rawParent(of: id)
        while let ancestor = current {
            if !ancestor.isIgnored, isLeaf(ancestor) { return false }
            current = rawParent(of: ancestor.id)
        }
        return node.id.tree == mainTreeID || hosts[node.id.tree] != nil
    }

    /// The node itself if a screen reader sees it, else its nearest exposed
    /// ancestor.
    public func exposedNode(atOrAbove id: CefAccessibilityNode.ID) -> CefAccessibilityNode? {
        var candidate = node(id)
        var lastLeaf: CefAccessibilityNode?
        var current = candidate
        // A node inside a leaf resolves to the outermost leaf above it.
        while let ancestor = current {
            if !ancestor.isIgnored, isLeaf(ancestor), ancestor.id != id { lastLeaf = ancestor }
            current = rawParent(of: ancestor.id)
        }
        if let lastLeaf { return lastLeaf }
        while let node = candidate, node.isIgnored {
            candidate = rawParent(of: node.id)
        }
        return candidate
    }

    /// The node's frame in the host view's points, top-left origin.
    public func frame(of id: CefAccessibilityNode.ID) -> CGRect? {
        guard let pixels = pixelFrame(of: id) else { return nil }
        let scale = deviceScaleFactor > 0 ? deviceScaleFactor : 1
        return CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
    }

    /// The deepest exposed node whose frame contains `point`, in view
    /// points; later siblings, which paint on top, win.
    public func hitTest(_ point: CGPoint) -> CefAccessibilityNode? {
        guard let root else { return nil }
        return hitTest(point, in: root, depth: 0) ?? (frame(of: root.id)?.contains(point) == true ? root : nil)
    }

    /// The text of a node and its descendants: the names of its text runs,
    /// joined by spaces.
    public func textContent(of id: CefAccessibilityNode.ID) -> String {
        var parts: [String] = []
        collectText(id, into: &parts, depth: 0)
        return parts.joined(separator: " ")
    }

    // MARK: Text ranges

    /// The text runs (`inlineTextBox` nodes) under a node, in order, with
    /// the UTF-16 offset each starts at.
    private func textRuns(under id: CefAccessibilityNode.ID) -> [(node: CefAccessibilityNode, start: Int)] {
        var runs: [(CefAccessibilityNode, Int)] = []
        var offset = 0
        func walk(_ id: CefAccessibilityNode.ID, depth: Int) {
            guard depth < 64, let node = node(id) else { return }
            if node.role == "inlineTextBox" {
                runs.append((node, offset))
                offset += (node.name ?? "").utf16.count
                return
            }
            for child in node.childIDs { walk(child, depth: depth + 1) }
        }
        walk(id, depth: 0)
        return runs
    }

    /// The frame, in view points, of a range of a text field's or text
    /// node's characters, from the positions Chromium reports for its text
    /// runs. `nil` when Chromium sent no text runs for the node.
    public func frame(ofCharacterRange range: NSRange, in id: CefAccessibilityNode.ID) -> CGRect? {
        let runs = textRuns(under: id)
        guard !runs.isEmpty else { return nil }
        let scale = deviceScaleFactor > 0 ? deviceScaleFactor : 1
        var union: CGRect?
        for (run, start) in runs {
            let length = (run.name ?? "").utf16.count
            let lower = max(range.location, start)
            let upper = min(range.location + max(range.length, 0), start + length)
            // An empty range is the caret: place it before the character.
            let isCaret = range.length == 0 && range.location >= start && range.location <= start + length
            guard lower < upper || isCaret, let box = pixelFrame(of: run.id) else { continue }
            let offsets = run.characterOffsets
            func position(_ index: Int) -> CGFloat {
                guard index > 0 else { return 0 }
                return offsets.indices.contains(index - 1) ? CGFloat(offsets[index - 1]) : box.width
            }
            let localLower = (isCaret ? range.location : lower) - start
            let localUpper = isCaret ? localLower : upper - start
            let vertical = run.string("textDirection") == "ttb" || run.string("textDirection") == "btt"
            let rtl = run.string("textDirection") == "rtl"
            var rect: CGRect
            if vertical {
                rect = CGRect(x: box.minX, y: box.minY + position(localLower), width: box.width,
                              height: max(position(localUpper) - position(localLower), isCaret ? 1 : 0))
            } else if rtl {
                rect = CGRect(x: box.maxX - position(localUpper), y: box.minY,
                              width: max(position(localUpper) - position(localLower), isCaret ? 1 : 0), height: box.height)
            } else {
                rect = CGRect(x: box.minX + position(localLower), y: box.minY,
                              width: max(position(localUpper) - position(localLower), isCaret ? 1 : 0), height: box.height)
            }
            rect = CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
            union = union.map { $0.union(rect) } ?? rect
            if isCaret { break }
        }
        return union
    }

    /// The zero-based line holding the character at `offset` of a text
    /// field or text node, from the positions of its text runs, or from its
    /// line breaks when Chromium sent no runs.
    public func lineIndex(ofCharacterAt offset: Int, in id: CefAccessibilityNode.ID) -> Int? {
        let runs = textRuns(under: id)
        guard !runs.isEmpty else {
            guard let text = node(id)?.value ?? node(id)?.name else { return nil }
            let prefix = (text as NSString).substring(to: min(max(offset, 0), (text as NSString).length))
            return prefix.filter { $0 == "\n" }.count
        }
        var line = 0
        var lastTop: CGFloat?
        for (run, start) in runs {
            if let box = pixelFrame(of: run.id) {
                if let top = lastTop, abs(box.minY - top) > box.height / 2 { line += 1 }
                lastTop = box.minY
            }
            if offset < start + (run.name ?? "").utf16.count { return line }
        }
        return line
    }

    // MARK: Updates

    /// Applies an `on_accessibility_tree_change` value: a dictionary with
    /// `ax_tree_id`, `updates` (serialized `AXTreeUpdate`s) and `events`.
    @discardableResult
    func applyTreeChange(_ value: CefJSON) -> CefAccessibilityChanges {
        let focusBefore = focusedNode?.id
        var changes = CefAccessibilityChanges()
        let treeID = value["ax_tree_id"].stringValue
            ?? value["updates"][0]["tree_data"]["tree_id"].stringValue
            ?? mainTreeID
            ?? ""
        for update in value["updates"].arrayValue ?? [] {
            apply(update: update, treeID: update["tree_data"]["tree_id"].stringValue ?? treeID, changes: &changes)
        }
        for event in value["events"].arrayValue ?? [] {
            guard let type = event["event_type"].stringValue else { continue }
            let node = event["id"].intValue.map { CefAccessibilityNode.ID(tree: treeID, node: Int32(truncatingIfNeeded: $0)) }
            changes.events.append(CefAccessibilityEvent(type: type, node: node))
            switch type {
            case "loadComplete" where treeID == mainTreeID:
                changes.didFinishLoading = true
            default:
                break
            }
        }
        frameCache = [:]
        if focusedNode?.id != focusBefore { changes.focusDidChange = true }
        if !changes.insertedNodes.isEmpty || !changes.removedNodes.isEmpty { changes.layoutDidChange = true }
        return changes
    }

    /// Applies an `on_accessibility_location_change` value: a list of
    /// `{id, ax_tree_id, new_location}` dictionaries.
    @discardableResult
    func applyLocationChanges(_ value: CefJSON) -> CefAccessibilityChanges {
        var changes = CefAccessibilityChanges()
        for change in value.arrayValue ?? [] {
            guard let number = change["id"].intValue,
                  let treeID = change["ax_tree_id"].stringValue ?? mainTreeID,
                  var node = trees[treeID]?.nodes[Int32(truncatingIfNeeded: number)]
            else { continue }
            let location = change["new_location"]
            node.applyLocation(
                bounds: location["bounds"],
                offsetContainer: location["offset_container_id"].intValue,
                transform: location["transform"].stringValue)
            trees[treeID]?.nodes[node.id.node] = node
            changes.layoutDidChange = true
        }
        if changes.layoutDidChange { frameCache = [:] }
        return changes
    }

    /// Applies the main document's scroll position, in Chromium's pixels.
    /// Chromium's scroll updates do not reach CEF's accessibility handler,
    /// so the browser passes on what the render handler reports.
    @discardableResult
    func applyDocumentScroll(_ offset: CGPoint) -> CefAccessibilityChanges {
        var changes = CefAccessibilityChanges()
        guard let mainTreeID, var tree = trees[mainTreeID], let rootID = tree.rootID, var root = tree.nodes[rootID]
        else { return changes }
        let x = offset.x.rounded()
        let y = offset.y.rounded()
        guard root.attributes["scrollX"]?.doubleValue != x || root.attributes["scrollY"]?.doubleValue != y else { return changes }
        root.attributes["scrollX"] = .number(x)
        root.attributes["scrollY"] = .number(y)
        tree.nodes[rootID] = root
        trees[mainTreeID] = tree
        frameCache = [:]
        changes.layoutDidChange = true
        return changes
    }

    /// Forgets every node, as when accessibility is turned off or the
    /// browser closes.
    @discardableResult
    func removeAll() -> CefAccessibilityChanges {
        var changes = CefAccessibilityChanges()
        for tree in trees.values {
            for id in tree.nodes.values.map(\.id) { changes.removedNodes.insert(id) }
        }
        changes.layoutDidChange = !changes.removedNodes.isEmpty
        changes.focusDidChange = focusedNode != nil
        trees = [:]
        hosts = [:]
        mainTreeID = nil
        frameCache = [:]
        return changes
    }

    private func apply(update: CefJSON, treeID: String, changes: inout CefAccessibilityChanges) {
        var tree = trees[treeID] ?? FrameTree()
        let wasEmpty = tree.nodes.isEmpty

        if update["has_tree_data"].boolValue == true || update["tree_data"].objectValue != nil {
            let data = update["tree_data"]
            tree.parentTreeID = data["parent_tree_id"].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            tree.focusedTreeID = data["focused_tree_id"].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            tree.focusID = data["focus_id"].intValue.map { Int32(truncatingIfNeeded: $0) }
            let loaded = data["loaded"].boolValue ?? false
            if loaded, !tree.isLoaded, !wasEmpty || tree.rootID != nil { changes.didFinishLoading = true }
            tree.isLoaded = loaded
            var selection: [String: CefJSON] = [:]
            for key in ["sel_anchor_object_id", "sel_anchor_offset", "sel_focus_object_id", "sel_focus_offset"] {
                selection[key] = data[key]
            }
            if selection != tree.selection, let focus = tree.focusID {
                changes.selectedTextChangedNodes.insert(.init(tree: treeID, node: focus))
            }
            tree.selection = selection
        }

        var removedHere: [CefAccessibilityNode] = []
        func remove(_ number: Int32, keeping keep: Set<Int32>) {
            guard !keep.contains(number), let node = tree.nodes.removeValue(forKey: number) else { return }
            removedHere.append(node)
            for child in node.childIDs { remove(child.node, keeping: keep) }
        }

        if let clear = update["node_id_to_clear"].intValue.map({ Int32(truncatingIfNeeded: $0) }), clear != 0 {
            if clear == tree.rootID {
                for number in Array(tree.nodes.keys) { remove(number, keeping: []) }
                tree.rootID = nil
            } else if let node = tree.nodes[clear] {
                for child in node.childIDs { remove(child.node, keeping: []) }
                tree.nodes[clear]?.childIDs = []
            }
        }

        let incoming = (update["nodes"].arrayValue ?? []).compactMap { CefAccessibilityNode(json: $0, tree: treeID) }
        let referenced = Set(incoming.flatMap { $0.childIDs.map(\.node) })
        var orphans: [Int32] = []
        var pendingAnnouncements: [CefAccessibilityNode] = []

        for var node in incoming {
            let old = tree.nodes[node.id.node]
            node.parentID = old?.parentID
            if let old {
                orphans.append(contentsOf: old.childIDs.map(\.node).filter { !referenced.contains($0) && $0 != node.id.node })
                if !Self.sameContent(old, node) { changes.updatedNodes.insert(node.id) }
                if Self.valueSignature(old) != Self.valueSignature(node) { changes.valueChangedNodes.insert(node.id) }
                if old.textSelection != node.textSelection { changes.selectedTextChangedNodes.insert(node.id) }
                if old.isSelected != node.isSelected, let parent = node.parentID {
                    changes.selectedChildrenChangedNodes.insert(parent)
                }
                if old.relativeBounds != node.relativeBounds || old.scrollOffset != node.scrollOffset {
                    changes.layoutDidChange = true
                }
                if node.role == "staticText", old.name != node.name, node.liveStatus != nil {
                    pendingAnnouncements.append(node)
                }
                if let previousChild = old.childTreeID, previousChild != node.childTreeID {
                    removeTree(previousChild, changes: &changes)
                }
            } else {
                changes.insertedNodes.insert(node.id)
                if node.role == "staticText", node.liveStatus != nil { pendingAnnouncements.append(node) }
            }
            if let childTree = node.childTreeID { hosts[childTree] = node.id }
            tree.nodes[node.id.node] = node
        }
        for node in incoming {
            for child in node.childIDs {
                tree.nodes[child.node]?.parentID = node.id
            }
        }
        if let newRoot = update["root_id"].intValue.map({ Int32(truncatingIfNeeded: $0) }) {
            if newRoot != tree.rootID {
                if let oldRoot = tree.rootID { remove(oldRoot, keeping: referenced.union([newRoot])) }
                tree.rootID = newRoot
            }
            tree.nodes[newRoot]?.parentID = nil
        } else if tree.rootID == nil, let first = incoming.first {
            tree.rootID = first.id.node
        }
        for orphan in orphans {
            remove(orphan, keeping: referenced)
        }

        for node in removedHere {
            changes.removedNodes.insert(node.id)
            changes.insertedNodes.remove(node.id)
            changes.updatedNodes.remove(node.id)
            changes.valueChangedNodes.remove(node.id)
            changes.selectedTextChangedNodes.remove(node.id)
            if let childTree = node.childTreeID, hosts[childTree] == node.id {
                trees[treeID] = tree
                removeTree(childTree, changes: &changes)
                tree = trees[treeID] ?? tree
            }
        }
        trees[treeID] = tree

        // The main frame's tree is the one without a parent; a new one means
        // a new document, and the frames of the old one go with it.
        if tree.parentTreeID == nil, mainTreeID != treeID,
           let rootID = tree.rootID, tree.nodes[rootID]?.role == "rootWebArea" {
            if let old = mainTreeID { removeTree(old, changes: &changes) }
            mainTreeID = treeID
            changes.focusDidChange = true
        }

        // Live regions do not announce what a document loads with.
        if !wasEmpty {
            announce(pendingAnnouncements, changes: &changes)
        }
    }

    /// Removes a frame's tree and the trees of its frames.
    private func removeTree(_ treeID: String, changes: inout CefAccessibilityChanges) {
        guard let tree = trees.removeValue(forKey: treeID) else { return }
        for node in tree.nodes.values {
            changes.removedNodes.insert(node.id)
            changes.insertedNodes.remove(node.id)
            changes.updatedNodes.remove(node.id)
        }
        hosts[treeID] = nil
        if mainTreeID == treeID { mainTreeID = nil }
        let children = trees.filter { $0.value.parentTreeID == treeID }.map(\.key)
        for child in children { removeTree(child, changes: &changes) }
    }

    private func announce(_ nodes: [CefAccessibilityNode], changes: inout CefAccessibilityChanges) {
        var regions: [(root: CefAccessibilityNode.ID, texts: [String], assertive: Bool, atomic: Bool)] = []
        for node in nodes {
            guard let current = self.node(node.id), let status = current.liveStatus, let text = current.name,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            var liveRoot = current
            var walker: CefAccessibilityNode? = current
            while let candidate = walker {
                if candidate.isLiveRoot { liveRoot = candidate; break }
                walker = rawParent(of: candidate.id)
            }
            if liveRoot.isBusy { continue }
            if let index = regions.firstIndex(where: { $0.root == liveRoot.id }) {
                regions[index].texts.append(text)
            } else {
                regions.append((liveRoot.id, [text], status == "assertive", current.isLiveAtomic))
            }
        }
        for region in regions {
            let text = region.atomic ? textContent(of: region.root) : region.texts.joined(separator: " ")
            changes.announcements.append(CefAccessibilityAnnouncement(text: text, isAssertive: region.assertive))
        }
    }

    // MARK: Helpers

    /// Whether two versions of a node differ in anything but position.
    private static func sameContent(_ a: CefAccessibilityNode, _ b: CefAccessibilityNode) -> Bool {
        a.role == b.role && a.states == b.states && a.attributes == b.attributes
            && a.actions == b.actions && a.childIDs == b.childIDs
    }

    private static func valueSignature(_ node: CefAccessibilityNode) -> [CefJSON?] {
        [node.attributes["value"], node.attributes["valueForRange"], node.attributes["checkedState"],
         node.role == "staticText" ? node.attributes["name"] : nil]
    }

    /// The raw parent, crossing from a frame's root to its host.
    func rawParent(of id: CefAccessibilityNode.ID) -> CefAccessibilityNode? {
        guard let node = node(id) else { return nil }
        if let parent = node.parentID { return self.node(parent) }
        guard let host = hosts[id.tree], self.node(host)?.childTreeID == id.tree else { return nil }
        return self.node(host)
    }

    /// Roles whose descendants a screen reader does not see separately.
    private static let leafRoles: Set<String> = [
        "staticText", "inlineTextBox", "lineBreak", "image", "button", "checkBox", "radioButton", "switch",
        "toggleButton", "slider", "progressIndicator", "meter", "scrollBar", "splitter", "listMarker",
        "comboBoxSelect", "popUpButton", "comboBoxMenuButton", "colorWell", "menuListOption", "spinButton",
        "date", "dateTime", "inputTime",
    ]
    private static let atomicTextRoles: Set<String> = ["textField", "searchBox", "textFieldWithComboBox"]

    func isLeaf(_ node: CefAccessibilityNode) -> Bool {
        if node.childTreeID != nil { return false }
        if Self.leafRoles.contains(node.role) { return true }
        if Self.atomicTextRoles.contains(node.role) { return !node.isRichlyEditable }
        return false
    }

    private func appendExposedChildren(of node: CefAccessibilityNode, to result: inout [CefAccessibilityNode], depth: Int) {
        guard depth < 256 else { return }
        if let childTree = node.childTreeID, let tree = trees[childTree], let rootID = tree.rootID,
           let root = tree.nodes[rootID] {
            if root.isIgnored { appendExposedChildren(of: root, to: &result, depth: depth + 1) } else { result.append(root) }
            return
        }
        for childID in node.childIDs {
            guard let child = self.node(childID) else { continue }
            if child.isIgnored {
                appendExposedChildren(of: child, to: &result, depth: depth + 1)
            } else {
                result.append(child)
            }
        }
    }

    private func hitTest(_ point: CGPoint, in node: CefAccessibilityNode, depth: Int) -> CefAccessibilityNode? {
        guard depth < 256 else { return nil }
        for child in children(of: node.id).reversed() {
            if let hit = hitTest(point, in: child, depth: depth + 1) { return hit }
        }
        guard let frame = frame(of: node.id), frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
        return node
    }

    private func collectText(_ id: CefAccessibilityNode.ID, into parts: inout [String], depth: Int) {
        guard depth < 256, let node = node(id) else { return }
        if node.role == "staticText" {
            if let name = node.name { parts.append(name) }
            return
        }
        if let childTree = node.childTreeID, let rootID = trees[childTree]?.rootID {
            collectText(.init(tree: childTree, node: rootID), into: &parts, depth: depth + 1)
        }
        for child in node.childIDs { collectText(child, into: &parts, depth: depth + 1) }
    }

    /// The node's bounds in its frame's coordinates, offset into the main
    /// frame's, in Chromium's pixels.
    private func pixelFrame(of id: CefAccessibilityNode.ID) -> CGRect? {
        if let cached = frameCache[id] { return cached }
        guard let tree = trees[id.tree], let node = tree.nodes[id.node] else { return nil }
        var bounds = node.relativeBounds
        var current = node
        var steps = 0
        while steps < 512 {
            steps += 1
            if let transform = current.transform { bounds = bounds.applying(transform) }
            let containerNumber = current.offsetContainer?.node ?? (current.id.node == tree.rootID ? nil : tree.rootID)
            guard let containerNumber, containerNumber != current.id.node,
                  let container = tree.nodes[containerNumber]
            else { break }
            bounds.origin.x += container.relativeBounds.minX
            bounds.origin.y += container.relativeBounds.minY
            if let scroll = container.scrollOffset {
                bounds.origin.x -= scroll.x
                bounds.origin.y -= scroll.y
            }
            current = container
        }
        // A frame's tree is positioned inside the `<iframe>` hosting it.
        if id.tree != mainTreeID, let host = hosts[id.tree], host.tree != id.tree, let hostFrame = pixelFrame(of: host) {
            bounds.origin.x += hostFrame.minX
            bounds.origin.y += hostFrame.minY
        }
        frameCache[id] = bounds
        return bounds
    }
}
