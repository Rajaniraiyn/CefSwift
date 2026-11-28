import CoreGraphics
import Foundation
import Testing

@testable import CefKit

/// Typed DevTools Protocol commands: what they send and how their replies
/// decode, without Chromium.
@MainActor
struct DevToolsCommandTests {
    private func parameters(_ command: some CefDevToolsCommand) throws -> CefJSON {
        try CefJSON(data: JSONEncoder().encode(command))
    }

    @Test func messagesSpliceEncodedParameters() throws {
        let message = CefDevTools.message(id: 7, method: "Input.insertText", encodedParams: Data(#"{"text":"a\"b"}"#.utf8))
        let json = try CefJSON(data: message)
        #expect(json["id"].intValue == 7)
        #expect(json["method"].stringValue == "Input.insertText")
        #expect(json["params"]["text"].stringValue == "a\"b")
        // A method name is escaped like any JSON string.
        let odd = try CefJSON(data: CefDevTools.message(id: 1, method: "A.\"b", encodedParams: Data("{}".utf8)))
        #expect(odd["method"].stringValue == "A.\"b")
    }

    @Test func nilParametersAreLeftOut() throws {
        #expect(try parameters(CefDevTools.Page.CaptureScreenshot()) == [:])
        #expect(try parameters(CefDevTools.Accessibility.GetFullAXTree()) == [:])
        #expect(try parameters(CefDevTools.Accessibility.GetFullAXTree(depth: 2, frameID: "F")) == ["depth": 2, "frameId": "F"])
    }

    @Test func screenshotParametersUseTheProtocolsNames() throws {
        let command = CefDevTools.Page.CaptureScreenshot(
            format: .jpeg, quality: 60, clip: (CGRect(x: 1, y: 2, width: 30, height: 40), 0.5),
            capturesBeyondViewport: true, optimizesForSpeed: false)
        #expect(try parameters(command) == [
            "format": "jpeg", "quality": 60,
            "clip": ["x": 1, "y": 2, "width": 30, "height": 40, "scale": 0.5],
            "captureBeyondViewport": true, "optimizeForSpeed": false,
        ])
    }

    @Test func mouseEvents() throws {
        let click = CefDevTools.Input.DispatchMouseEvent(
            .pressed, at: CGPoint(x: 10, y: 20.5), button: .left, clickCount: 2, modifiers: [.shift, .command])
        #expect(try parameters(click) == [
            "type": "mousePressed", "x": 10, "y": 20.5, "button": "left", "clickCount": 2, "modifiers": 12,
        ])
        // Chromium refuses a wheel event without both deltas.
        let wheel = CefDevTools.Input.DispatchMouseEvent(.wheel, at: .zero)
        #expect(try parameters(wheel) == ["type": "mouseWheel", "x": 0, "y": 0, "deltaX": 0, "deltaY": 0])
        let scroll = CefDevTools.Input.DispatchMouseEvent(.wheel, at: .zero, scrollDelta: CGVector(dx: 0, dy: -40))
        #expect(try parameters(scroll)["deltaY"] == -40)
    }

    @Test func keyEvents() throws {
        let key = CefDevTools.Input.DispatchKeyEvent(
            .rawKeyDown, key: "a", code: "KeyA", windowsVirtualKeyCode: 65, modifiers: .command, commands: ["selectAll"])
        #expect(try parameters(key) == [
            "type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "modifiers": 4,
            "commands": ["selectAll"],
        ])
        #expect(try parameters(CefDevTools.Input.InsertText("héllo")) == ["text": "héllo"])
    }

    @Test func resultsDecodeFromTheReplysBytes() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let reply = CefDevTools.Reply(succeeded: true, result: Data(#"{"data":"\#(png.base64EncodedString())"}"#.utf8))
        let result = try CefDevTools.decode(CefDevTools.Page.CaptureScreenshot.Result.self, from: reply, for: "Page.captureScreenshot")
        #expect(result.data == png)
        let empty = CefDevTools.Reply(succeeded: true, result: Data("{}".utf8))
        #expect(try CefDevTools.decode(CefDevTools.NoResult.self, from: empty, for: "Input.insertText") == CefDevTools.NoResult())
    }

    @Test func errorRepliesThrowTheProtocolsError() {
        let reply = CefDevTools.Reply(succeeded: false, result: Data(#"{"code":-32602,"message":"Invalid parameters"}"#.utf8))
        #expect(throws: CefDevToolsError(method: "Input.dispatchMouseEvent", code: -32602, message: "Invalid parameters")) {
            try CefDevTools.decode(CefDevTools.NoResult.self, from: reply, for: "Input.dispatchMouseEvent")
        }
    }

    @Test func accessibilityNodesKeepTheValuesOfAXValues() throws {
        let json = #"""
        {"nodes":[
          {"nodeId":"1","ignored":false,"role":{"type":"role","value":"RootWebArea"},"name":{"type":"computedString","value":"probe"},"childIds":["2"],"backendDOMNodeId":3},
          {"nodeId":"2","ignored":true,"parentId":"1"},
          {"nodeId":"5","ignored":false,"role":{"type":"role","value":"textbox"},"value":{"type":"string","value":"typed"}}
        ]}
        """#
        let tree = try JSONDecoder().decode(CefDevTools.Accessibility.GetFullAXTree.Result.self, from: Data(json.utf8))
        #expect(tree.nodes.map(\.id) == ["1", "2", "5"])
        #expect(tree.nodes[0] == CefDevTools.Accessibility.Node(
            id: "1", role: "RootWebArea", name: "probe", childIDs: ["2"], backendDOMNodeID: 3))
        #expect(tree.nodes[1].isIgnored && tree.nodes[1].parentID == "1" && tree.nodes[1].role == nil)
        #expect(tree.nodes[2].value == "typed")
    }

    @Test func domSnapshotsDecodeTheirTables() throws {
        let json = #"""
        {"documents":[{"documentURL":0,"title":1,"frameId":2,"baseURL":0,"contentLanguage":-1,"encodingName":-1,
          "publicId":-1,"systemId":-1,"scrollOffsetX":0,"scrollOffsetY":0,
          "nodes":{"parentIndex":[-1,0],"nodeType":[9,1],"nodeName":[3,4],"nodeValue":[-1,-1],"backendNodeId":[10,11],
                   "attributes":[[],[5,6]],"isClickable":{"index":[1]}},
          "layout":{"nodeIndex":[1],"bounds":[[100,80,120,40]],"text":[-1],"styles":[[7]],"stackingContexts":{"index":[]}},
          "textBoxes":{"layoutIndex":[],"bounds":[],"start":[],"length":[]}}],
         "strings":["https://probe.test/","probe","F1","#document","BUTTON","id","go","inline-block"]}
        """#
        let snapshot = try JSONDecoder().decode(CefDevTools.DOMSnapshot.CaptureSnapshot.Result.self, from: Data(json.utf8))
        let document = try #require(snapshot.documents.first)
        #expect(snapshot.string(document.url) == "https://probe.test/")
        #expect(snapshot.string(-1) == nil && snapshot.string(99) == nil)
        #expect(document.nodes.nodeName.map { snapshot.string($0) } == ["#document", "BUTTON"])
        #expect(document.nodes.clickableNodes == [1] && document.nodes.backendNodeID == [10, 11])
        #expect(document.nodes.attributes[1].map { snapshot.string($0) } == ["id", "go"])
        #expect(document.layout.bounds == [CGRect(x: 100, y: 80, width: 120, height: 40)])
        #expect(document.layout.styles == [[7]])
    }

    private struct ConsoleCalled: CefDevToolsEvent {
        static let method = "Runtime.consoleAPICalled"
        var type: String
    }

    @Test func typedEventsDecodeAndEndWithThePage() async {
        let page = CefPage()
        let typed = page.devTools.events(ConsoleCalled.self, bufferingPolicy: .unbounded)
        let untyped = page.devTools.events("Runtime.consoleAPICalled", bufferingPolicy: .unbounded)
        page.devTools.received(event: "Runtime.consoleAPICalled", params: Data(#"{"type":"log","args":[]}"#.utf8))
        // An event that does not decode is dropped from the typed stream only.
        page.devTools.received(event: "Runtime.consoleAPICalled", params: Data(#"{"args":[]}"#.utf8))
        page.devTools.received(event: "Runtime.consoleAPICalled", params: Data(#"{"type":"warning"}"#.utf8))
        page.devTools.invalidate()
        var types: [String] = []
        for await event in typed { types.append(event.type) }
        var count = 0
        for await _ in untyped { count += 1 }
        #expect(types == ["log", "warning"])
        #expect(count == 3)
    }

    @Test func typedEventsSurviveADiscardsNewSession() async {
        let page = CefPage()
        let typed = page.devTools.events(ConsoleCalled.self, bufferingPolicy: .unbounded)
        page.devTools.prepareForNewSession()
        page.devTools.received(event: "Runtime.consoleAPICalled", params: Data(#"{"type":"log"}"#.utf8))
        page.devTools.invalidate()
        var types: [String] = []
        for await event in typed { types.append(event.type) }
        #expect(types == ["log"])
    }
}
