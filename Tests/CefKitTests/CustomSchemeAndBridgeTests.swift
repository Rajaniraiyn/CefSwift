import Foundation
import Testing

@testable import CCef
@testable import CefKit

// Unit tests for the framework-free parts of custom schemes, the JS bridge,
// and download plumbing. No CEF runtime required.

@Suite struct CefCustomSchemeTests {
    @Test func optionsMirrorCefSchemeOptions() {
        #expect(CefCustomScheme.Options.standard.rawValue == Int32(CEF_SCHEME_OPTION_STANDARD.rawValue))
        #expect(CefCustomScheme.Options.local.rawValue == Int32(CEF_SCHEME_OPTION_LOCAL.rawValue))
        #expect(CefCustomScheme.Options.displayIsolated.rawValue == Int32(CEF_SCHEME_OPTION_DISPLAY_ISOLATED.rawValue))
        #expect(CefCustomScheme.Options.secure.rawValue == Int32(CEF_SCHEME_OPTION_SECURE.rawValue))
        #expect(CefCustomScheme.Options.corsEnabled.rawValue == Int32(CEF_SCHEME_OPTION_CORS_ENABLED.rawValue))
        #expect(CefCustomScheme.Options.cspBypassing.rawValue == Int32(CEF_SCHEME_OPTION_CSP_BYPASSING.rawValue))
        #expect(CefCustomScheme.Options.fetchEnabled.rawValue == Int32(CEF_SCHEME_OPTION_FETCH_ENABLED.rawValue))
        #expect(CefCustomScheme.Options().rawValue == Int32(CEF_SCHEME_OPTION_NONE.rawValue))
    }

    @Test func defaultOptionsAreAppShaped() {
        let scheme = CefCustomScheme(name: "myapp")
        #expect(scheme.options == [.standard, .secure, .corsEnabled, .fetchEnabled])
    }

    @Test func childSwitchSerializationRoundTrips() {
        let schemes = [
            CefCustomScheme(name: "myapp"),
            CefCustomScheme(name: "assets", options: [.standard, .local]),
            CefCustomScheme(name: "raw", options: []),
        ]
        let serialized = CefCustomScheme.serialize(schemes)
        #expect(serialized == "myapp:89,assets:3,raw:0")
        #expect(CefCustomScheme.parse(serialized) == schemes)
    }

    @Test func parseFromHelperArguments() {
        let arguments = [
            "/path/to/Helper", "--type=renderer",
            "--cefswift-schemes=myapp:89,cefswift:89", "--lang=en-US",
        ]
        let schemes = CefCustomScheme.parse(fromArguments: arguments)
        #expect(schemes.map(\.name) == ["myapp", "cefswift"])
        #expect(schemes.allSatisfy { $0.options == [.standard, .secure, .corsEnabled, .fetchEnabled] })
    }

    @Test func parseDropsMalformedEntries() {
        #expect(CefCustomScheme.parse("ok:1,,bad,:5,alsobad:x,fine:0") == [
            CefCustomScheme(name: "ok", options: CefCustomScheme.Options(rawValue: 1)),
            CefCustomScheme(name: "fine", options: []),
        ])
        #expect(CefCustomScheme.parse("") == [])
        #expect(CefCustomScheme.parse(fromArguments: ["--no-such-switch"]) == [])
    }
}

@Suite struct CefBridgeDispatchTests {
    private func request(
        _ url: String,
        method: String = "POST",
        body: Data? = nil
    ) -> CefSchemeRequest {
        CefSchemeRequest(url: URL(string: url), urlString: url, method: method, headers: [:], body: body)
    }

    @Test func functionNameParsing() {
        #expect(CefBridge.functionName(for: URL(string: "cefswift://bridge/greet")) == "greet")
        #expect(CefBridge.functionName(for: URL(string: "cefswift://bridge/with%20space")) == "with space")
        #expect(CefBridge.functionName(for: URL(string: "cefswift://bridge/")) == nil)
        #expect(CefBridge.functionName(for: URL(string: "cefswift://bridge/a/b")) == nil)
        #expect(CefBridge.functionName(for: URL(string: "cefswift://other/greet")) == nil)
        #expect(CefBridge.functionName(for: URL(string: "https://bridge/greet")) == nil)
        #expect(CefBridge.functionName(for: nil) == nil)
    }

    @Test func dispatchInvokesRegisteredRawHandler() async {
        let bridge = CefBridge()
        bridge.register("echo") { body in body }
        let response = await bridge.dispatch(request("cefswift://bridge/echo", body: Data("ping".utf8)))
        #expect(response.status == 200)
        #expect(response.mimeType == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == "ping")
        #expect(response.headers["Access-Control-Allow-Origin"] == "*")
    }

    @Test func dispatchTypedCodableHandler() async throws {
        struct Person: Codable, Sendable { let name: String }
        struct Greeting: Codable, Sendable, Equatable { let message: String }

        let bridge = CefBridge()
        bridge.register("greet") { (person: Person) in
            Greeting(message: "Hello, \(person.name)!")
        }
        let body = try JSONEncoder().encode(Person(name: "Ada"))
        let response = await bridge.dispatch(request("cefswift://bridge/greet", body: body))
        #expect(response.status == 200)
        let greeting = try JSONDecoder().decode(Greeting.self, from: response.body)
        #expect(greeting == Greeting(message: "Hello, Ada!"))
    }

    @Test func dispatchUnknownFunctionIs404() async {
        let response = await CefBridge().dispatch(request("cefswift://bridge/missing"))
        #expect(response.status == 404)
    }

    @Test func dispatchMalformedURLIs400() async {
        let response = await CefBridge().dispatch(request("cefswift://elsewhere/x"))
        #expect(response.status == 400)
    }

    @Test func dispatchHandlerErrorIs500() async {
        struct Boom: Error {}
        let bridge = CefBridge()
        bridge.register("explode") { _ in throw Boom() }
        let response = await bridge.dispatch(request("cefswift://bridge/explode"))
        #expect(response.status == 500)
    }

    @Test func dispatchAnswersCORSPreflight() async {
        let response = await CefBridge().dispatch(request("cefswift://bridge/anything", method: "OPTIONS"))
        #expect(response.status == 204)
        #expect(response.headers["Access-Control-Allow-Methods"]?.contains("POST") == true)
    }

    @Test func shimAndReservedSchemeShape() {
        #expect(CefBridge.javascriptShim.contains("window.cefSwift"))
        #expect(CefBridge.javascriptShim.contains("cefswift://bridge/"))
        #expect(CefBridge.customScheme.name == CefBridge.schemeName)
        #expect(CefBridge.customScheme.options.contains([.standard, .secure, .corsEnabled, .fetchEnabled]))
        let bridge = CefBridge()
        #expect(!bridge.hasRegisteredFunctions)
        bridge.register("f") { body in body }
        #expect(bridge.hasRegisteredFunctions)
        bridge.unregister("f")
        #expect(!bridge.hasRegisteredFunctions)
    }
}

@Suite struct CefDownloadDecisionTests {
    @Test func denyResolvesToNil() {
        #expect(CefDownloadDestination.resolve(decision: .deny, suggestedName: "file.zip") == nil)
    }

    @Test func explicitDestinationWins() {
        let destination = URL(fileURLWithPath: "/tmp/custom/save-here.zip")
        #expect(
            CefDownloadDestination.resolve(decision: .allow(destination: destination), suggestedName: "x.zip")
                == destination)
    }

    @Test func defaultDestinationIsDownloadsPlusSuggestedName() throws {
        let resolved = try #require(
            CefDownloadDestination.resolve(decision: .allow(destination: nil), suggestedName: "report.pdf"))
        #expect(resolved.lastPathComponent == "report.pdf")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(resolved.deletingLastPathComponent().path == downloads?.path)
    }

    @Test func hostileSuggestedNameIsSanitized() throws {
        let resolved = try #require(
            CefDownloadDestination.resolve(decision: .allow(destination: nil), suggestedName: "../../etc/passwd"))
        #expect(resolved.lastPathComponent == "passwd")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(resolved.deletingLastPathComponent().path == downloads?.path)
    }
}

@Suite struct CefBundleSchemeHandlerTests {
    @Test func servesIndexAndGuardsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-bundle-scheme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html>index</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: root.appendingPathComponent("app.css"))

        let handler = CefBundleSchemeHandler(directory: root)
        #expect(handler.resolveFile(forRequestPath: "/")?.lastPathComponent == "index.html")
        #expect(handler.resolveFile(forRequestPath: "")?.lastPathComponent == "index.html")
        #expect(handler.resolveFile(forRequestPath: "/app.css")?.lastPathComponent == "app.css")
        #expect(handler.resolveFile(forRequestPath: "/missing.js") == nil)
        #expect(handler.resolveFile(forRequestPath: "/../outside.txt") == nil)
    }

    @Test func mimeDetection() {
        #expect(CefBundleSchemeHandler.mimeType(forPathExtension: "html") == "text/html")
        #expect(CefBundleSchemeHandler.mimeType(forPathExtension: "css") == "text/css")
        #expect(CefBundleSchemeHandler.mimeType(forPathExtension: "png") == "image/png")
        #expect(CefBundleSchemeHandler.mimeType(forPathExtension: "") == "application/octet-stream")
        #expect(CefBundleSchemeHandler.mimeType(forPathExtension: "nonsense-ext") == "application/octet-stream")
    }
}
