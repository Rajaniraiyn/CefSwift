import Foundation
import Testing

@testable import CCef
import CefBase
@testable import CefKit
@testable import CefRenderer

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

    /// The helper executable reads the same switch, and skips what the
    /// browser process's parser would.
    @Test func helperReadsTheSchemeSwitch() {
        #expect(CefHelper.schemesSwitch == "--\(CefCustomScheme.childProcessSwitchName)=")
        let parsed = CefHelper.parseSchemes(CefCustomScheme.serialize([
            CefCustomScheme(name: "myapp"), CefCustomScheme(name: "assets", options: [.standard, .local]),
        ]) + ",broken,:4,odd:x")
        #expect(parsed.map(\.name) == ["myapp", "assets"])
        #expect(parsed.map(\.options) == [89, 3])
    }
}

@MainActor
@Suite struct CefDownloadStateTests {
    @Test func flagsMapToOneState() {
        func state(complete: Bool = false, cancelled: Bool = false, interrupted: Bool = false, paused: Bool = false)
            -> CefDownload.State
        {
            CefDownload.state(
                isComplete: complete, isCancelled: cancelled, isInterrupted: interrupted, isPaused: paused,
                interruptReason: 20)
        }
        #expect(state() == .inProgress)
        #expect(state(paused: true) == .paused)
        #expect(state(interrupted: true) == .interrupted(.networkFailed))
        #expect(state(cancelled: true, interrupted: true) == .cancelled)
        #expect(state(complete: true) == .completed)
        #expect(!CefDownload.State.interrupted(.networkFailed).isFinished && CefDownload.State.cancelled.isFinished)
    }

    @Test func interruptedDownloadsKeepTheirControl() {
        let browser = CefBrowser()
        func update(_ state: CefDownload.State) {
            let control = CefRef(adopting: cefAllocate(cef_download_item_callback_t.self, owner: NSObject()))
            browser.applyDownload(
                CefDownload(id: 7, url: nil, receivedBytes: 10, expectedBytes: nil, state: state, destinationURL: nil),
                control: control)
        }
        update(.interrupted(.networkDisconnected))
        #expect(browser.downloadControls[7] != nil)
        #expect(browser.downloads.first?.canResume == true)
        update(.paused)
        #expect(browser.downloadControls[7] != nil)
        update(.completed)
        #expect(browser.downloadControls[7] == nil)
        #expect(browser.downloads.count == 1 && browser.downloads.first?.canResume == false)
    }
}

@Suite struct CefDownloadDecisionTests {
    @Test func cancelResolvesToNil() {
        #expect(CefDownloadDestination.resolve(decision: .cancel, suggestedName: "file.zip") == nil)
    }

    @Test func explicitDestinationWins() {
        let destination = URL(fileURLWithPath: "/tmp/custom/save-here.zip")
        #expect(
            CefDownloadDestination.resolve(decision: .save(to: destination), suggestedName: "x.zip")
                == destination)
    }

    @Test func defaultDestinationIsDownloadsPlusSuggestedName() throws {
        let resolved = try #require(
            CefDownloadDestination.resolve(decision: .saveToDownloadsFolder, suggestedName: "report.pdf"))
        #expect(resolved.lastPathComponent == "report.pdf")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(resolved.deletingLastPathComponent().path == downloads?.path)
    }

    @Test func hostileSuggestedNameIsSanitized() throws {
        let resolved = try #require(
            CefDownloadDestination.resolve(decision: .saveToDownloadsFolder, suggestedName: "../../etc/passwd"))
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

    @Test func refusesSymlinksAndIndexFilesThatLeadOutside() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cefswift-scheme-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
        try Data("<p>index</p>".utf8).write(to: root.appendingPathComponent("sub/index.html"))
        // Links out of the root, to a file and to a directory.
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape.txt"),
                                  withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("away"), withDestinationURL: outside)
        // A link that stays inside.
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias.txt"),
                                  withDestinationURL: root.appendingPathComponent("inside.txt"))

        let handler = CefDirectorySchemeHandler(directory: root)
        #expect(handler.resolveFile(forRequestPath: "/escape.txt") == nil)
        #expect(handler.resolveFile(forRequestPath: "/away/secret.txt") == nil)
        #expect(handler.resolveFile(forRequestPath: "/alias.txt")?.lastPathComponent == "inside.txt")
        #expect(handler.resolveFile(forRequestPath: "/sub/")?.lastPathComponent == "index.html")

        // An index file that climbs out of the directory it is served for.
        let climbing = CefDirectorySchemeHandler(directory: root, indexFile: "../../outside/secret.txt")
        #expect(climbing.resolveFile(forRequestPath: "/sub/") == nil)
        #expect(climbing.resolveFile(forRequestPath: "/") == nil)
        let within = CefDirectorySchemeHandler(directory: root, indexFile: "../inside.txt")
        #expect(within.resolveFile(forRequestPath: "/sub/")?.lastPathComponent == "inside.txt")
    }

    @Test func mimeDetection() {
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "html") == "text/html")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "css") == "text/css")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "png") == "image/png")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "") == "application/octet-stream")
        #expect(CefDirectorySchemeHandler.mimeType(forPathExtension: "nonsense-ext") == "application/octet-stream")
    }
}
