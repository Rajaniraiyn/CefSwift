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

    func established(_ claimed: String, at url: String?, in ancestors: [String?] = []) -> CefBridge.EstablishedOrigin {
        CefBridge.establishedOrigin(claimed: claimed, url: url) { ancestors }
    }

    @Test func checksTheReportedOriginAgainstTheFrameAddress() {
        let page = "https://example.com:8443/page"
        #expect(established("https://example.com:8443", at: page) == .origin("https://example.com:8443"))
        #expect(established("https://other.example", at: page) == .inconsistent)
        // A sandboxed document's origin is opaque.
        #expect(established("null", at: page) == .opaque)
        // Default ports are not part of an origin; hosts compare without case.
        #expect(established("https://example.com", at: "https://EXAMPLE.com:443/") == .origin("https://example.com"))
        #expect(established("app://start", at: "app://start/index.html") == .origin("app://start"))
        #expect(established("http://[::1]:8080", at: "http://[::1]:8080/") == .origin("http://[::1]:8080"))
    }

    @Test func hostlessDocumentsFailClosed() {
        let allowed = "https://example.com"
        // Opaque documents are opaque whatever the renderer claims.
        #expect(established(allowed, at: "data:text/html,x") == .opaque)
        #expect(established(allowed, at: "javascript:0") == .opaque)
        #expect(established(allowed, at: "about:version") == .opaque)
        #expect(established(allowed, at: nil) == .opaque)
        #expect(established(allowed, at: "") == .opaque)
        #expect(established(allowed, at: "not a url") == .opaque)
        // A top-level about:blank (a popup's) has no parent to inherit from.
        #expect(established(allowed, at: "about:blank") == .opaque)
        // about:blank and srcdoc inherit the nearest ancestor's origin.
        #expect(established(allowed, at: "about:srcdoc", in: ["https://example.com/a"]) == .origin(allowed))
        #expect(established(allowed, at: "about:blank#x", in: ["about:srcdoc", "https://example.com/"]) == .origin(allowed))
        #expect(established(allowed, at: "about:blank", in: ["https://evil.example/"]) == .inconsistent)
        #expect(established(allowed, at: "about:srcdoc", in: ["data:text/html,x"]) == .opaque)
        #expect(established("null", at: "about:srcdoc", in: ["https://example.com/"]) == .opaque)
        // blob: carries its origin.
        #expect(established(allowed, at: "blob:https://example.com/0b1e") == .origin(allowed))
        #expect(established(allowed, at: "blob:https://evil.example/0b1e") == .inconsistent)
        #expect(established(allowed, at: "blob:null/0b1e") == .opaque)
        #expect(established(allowed, at: "blob:blob:https://example.com/0b1e") == .opaque)
    }

    @Test func localSchemesHaveTheirAddressOriginOnlyInTheMainFrame() {
        func main(_ claimed: String, _ url: String, local: Set<String> = ["file"]) -> CefBridge.EstablishedOrigin {
            CefBridge.establishedOrigin(claimed: claimed, url: url, isMainFrame: true, localSchemes: local) { [] }
        }
        func sub(_ claimed: String, _ url: String, in ancestors: [String?], local: Set<String> = ["file"]) -> CefBridge.EstablishedOrigin {
            CefBridge.establishedOrigin(claimed: claimed, url: url, isMainFrame: false, localSchemes: local) { ancestors }
        }
        // A top-level file: page.
        #expect(main("file://", "file:///Users/a/page.html") == .origin("file://"))
        #expect(main("null", "file:///Users/a/page.html") == .opaque)
        #expect(main("https://example.com", "file:///Users/a/page.html") == .inconsistent)
        // A file: subframe may be sandboxed, which CEF does not say.
        #expect(sub("file://", "file:///Users/a/frame.html", in: ["file:///Users/a/page.html"]) == .opaque)
        // srcdoc, about:blank and data: inside a file: page.
        #expect(sub("null", "about:srcdoc", in: ["file:///Users/a/page.html"]) == .opaque)
        #expect(sub("file://", "about:srcdoc", in: ["file:///Users/a/page.html"]) == .opaque)
        #expect(sub("file://", "about:blank", in: ["file:///Users/a/frame.html", "file:///Users/a/page.html"]) == .opaque)
        #expect(sub("file://", "data:text/html,x", in: ["file:///Users/a/page.html"]) == .opaque)
        #expect(sub("file://", "blob:file:///0b1e", in: ["file:///Users/a/page.html"]) == .opaque)
        // A custom scheme registered with `.local` follows the same rules.
        let local: Set<String> = ["file", "myapp"]
        #expect(main("myapp://start", "myapp://start/index.html", local: local) == .origin("myapp://start"))
        #expect(sub("myapp://start", "myapp://start/frame.html", in: ["myapp://start/"], local: local) == .opaque)
        // Without `.local`, a standard custom scheme is like https, frames included.
        #expect(sub("myapp://start", "myapp://start/frame.html", in: ["myapp://start/"]) == .origin("myapp://start"))
        // A scheme that is not standard has no host, so it is opaque.
        #expect(main("null", "plain:/page.html") == .opaque)
        #expect(main("plain:", "plain:/page.html") == .opaque)
    }

    @Test func originScopedBridgesRejectUnconfirmedOrigins() {
        // The browser-side origin decides: `"null"` never matches `.origins`.
        #expect(CefBridge.EstablishedOrigin.opaque.origin == nil)
        #expect(CefBridge.EstablishedOrigin.origin("https://example.com").origin == "https://example.com")
        #expect(CefBridge.addressOrigin("file:///tmp/x.html") == .tuple("file://"))
        #expect(CefBridge.addressOrigin("about:srcdoc") == .inherited)
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
        var configuration = CefRuntime.Configuration()
        configuration.productName = "Orbit"
        #expect(configuration.stringOverrides[.productName] == "Orbit")
        #expect(configuration.stringOverrides[.shortProductName] == "Orbit")
        configuration.productName = nil
        #expect(configuration.stringOverrides.isEmpty)
    }

    @Test func embeddedPresetTurnsOffBackgroundServices() {
        let configuration = CefRuntime.Configuration.embedded
        #expect(configuration.extraCommandLineSwitches.keys.contains("disable-background-networking"))
        #expect(configuration.disabledFeatures.contains("OptimizationHints"))
    }

    /// Chromium sets `navigator.webdriver` for these; no preset may.
    @Test func noPresetMarksTheBrowserAsAutomated() {
        let automation: Set<String> = ["enable-automation", "headless", "remote-debugging-pipe", "remote-debugging-port"]
        for configuration in [CefRuntime.Configuration(), .embedded, .chrome] {
            #expect(automation.isDisjoint(with: configuration.extraCommandLineSwitches.keys))
            #expect(configuration.remoteDebuggingPort == nil)
        }
    }

    @Test func userAgentChoicesMapToCEFSettings() {
        #expect(CefRuntime.UserAgent.chromium.product == nil && CefRuntime.UserAgent.chromium.fullString == nil)
        #expect(CefRuntime.UserAgent.replacingProduct("Orbit/1").product == "Orbit/1")
        #expect(CefRuntime.UserAgent.custom("UA").fullString == "UA" && CefRuntime.UserAgent.custom("UA").product == nil)
        #expect(CefRuntime.Configuration().userAgent == .chromium)
    }

    @Test func browserPresetKeepsSessions() {
        #expect(CefRuntime.Configuration.chrome.persistsSessionCookies)
    }
}
