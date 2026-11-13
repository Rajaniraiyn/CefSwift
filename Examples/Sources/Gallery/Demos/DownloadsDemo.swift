import CefSwiftUI
import SwiftUI

/// `browser.downloads` lists a browser's downloads with their progress and
/// state, and `pauseDownload(_:)`, `resumeDownload(_:)` and
/// `cancelDownload(_:)` control them. Where each one is saved is the
/// delegate's decision, here a folder of the app's own.
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
                DownloadRow(download: download, browser: model.browser)
            }
            .frame(minHeight: 120)
            .overlay { if model.browser.downloads.isEmpty { Text("No downloads").foregroundStyle(.secondary) } }
        }
        .readyWhenLoaded(model.browser)
        .onDisappear { model.browser.close(force: true) }
    }
}

/// The browser's delegate saves into a folder of the app's own in the
/// temporary directory, which needs no permission, instead of asking.
@MainActor
private final class DownloadsModel: CefBrowserDelegate {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Gallery Downloads")
    lazy var browser = CefBrowser(url: Self.page.localURL, delegate: self)

    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload, suggestedName: String) async -> CefDownloadDecision {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return .save(to: folder.appending(path: suggestedName))
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
    let browser: CefBrowser

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(download.destinationURL?.lastPathComponent ?? download.url?.lastPathComponent ?? "Download")
                ProgressView(value: Double(download.receivedBytes), total: Double(max(1, download.expectedBytes ?? 0)))
                Text("\(download.receivedBytes.formatted(.byteCount(style: .file))) · \(String(describing: download.state))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch download.state {
            case .inProgress:
                Button("Pause", systemImage: "pause.fill") { browser.pauseDownload(download.id) }
                Button("Cancel", systemImage: "xmark") { browser.cancelDownload(download.id) }
            case .paused, .interrupted:
                Button("Resume", systemImage: "play.fill") { browser.resumeDownload(download.id) }
            case .completed:
                Button("Show in Finder", systemImage: "magnifyingglass") {
                    download.destinationURL.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                }
            case .cancelled:
                EmptyView()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
