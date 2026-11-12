import Foundation
import Testing

@testable import CefKit

@Suite struct CefJSONTests {
    @Test func literalsBuildTheExpectedTree() {
        let json: CefJSON = ["name": "Ada", "age": 36, "tags": ["a", true, nil], "ratio": 0.5]
        #expect(json["name"].stringValue == "Ada")
        #expect(json["age"].intValue == 36)
        #expect(json["tags"][1].boolValue == true)
        #expect(json["tags"][2].isNull)
        #expect(json["ratio"].doubleValue == 0.5)
    }

    @Test func lookupsOnMissingPathsChainToNull() {
        let json: CefJSON = ["a": ["b": 1]]
        #expect(json["a"]["missing"]["deeper"][3].isNull)
        #expect(json["a"]["b"].stringValue == nil)
    }

    @Test func intValueRejectsFractions() {
        #expect(CefJSON.number(1.5).intValue == nil)
        #expect(CefJSON.number(-3).intValue == -3)
    }

    @Test func roundTripsThroughText() throws {
        let original: CefJSON = ["list": [1, "two", false], "nested": ["null": nil]]
        #expect(try CefJSON(data: original.data) == original)
    }

    @Test func encodesAndDecodesCodableTypes() throws {
        struct Point: Codable, Equatable { var x: Int, y: Int }
        let json = try CefJSON(encoding: Point(x: 1, y: 2))
        #expect(json == ["x": 1, "y": 2])
        #expect(try json.decode(Point.self) == Point(x: 1, y: 2))
        #expect(try CefJSON.null.decode(Int?.self) == nil)
    }

    @Test func nonFiniteNumbersBecomeNullWhereTheyAre() throws {
        let tree: CefJSON = ["ok": 1, "nan": .number(.nan), "list": [.number(.infinity), 2]]
        #expect(try CefJSON(data: tree.data) == ["ok": 1, "nan": nil, "list": [nil, 2]])
        #expect(CefJSON.number(-.infinity).text == "null")
    }

    @MainActor @Test func devToolsRepliesMustBeObjects() throws {
        func reply(_ text: String, succeeded: Bool = true) -> CefDevTools.Reply {
            CefDevTools.Reply(succeeded: succeeded, result: Data(text.utf8))
        }
        #expect(try CefDevTools.result(of: reply(#"{"value":1}"#), for: "M.x") == ["value": 1])
        #expect(try CefDevTools.result(of: reply("{}"), for: "M.x") == [:])
        for malformed in ["", "null", "[1]", "3", "{", "\"text\""] {
            #expect(throws: CefError.self) { try CefDevTools.result(of: reply(malformed), for: "M.x") }
            #expect(throws: CefError.self) { try CefDevTools.result(of: reply(malformed, succeeded: false), for: "M.x") }
        }
        #expect(throws: CefDevToolsError(method: "M.x", code: -32000, message: "nope")) {
            try CefDevTools.result(of: reply(#"{"code":-32000,"message":"nope"}"#, succeeded: false), for: "M.x")
        }
    }

    @Test func textIsSafeToSpliceIntoJavaScript() {
        let text = CefJSON.string("line\u{2028}break\u{2029}\"quoted\"").text
        #expect(!text.contains("\u{2028}") && !text.contains("\u{2029}"))
        #expect(text.contains("\\\"quoted\\\""))
    }
}

@Suite @MainActor struct CefBridgeTests {
    @Test func describesItselfToTheRenderer() {
        let bridge = CefBridge(name: "app")
        #expect(bridge.rendererConfiguration == ["name": "app", "access": "mainFrame"])
        bridge.access = .origins(["https://b.example", "app://start"])
        #expect(bridge.rendererConfiguration == [
            "name": "app", "access": "origins", "origins": ["app://start", "https://b.example"],
        ])
    }

    @Test func checksTheReportedOriginAgainstTheFrameAddress() {
        let page = URL(string: "https://example.com:8443/page")
        #expect(CefBridge.origin("https://example.com:8443", isConsistentWith: page))
        #expect(!CefBridge.origin("https://other.example", isConsistentWith: page))
        // A sandboxed document's origin is opaque.
        #expect(CefBridge.origin("null", isConsistentWith: page))
        // Documents that inherit their origin.
        #expect(CefBridge.origin("https://example.com", isConsistentWith: URL(string: "about:blank")))
        #expect(CefBridge.origin("https://example.com", isConsistentWith: URL(string: "data:text/html,x")))
    }

    @Test func userScriptsDescribeWhenAndWhereTheyRun() {
        let script = CefUserScript(source: "x", matching: "https://*", injectionTime: .documentEnd, frames: .mainFrame)
        #expect(script.rendererConfiguration == [
            "source": "x", "urlPattern": "https://*", "atDocumentEnd": true, "mainFrameOnly": true,
        ])
        #expect(CefUserScript(source: "y").rendererConfiguration == [
            "source": "y", "atDocumentEnd": false, "mainFrameOnly": false,
        ])
    }

    @Test func defaultsToMainFrameAccess() {
        #expect(CefBridge().access == .mainFrame)
        #expect(CefBridge().name == "native")
    }
}

@Suite struct CefConfigurationTests {
    @Test func productNameSetsBothBrandStrings() {
        var configuration = CefConfiguration()
        configuration.productName = "Orbit"
        #expect(configuration.stringOverrides[.productName] == "Orbit")
        #expect(configuration.stringOverrides[.shortProductName] == "Orbit")
        configuration.productName = nil
        #expect(configuration.stringOverrides.isEmpty)
    }

    @Test func embeddedPresetTurnsOffBackgroundServices() {
        let configuration = CefConfiguration.embedded
        #expect(configuration.extraCommandLineSwitches.keys.contains("disable-background-networking"))
        #expect(configuration.disabledFeatures.contains("OptimizationHints"))
    }

    /// Chromium sets `navigator.webdriver` for these; no preset may.
    @Test func noPresetMarksTheBrowserAsAutomated() {
        let automation: Set<String> = ["enable-automation", "headless", "remote-debugging-pipe", "remote-debugging-port"]
        for configuration in [CefConfiguration.default, .embedded, .browser] {
            #expect(automation.isDisjoint(with: configuration.extraCommandLineSwitches.keys))
            #expect(configuration.remoteDebuggingPort == nil)
        }
    }

    @Test func userAgentChoicesMapToCEFSettings() {
        #expect(CefUserAgent.chromium.product == nil && CefUserAgent.chromium.fullString == nil)
        #expect(CefUserAgent.replacingProduct("Orbit/1").product == "Orbit/1")
        #expect(CefUserAgent.custom("UA").fullString == "UA" && CefUserAgent.custom("UA").product == nil)
        #expect(CefConfiguration.default.userAgent == .chromium)
    }

    @Test func browserPresetKeepsSessions() {
        #expect(CefConfiguration.browser.persistsSessionCookies)
    }
}
