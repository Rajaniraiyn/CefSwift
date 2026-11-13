import CoreGraphics
import Foundation
import Testing

@testable import CefKit

/// The offscreen accessibility model, fed with updates in the shape CEF's
/// `on_accessibility_tree_change` and `on_accessibility_location_change`
/// deliver them (see `osr_accessibility_util.cc`).
@MainActor
struct AccessibilityTreeTests {

    // MARK: Fixtures

    static func node(
        _ id: Int, _ role: String, children: [Int] = [], frame: CGRect = .zero, container: Int? = 1,
        states: [String] = [], attributes: [String: CefJSON] = [:], transform: String? = nil
    ) -> CefJSON {
        var json: [String: CefJSON] = [
            "id": .number(Double(id)),
            "role": .string(role),
            // CEF pads the list with empty strings; the model must ignore them.
            "state": .array((states + ["", ""]).map(CefJSON.string)),
            "location": ["x": .number(frame.minX), "y": .number(frame.minY),
                         "width": .number(frame.width), "height": .number(frame.height)],
            "attributes": .object(attributes),
        ]
        if !children.isEmpty { json["child_ids"] = .array(children.map { .number(Double($0)) }) }
        if let container { json["offset_container_id"] = .number(Double(container)) }
        if let transform { json["transform"] = .string(transform) }
        return .object(json)
    }

    static func change(
        tree: String = "main", root: Int? = nil, clear: Int? = nil, treeData: [String: CefJSON]? = nil,
        nodes: [CefJSON], events: [CefJSON] = []
    ) -> CefJSON {
        var update: [String: CefJSON] = ["nodes": .array(nodes)]
        if let root { update["root_id"] = .number(Double(root)) }
        if let clear { update["node_id_to_clear"] = .number(Double(clear)) }
        if var treeData {
            treeData["tree_id"] = .string(tree)
            update["has_tree_data"] = true
            update["tree_data"] = .object(treeData)
        }
        var value: [String: CefJSON] = ["ax_tree_id": .string(tree), "updates": [.object(update)]]
        if !events.isEmpty { value["events"] = .array(events) }
        return .object(value)
    }

    /// A page: a heading, a button, a text field, an ignored wrapper around a
    /// link, and a polite live region.
    static func page(tree: String = "main") -> CefJSON {
        change(tree: tree, root: 1, treeData: ["focus_id": 1, "loaded": true, "parent_tree_id": ""], nodes: [
            node(1, "rootWebArea", children: [2, 4, 6, 8, 11], frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                 container: nil, states: ["focusable"], attributes: ["name": "Page", "scrollX": 0, "scrollY": 0]),
            node(2, "heading", children: [3], frame: CGRect(x: 16, y: 20, width: 400, height: 60),
                 attributes: ["hierarchicalLevel": 1, "name": "Title", "nameFrom": "contents"]),
            node(3, "staticText", frame: CGRect(x: 16, y: 20, width: 200, height: 60), attributes: ["name": "Title"]),
            node(4, "button", children: [5], frame: CGRect(x: 16, y: 100, width: 160, height: 40),
                 states: ["focusable"], attributes: ["name": "Go", "nameFrom": "contents", "defaultActionVerb": "press"]),
            node(5, "staticText", frame: CGRect(x: 30, y: 105, width: 40, height: 30), attributes: ["name": "Go"]),
            node(6, "textField", children: [7], frame: CGRect(x: 16, y: 160, width: 300, height: 40),
                 states: ["focusable", "editable"],
                 attributes: ["name": "Name", "value": "Ada", "placeholder": "Your name", "textSelStart": 3, "textSelEnd": 3]),
            node(7, "inlineTextBox", frame: CGRect(x: 20, y: 164, width: 30, height: 32),
                 attributes: ["name": "Ada", "characterOffsets": [10, 20, 30]]),
            node(8, "genericContainer", children: [9], frame: CGRect(x: 16, y: 220, width: 300, height: 40),
                 states: ["ignored"]),
            node(9, "link", children: [10], frame: CGRect(x: 16, y: 220, width: 100, height: 40),
                 states: ["focusable", "linked"], attributes: ["name": "More", "url": "https://example.com/more"]),
            node(10, "staticText", frame: CGRect(x: 16, y: 220, width: 100, height: 40), attributes: ["name": "More"]),
            node(11, "genericContainer", children: [12], frame: CGRect(x: 16, y: 280, width: 300, height: 40),
                 attributes: ["liveStatus": "polite", "containerLiveStatus": "polite"]),
            node(12, "staticText", frame: CGRect(x: 16, y: 280, width: 100, height: 40),
                 attributes: ["name": "Idle", "containerLiveStatus": "polite"]),
        ], events: [["event_type": "loadComplete", "id": 1]])
    }

    static func id(_ node: Int32, _ tree: String = "main") -> CefAccessibilityNode.ID {
        .init(tree: tree, node: node)
    }

    // MARK: Building

    @Test func buildsTreeFromFirstUpdate() {
        let tree = CefAccessibilityTree()
        let changes = tree.applyTreeChange(Self.page())
        #expect(tree.mainTreeID == "main")
        #expect(tree.root?.role == "rootWebArea")
        #expect(tree.nodeCount == 12)
        #expect(tree.isLoaded)
        #expect(changes.insertedNodes.count == 12)
        #expect(changes.didFinishLoading)
        #expect(changes.focusDidChange)
        #expect(changes.announcements.isEmpty, "live regions stay quiet while a document loads")
        #expect(tree.node(Self.id(2))?.hierarchicalLevel == 1)
        #expect(tree.node(Self.id(1))?.states == ["focusable"])
        #expect(tree.node(Self.id(6))?.textSelection == NSRange(location: 3, length: 0))
        #expect(tree.node(Self.id(9))?.url?.absoluteString == "https://example.com/more")
    }

    @Test func exposedChildrenSkipIgnoredNodesAndLeafInsides() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        // The ignored wrapper (8) is replaced by the link it holds.
        #expect(tree.children(of: Self.id(1)).map(\.id.node) == [2, 4, 6, 9, 11])
        #expect(tree.children(of: Self.id(2)).map(\.id.node) == [3])
        // Buttons and text fields are leaves.
        #expect(tree.children(of: Self.id(4)).isEmpty)
        #expect(tree.children(of: Self.id(6)).isEmpty)
        #expect(tree.parent(of: Self.id(9))?.id == Self.id(1))
        #expect(tree.parent(of: Self.id(1)) == nil)
        #expect(tree.exposedNode(atOrAbove: Self.id(5))?.id == Self.id(4))
        #expect(tree.exposedNode(atOrAbove: Self.id(8))?.id == Self.id(1))
        #expect(tree.textContent(of: Self.id(1)) == "Title Go More Idle")
    }

    // MARK: Geometry

    @Test func framesHonourScaleScrollAndContainers() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        #expect(tree.frame(of: Self.id(4)) == CGRect(x: 16, y: 100, width: 160, height: 40))
        tree.deviceScaleFactor = 2
        #expect(tree.frame(of: Self.id(4)) == CGRect(x: 8, y: 50, width: 80, height: 20))

        // Scrolling the document moves everything positioned in it.
        let scrolled = tree.applyTreeChange(Self.change(nodes: [
            Self.node(1, "rootWebArea", children: [2, 4, 6, 8, 11], frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      container: nil, states: ["focusable"], attributes: ["name": "Page", "scrollX": 0, "scrollY": 100]),
        ]))
        #expect(scrolled.layoutDidChange)
        #expect(tree.frame(of: Self.id(4)) == CGRect(x: 8, y: 0, width: 80, height: 20))
        #expect(tree.frame(of: Self.id(1)) == CGRect(x: 0, y: 0, width: 400, height: 300), "the root itself does not scroll")
    }

    @Test func nestedContainersAndTransforms() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.change(root: 1, treeData: ["focus_id": 1, "loaded": true], nodes: [
            Self.node(1, "rootWebArea", children: [2], frame: CGRect(x: 0, y: 0, width: 800, height: 600), container: nil),
            Self.node(2, "genericContainer", children: [3], frame: CGRect(x: 100, y: 50, width: 200, height: 200),
                      attributes: ["scrollY": 30]),
            Self.node(3, "button", frame: CGRect(x: 10, y: 40, width: 20, height: 10), container: 2,
                      transform: "[ 2 0 0 5\n  0 2 0 7\n  0 0 1 0\n  0 0 0 1 ]\n"),
        ]))
        // (10,40,20,10) scaled by 2 and moved by (5,7), then offset by the
        // container's origin less its scroll offset.
        #expect(tree.frame(of: Self.id(3)) == CGRect(x: 125, y: 107, width: 40, height: 20))
    }

    @Test func locationChangesMoveNodes() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.applyLocationChanges([
            ["id": 4, "ax_tree_id": "main",
             "new_location": ["offset_container_id": 1, "bounds": ["x": 50, "y": 300, "width": 100, "height": 20]]],
        ])
        #expect(changes.layoutDidChange)
        #expect(tree.frame(of: Self.id(4)) == CGRect(x: 50, y: 300, width: 100, height: 20))
    }

    @Test func hitTestFindsTheDeepestExposedNode() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        #expect(tree.hitTest(CGPoint(x: 40, y: 110))?.id == Self.id(4), "a button, not its text")
        #expect(tree.hitTest(CGPoint(x: 20, y: 230))?.id == Self.id(10), "through the ignored wrapper")
        #expect(tree.hitTest(CGPoint(x: 700, y: 500))?.id == Self.id(1))
        #expect(tree.hitTest(CGPoint(x: 900, y: 900)) == nil)
    }

    @Test func characterRangeFramesComeFromTextRuns() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        #expect(tree.frame(ofCharacterRange: NSRange(location: 1, length: 2), in: Self.id(6))
                == CGRect(x: 30, y: 164, width: 20, height: 32))
        #expect(tree.frame(ofCharacterRange: NSRange(location: 3, length: 0), in: Self.id(6))?.minX == 50)
        #expect(tree.lineIndex(ofCharacterAt: 2, in: Self.id(6)) == 0)
        #expect(tree.frame(ofCharacterRange: NSRange(location: 0, length: 1), in: Self.id(4)) == nil)
    }

    // MARK: Frames

    @Test func childTreesHangUnderTheirIframe() {
        let tree = CefAccessibilityTree()
        // Chromium may send a frame's tree before its parent's.
        tree.applyTreeChange(Self.change(tree: "child", root: 1, treeData: ["focus_id": 1, "loaded": true, "parent_tree_id": "main"], nodes: [
            Self.node(1, "rootWebArea", children: [2], frame: CGRect(x: 0, y: 0, width: 300, height: 80), container: nil),
            Self.node(2, "button", frame: CGRect(x: 5, y: 5, width: 50, height: 20), attributes: ["name": "Inner"]),
        ]))
        #expect(tree.root == nil)
        tree.applyTreeChange(Self.change(root: 1, treeData: ["focus_id": 1, "loaded": true], nodes: [
            Self.node(1, "rootWebArea", children: [2], frame: CGRect(x: 0, y: 0, width: 800, height: 600), container: nil),
            Self.node(2, "iframe", frame: CGRect(x: 10, y: 100, width: 300, height: 80), attributes: ["childTreeId": "child"]),
        ]))
        #expect(tree.children(of: Self.id(2)).map(\.id) == [Self.id(1, "child")])
        #expect(tree.parent(of: Self.id(1, "child"))?.id == Self.id(2))
        #expect(tree.frame(of: Self.id(2, "child")) == CGRect(x: 15, y: 105, width: 50, height: 20))
        #expect(tree.hitTest(CGPoint(x: 20, y: 110))?.id == Self.id(2, "child"))
        #expect(tree.textContent(of: Self.id(1)).isEmpty)

        // Focus inside the frame: the main tree points at the iframe.
        let focus = tree.applyTreeChange(Self.change(treeData: ["focus_id": 2, "loaded": true], nodes: []))
        #expect(focus.focusDidChange && tree.focusedNode?.id == Self.id(1, "child"))
        tree.applyTreeChange(Self.change(tree: "child", treeData: ["focus_id": 2, "loaded": true, "parent_tree_id": "main"], nodes: []))
        #expect(tree.focusedNode?.id == Self.id(2, "child"))

        // A new document in the main frame takes its frames with it.
        let navigated = tree.applyTreeChange(Self.change(tree: "next", root: 1, treeData: ["focus_id": 1, "loaded": true], nodes: [
            Self.node(1, "rootWebArea", frame: CGRect(x: 0, y: 0, width: 800, height: 600), container: nil),
        ]))
        #expect(tree.mainTreeID == "next")
        #expect(tree.nodeCount == 1)
        #expect(navigated.removedNodes == [Self.id(1), Self.id(2), Self.id(1, "child"), Self.id(2, "child")])
    }

    // MARK: Incremental updates

    @Test func incrementalUpdatesReportWhatChanged() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.applyTreeChange(Self.change(treeData: ["focus_id": 6, "loaded": true], nodes: [
            Self.node(6, "textField", children: [7], frame: CGRect(x: 16, y: 160, width: 300, height: 40),
                      states: ["focusable", "editable"],
                      attributes: ["name": "Name", "value": "Adam", "placeholder": "Your name", "textSelStart": 1, "textSelEnd": 4]),
            Self.node(12, "staticText", frame: CGRect(x: 16, y: 280, width: 100, height: 40),
                      attributes: ["name": "Saved", "containerLiveStatus": "polite"]),
        ], events: [["event_type": "focus", "id": 6]]))
        #expect(changes.valueChangedNodes == [Self.id(6), Self.id(12)])
        #expect(changes.selectedTextChangedNodes.contains(Self.id(6)))
        #expect(changes.updatedNodes == [Self.id(6), Self.id(12)])
        #expect(changes.focusDidChange)
        #expect(tree.focusedNode?.id == Self.id(6))
        #expect(changes.announcements == [CefAccessibilityAnnouncement(text: "Saved", isAssertive: false)])
        #expect(changes.events == [CefAccessibilityEvent(type: "focus", node: Self.id(6))])
        #expect(tree.node(Self.id(6))?.textSelection == NSRange(location: 1, length: 3))
    }

    @Test func removedChildrenTakeTheirSubtrees() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.applyTreeChange(Self.change(nodes: [
            Self.node(1, "rootWebArea", children: [2, 6, 11], frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      container: nil, attributes: ["name": "Page"]),
        ]))
        #expect(changes.removedNodes == [Self.id(4), Self.id(5), Self.id(8), Self.id(9), Self.id(10)])
        #expect(changes.layoutDidChange)
        #expect(tree.node(Self.id(5)) == nil)
        #expect(tree.children(of: Self.id(1)).map(\.id.node) == [2, 6, 11])
    }

    @Test func reparentedNodesSurvive() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        // The link moves out of its wrapper, which goes away.
        let changes = tree.applyTreeChange(Self.change(nodes: [
            Self.node(1, "rootWebArea", children: [2, 4, 6, 9, 11], frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      container: nil, attributes: ["name": "Page"]),
        ]))
        #expect(changes.removedNodes == [Self.id(8)])
        #expect(tree.node(Self.id(9))?.parentID == Self.id(1))
        #expect(tree.node(Self.id(10)) != nil)
    }

    @Test func clearingTheRootReplacesTheTree() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.applyTreeChange(Self.change(root: 20, clear: 1, nodes: [
            Self.node(20, "rootWebArea", children: [21], frame: CGRect(x: 0, y: 0, width: 800, height: 600), container: nil),
            Self.node(21, "staticText", frame: CGRect(x: 0, y: 0, width: 10, height: 10), container: 20, attributes: ["name": "New"]),
        ]))
        #expect(changes.removedNodes.count == 12)
        #expect(changes.insertedNodes == [Self.id(20), Self.id(21)])
        #expect(tree.root?.id == Self.id(20))
        #expect(tree.nodeCount == 2)
    }

    @Test func assertiveAtomicRegionsAnnounceAsAWhole() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.change(root: 1, treeData: ["focus_id": 1, "loaded": true], nodes: [
            Self.node(1, "rootWebArea", children: [2], frame: CGRect(x: 0, y: 0, width: 800, height: 600), container: nil),
            Self.node(2, "alert", children: [3, 4], attributes: ["liveStatus": "assertive", "containerLiveStatus": "assertive", "liveAtomic": true]),
            Self.node(3, "staticText", attributes: ["name": "Error:", "containerLiveStatus": "assertive", "containerLiveAtomic": true]),
            Self.node(4, "staticText", attributes: ["name": "old", "containerLiveStatus": "assertive", "containerLiveAtomic": true]),
        ]))
        let changes = tree.applyTreeChange(Self.change(nodes: [
            Self.node(4, "staticText", attributes: ["name": "disk full", "containerLiveStatus": "assertive", "containerLiveAtomic": true]),
        ]))
        #expect(changes.announcements == [CefAccessibilityAnnouncement(text: "Error: disk full", isAssertive: true)])
    }

    @Test func removeAllEmptiesTheTree() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.removeAll()
        #expect(changes.removedNodes.count == 12)
        #expect(tree.isEmpty && tree.nodeCount == 0 && tree.focusedNode == nil)
    }

    @Test func documentScrollReadBackMovesNodes() {
        let tree = CefAccessibilityTree()
        tree.applyTreeChange(Self.page())
        let changes = tree.applyDocumentScroll(CGPoint(x: 0, y: 50))
        #expect(changes.layoutDidChange)
        #expect(tree.frame(of: Self.id(4))?.minY == 50)
        #expect(tree.applyDocumentScroll(CGPoint(x: 0, y: 50)).isEmpty)
    }

    // MARK: Recorded

    @Test func recordedPageFromChromium() throws {
        let tree = CefAccessibilityTree()
        tree.deviceScaleFactor = 2
        for value in try CefJSON(data: Data(AccessibilityFixtures.recordedPage.utf8)).arrayValue ?? [] {
            tree.applyTreeChange(value)
        }
        let root = try #require(tree.root)
        #expect(root.name == "ax")
        #expect(tree.isLoaded)

        func all(_ id: CefAccessibilityNode.ID) -> [CefAccessibilityNode] {
            tree.children(of: id).flatMap { [$0] + all($0.id) }
        }
        let nodes = all(root.id)
        func first(_ role: String, _ name: String? = nil) -> CefAccessibilityNode? {
            nodes.first { $0.role == role && (name == nil || $0.name == name) }
        }
        #expect(first("heading", "Accessible heading")?.hierarchicalLevel == 1)
        #expect(first("link", "Example link")?.url?.fragment == "target")
        #expect(first("textField")?.value == "Ada")
        #expect(first("textField")?.placeholder == "Your name")
        #expect(first("checkBox", "Subscribe")?.checkedState == .checked)
        #expect(first("image", "A red square") != nil)
        #expect(first("list").map { tree.children(of: $0.id).count } == 3)
        #expect(first("navigation", "Site") != nil)

        // Physical pixels at a scale of 2 become points.
        let button = try #require(first("button", "Press me"))
        let frame = try #require(tree.frame(of: button.id))
        #expect(abs(frame.minX - 8) < 0.01 && abs(frame.minY - 106.375) < 0.01 && abs(frame.height - 27) < 0.01)
        #expect(tree.hitTest(CGPoint(x: frame.midX, y: frame.midY))?.id == button.id)

        // The srcdoc iframe's tree hangs under the iframe and sits inside it.
        let iframe = try #require(first("iframe"))
        let inner = try #require(first("button", "Inner button"))
        #expect(inner.id.tree != tree.mainTreeID)
        #expect(tree.parent(of: tree.parent(of: inner.id)?.id ?? inner.id)?.id != nil)
        let iframeFrame = try #require(tree.frame(of: iframe.id))
        let innerFrame = try #require(tree.frame(of: inner.id))
        #expect(iframeFrame.contains(innerFrame))
        #expect(abs(innerFrame.minX - (iframeFrame.minX + 8)) < 0.01)
    }

    @Test func foundationObjectsConvert() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":2.5,"d":"x","e":[false,null]}"#.utf8))
        #expect(CefJSON(foundationValue: object) == ["a": true, "b": 1, "c": 2.5, "d": "x", "e": [false, nil]])
    }

    @Test func transformStrings() {
        #expect(CefAccessibilityNode.parseTransform("[ 1 0 0 0\n 0 1 0 0\n 0 0 1 0\n 0 0 0 1 ]") == nil)
        #expect(CefAccessibilityNode.parseTransform("[ 1 0 0 -4.5\n 0 1 0 2e1\n 0 0 1 0\n 0 0 0 1 ]")
                == CGAffineTransform(translationX: -4.5, y: 20))
        #expect(CefAccessibilityNode.parseTransform("garbage") == nil)
    }
}
