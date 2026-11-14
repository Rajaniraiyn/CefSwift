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
        let parsed = CefSchemeList.entries(inArguments: ["--type=renderer", "--cefswift-schemes=" + CefCustomScheme.serialize([
            CefCustomScheme(name: "myapp"), CefCustomScheme(name: "assets", options: [.standard, .local]),
        ]) + ",broken,:4,odd:x"])
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
        let browser = CefBrowser(configuration: Self.configuration(profile: .incognito()))
        func update(_ state: CefDownload.State) {
            let control = CefRef(adopting: cefAllocate(cef_download_item_callback_t.self, owner: NSObject()))
            browser.applyDownload(CefDownload.Snapshot(id: 7, receivedBytes: 10, state: state), control: control)
        }
        update(.interrupted(.networkDisconnected))
        let download = try! #require(browser.downloads.first)
        #expect(download.control != nil && download.canResume)
        update(.paused)
        #expect(download.control != nil)
        update(.completed)
        #expect(download.control == nil)
        #expect(browser.downloads.count == 1 && !download.canResume)
    }

    /// One object per download, updated in place, listed by its browser and
    /// its profile.
    @Test func updatesKeepOneObjectPerDownload() {
        let profile = CefProfile.incognito()
        let first = CefBrowser(configuration: Self.configuration(profile: profile))
        let second = CefBrowser(configuration: Self.configuration(profile: profile))
        first.applyDownload(CefDownload.Snapshot(id: 1, suggestedFilename: "a.zip", mimeType: "application/zip",
                                                 receivedBytes: 10, expectedBytes: 40, bytesPerSecond: 10), control: nil)
        second.applyDownload(CefDownload.Snapshot(id: 2, suggestedFilename: "b.txt"), control: nil)
        let download = try! #require(first.downloads.first)
        #expect(download.fractionCompleted == 0.25)
        #expect(download.estimatedTimeRemaining == .seconds(3))
        first.applyDownload(CefDownload.Snapshot(id: 1, suggestedFilename: "", receivedBytes: 40, expectedBytes: 40,
                                                 state: .completed), control: nil)
        #expect(first.downloads.count == 1 && first.downloads.first === download)
        #expect(download.state == .completed && download.suggestedFilename == "a.zip" && download.mimeType == "application/zip")
        #expect(download.bytesPerSecond == 0 && download.estimatedTimeRemaining == nil && download.fractionCompleted == 1)
        #expect(profile.downloads.map(\.suggestedFilename) == ["a.zip", "b.txt"])
        #expect(second.downloads.map(\.suggestedFilename) == ["b.txt"])
        #expect(download.browser === first)
    }

    /// Removal takes finished downloads out of both lists, and keeps one
    /// that can still go on.
    @Test func removingDownloadsKeepsThoseThatCanGoOn() {
        let profile = CefProfile.incognito()
        let browser = CefBrowser(configuration: Self.configuration(profile: profile))
        let control = CefRef(adopting: cefAllocate(cef_download_item_callback_t.self, owner: NSObject()))
        browser.applyDownload(CefDownload.Snapshot(id: 1, suggestedFilename: "done.zip", state: .completed), control: nil)
        browser.applyDownload(CefDownload.Snapshot(id: 2, suggestedFilename: "going.zip"), control: control)
        browser.applyDownload(CefDownload.Snapshot(id: 3, suggestedFilename: "paused.zip", state: .paused), control: control)
        browser.applyDownload(CefDownload.Snapshot(id: 4, suggestedFilename: "stuck.zip", state: .interrupted(.networkFailed)),
                              control: nil)
        browser.applyDownload(CefDownload.Snapshot(id: 5, suggestedFilename: "gone.zip", state: .cancelled), control: nil)

        profile.removeDownloads { $0.state == .cancelled || $0.state == .inProgress }
        #expect(profile.downloads.map(\.suggestedFilename) == ["done.zip", "going.zip", "paused.zip", "stuck.zip"])
        #expect(browser.downloads.map(\.suggestedFilename) == profile.downloads.map(\.suggestedFilename))

        profile.removeFinishedDownloads()
        #expect(profile.downloads.map(\.suggestedFilename) == ["going.zip", "paused.zip"])
        #expect(browser.downloads.map(\.suggestedFilename) == ["going.zip", "paused.zip"])

        // A later report of a removed download makes it anew.
        browser.applyDownload(CefDownload.Snapshot(id: 1, suggestedFilename: "done.zip", state: .completed), control: nil)
        #expect(profile.downloads.count == 3 && browser.downloads.count == 3)
    }

    @Test func downloadsCarryTheirOriginAndDates() {
        let browser = CefBrowser(configuration: Self.configuration(profile: .incognito()))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        browser.applyDownload(CefDownload.Snapshot(
            id: 9, url: URL(string: "https://cdn.example/f.zip"), originalURL: URL(string: "https://example.com/get"),
            startDate: start), control: nil)
        let download = try! #require(browser.downloads.first)
        #expect(download.originalURL?.host() == "example.com" && download.startDate == start && download.endDate == nil)
        browser.applyDownload(CefDownload.Snapshot(
            id: 9, url: URL(string: "https://cdn.example/f.zip"), startDate: start, endDate: start + 5, state: .completed),
            control: nil)
        #expect(download.originalURL?.host() == "example.com" && download.endDate == start + 5)
    }

    static func configuration(profile: CefProfile) -> CefBrowser.Configuration {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        return configuration
    }
}

@MainActor
@Suite struct CefDownloadDecisionTests {
    let folder = URL(fileURLWithPath: "/tmp/cefswift-downloads", isDirectory: true)

    private func resolve(_ decision: CefDownloadDecision, _ name: String, existing: Set<String> = []) -> CefDownloadDestination {
        CefDownloadDestination.resolve(decision, suggestedFilename: name) { existing.contains($0.lastPathComponent) }
    }

    @Test func policyMapsToDecision() {
        #expect(CefDownloadDecision(.downloadsFolder) == .saveInFolder(CefDownloadDestination.downloadsFolder))
        #expect(CefDownloadDecision(.folder(folder)) == .saveInFolder(folder))
        #expect(CefDownloadDecision(.ask) == .ask)
        #expect(CefDownloadDecision(.disabled) == .cancel)
    }

    @Test func defaultPolicyIsTheDownloadsFolder() {
        #expect(CefProfile.incognito().downloadPolicy == .downloadsFolder)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #expect(CefDownloadDestination.downloadsFolder.path == downloads?.path)
    }

    /// The default delegate follows the download's profile; a delegate's
    /// own answer wins over it.
    @Test func delegateFollowsThePolicyUnlessItDecides() async {
        let profile = CefProfile.incognito()
        let browser = CefBrowser(configuration: CefDownloadStateTests.configuration(profile: profile))
        browser.applyDownload(CefDownload.Snapshot(id: 3, suggestedFilename: "r.pdf"), control: nil)
        let download = browser.downloads[0]
        let standard = CefDefaultBrowserDelegate.shared
        profile.downloadPolicy = .folder(folder)
        #expect(await standard.browser(browser, decideDestinationFor: download) == .saveInFolder(folder))
        profile.downloadPolicy = .disabled
        #expect(await standard.browser(browser, decideDestinationFor: download) == .cancel)
        profile.downloadPolicy = .ask
        #expect(await standard.browser(browser, decideDestinationFor: download) == .ask)
        #expect(await PDFsToFolder(folder: folder).browser(browser, decideDestinationFor: download)
                    == .save(to: folder.appendingPathComponent("r.pdf")))
    }

    @Test func cancelAndAskResolveToThemselves() {
        #expect(resolve(.cancel, "file.zip") == .cancel)
        #expect(resolve(.ask, "file.zip") == .ask)
    }

    @Test func explicitFileWinsEvenWhenTaken() {
        let file = folder.appendingPathComponent("save-here.zip")
        #expect(resolve(.save(to: file), "x.zip", existing: ["save-here.zip"]) == .file(file))
    }

    @Test func folderTakesTheSuggestedName() {
        #expect(resolve(.saveInFolder(folder), "report.pdf") == .file(folder.appendingPathComponent("report.pdf")))
    }

    @Test func takenNamesAreNumbered() {
        #expect(resolve(.saveInFolder(folder), "report.pdf", existing: ["report.pdf", "report (1).pdf"])
                    == .file(folder.appendingPathComponent("report (2).pdf")))
        #expect(resolve(.saveInFolder(folder), "README", existing: ["README"]) == .file(folder.appendingPathComponent("README (1)")))
        // A download still being written holds its name.
        #expect(resolve(.saveInFolder(folder), "a.zip", existing: ["a.zip.crdownload"]) == .file(folder.appendingPathComponent("a (1).zip")))
    }

    @Test func hostileSuggestedNamesStayInTheFolder() {
        #expect(resolve(.saveInFolder(folder), "../../etc/passwd") == .file(folder.appendingPathComponent("passwd")))
        #expect(resolve(.saveInFolder(folder), "..") == .file(folder.appendingPathComponent("download")))
        #expect(resolve(.saveInFolder(folder), "") == .file(folder.appendingPathComponent("download")))
    }

    @Test func savePanelProposesTheType() {
        #expect(CefDownloadPresenter.contentType(suggestedFilename: "a.pdf", mimeType: "application/octet-stream") == .pdf)
        #expect(CefDownloadPresenter.contentType(suggestedFilename: "a", mimeType: "image/png") == .png)
        #expect(CefDownloadPresenter.contentType(suggestedFilename: "a", mimeType: "application/octet-stream") == nil)
        #expect(CefDownloadPresenter.contentType(suggestedFilename: "a.zzzunknown", mimeType: "") == nil)
    }
}

@MainActor
private final class PDFsToFolder: CefBrowserDelegate {
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
        download.suggestedFilename.hasSuffix(".pdf") ? .save(to: folder.appendingPathComponent(download.suggestedFilename)) : .default(for: download)
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
