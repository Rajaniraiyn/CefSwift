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
    }

    /// The helper executable (C, compiled by the plugin) reads the same
    /// switch.
    @Test func helperReadsTheSchemeSwitch() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins/CefPlugin/Helper/helper_main.c")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("\"--\(CefCustomScheme.childProcessSwitchName)=\""))
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

@Suite struct CefDirectorySchemeHandlerTests {
    @Test func servesIndexAndGuardsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-bundle-scheme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html>index</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: root.appendingPathComponent("app.css"))

        let handler = CefDirectorySchemeHandler(directory: root)
        #expect(handler.resolveFile(forRequestPath: "/")?.lastPathComponent == "index.html")
        #expect(handler.resolveFile(forRequestPath: "")?.lastPathComponent == "index.html")
        #expect(handler.resolveFile(forRequestPath: "/app.css")?.lastPathComponent == "app.css")
        #expect(handler.resolveFile(forRequestPath: "/missing.js") == nil)
        #expect(handler.resolveFile(forRequestPath: "/../outside.txt") == nil)
    }

    @Test func mimeDetection() {
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "html") == "text/html")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "css") == "text/css")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "png") == "image/png")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "") == "application/octet-stream")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "nonsense-ext") == "application/octet-stream")
    }
}
