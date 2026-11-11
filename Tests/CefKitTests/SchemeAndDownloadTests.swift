import Foundation
import Testing

@testable import CCef
@testable import CefKit

// Unit tests for the framework-free parts of custom schemes, the JS bridge,
// and download plumbing. No CEF runtime required.

@Suite struct CefCustomSchemeTests {
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
