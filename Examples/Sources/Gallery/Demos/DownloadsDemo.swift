import CefSwiftUI
import SwiftUI

/// `browser.downloads` lists a browser's downloads; each ``CefDownload`` is
/// observable, with its progress and state, and `pause()`, `resume()` and
/// `cancel()`. Downloads belong to the profile: where one is saved follows
/// the profile's `downloadPolicy` unless the profile's delegate decides, as
/// here: a folder of the app's own.
struct DownloadsDemo: Demo {
    let title = "Downloads"
    let summary = "Files the page downloads, saved where the app decides, with their progress and controls."
    let symbol = "arrow.down.circle"
    let category = DemoCategory.network

    func makeView() -> some View { DownloadsView() }
}

private struct DownloadsView: View {
    @State private var model = DownloadsModel()

    var body: some View {
        VSplitView {
            CefWebView(model.browser).frame(minHeight: 160)
            List(model.browser.downloads.reversed()) { download in
                DownloadRow(download: download)
            }
            .frame(minHeight: 120)
            .overlay { if model.browser.downloads.isEmpty { Text("No downloads").foregroundStyle(.secondary) } }
        }
        .readyWhenLoaded(model.browser)
        .onDisappear { model.browser.close(force: true) }
    }
}

/// The profile's delegate saves into a folder of the app's own in the
/// temporary directory, which needs no permission, instead of asking. The
/// demo's page has a profile of its own, so the decision is the demo's alone.
@MainActor
private final class DownloadsModel: CefProfileDelegate {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Gallery Downloads")
    let profile = CefProfile.incognito()
    lazy var browser: CefBrowser = {
        profile.delegate = self
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        return CefBrowser(url: Self.page.localURL, configuration: configuration)
    }()

    func profile(_ profile: CefProfile, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return .saveInFolder(folder)
    }

    static let page = SamplePage("downloads.html", title: "Downloads", body: """
        <h1>Downloads</h1>
        <p>Each link is a file the server sends as an attachment, over a couple of seconds.</p>
        <p><a href="/stream?bytes=2000000&name=small.bin">small.bin, 2 MB</a> ·
           <a href="/stream?bytes=20000000&name=large.bin">large.bin, 20 MB</a></p>
        """)
}

private struct DownloadRow: View {
    let download: CefDownload

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(download.suggestedFilename)
                ProgressView(value: download.fractionCompleted)
                Text("\(download.receivedBytes.formatted(.byteCount(style: .file))) · \(String(describing: download.state))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch download.state {
            case .inProgress:
                Button("Pause", systemImage: "pause.fill") { download.pause() }
                Button("Cancel", systemImage: "xmark") { download.cancel() }
            case .paused, .interrupted:
                Button("Resume", systemImage: "play.fill") { download.resume() }
            case .completed:
                Button("Show in Finder", systemImage: "magnifyingglass") {
                    download.fileURL.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                }
            case .cancelled:
                EmptyView()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
