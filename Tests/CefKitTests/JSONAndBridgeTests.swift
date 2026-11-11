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

    @Test func textIsSafeToSpliceIntoJavaScript() {
        let text = CefJSON.string("line\u{2028}break\u{2029}\"quoted\"").text
        #expect(!text.contains("\u{2028}") && !text.contains("\u{2029}"))
        #expect(text.contains("\\\"quoted\\\""))
    }
}

@Suite @MainActor struct CefBridgeTests {
    @Test func shimDefinesTheNamedGlobalAndItsPlumbing() {
        let shim = CefBridge(name: "app").shim
        #expect(shim.contains("globalThis.__cefswift_app"))
        #expect(shim.contains("hidden('app'"))
        #expect(shim.contains("__cefswift_app_reply"))
        #expect(shim.contains("__cefswift_app_emit"))
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
        #expect(configuration.disabledFeatures.contains("Translate"))
    }

    @Test func browserPresetKeepsSessions() {
        #expect(CefConfiguration.browser.persistSessionCookies)
    }
}

@Suite struct CefWindowOpenPolicyTests {
    private let url = URL(string: "https://example.com")

    @Test func chromeStyleKeepsNativeHandling() {
        let request = CefWindowOpenRequest(targetURL: url, isSourceChromeStyle: true)
        #expect(CefWindowOpenPolicy.defaultAction(for: request) == .allowNativePopup)
    }

    @Test func embeddedBrowsersLoadInPlace() {
        #expect(CefWindowOpenPolicy.defaultAction(for: CefWindowOpenRequest(targetURL: url)) == .openInCurrentBrowser)
    }

    @Test func offscreenNeverGetsANativePopup() {
        let request = CefWindowOpenRequest(targetURL: url, isSourceOffscreen: true)
        #expect(CefWindowOpenPolicy.resolve(.allowNativePopup, for: request) == .openInCurrentBrowser)
        let blank = CefWindowOpenRequest(targetURL: nil, isSourceOffscreen: true)
        #expect(CefWindowOpenPolicy.resolve(.allowNativePopup, for: blank) == .deny)
    }
}
