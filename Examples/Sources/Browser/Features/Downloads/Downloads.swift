import AppKit
import CefSwiftUI
import SwiftUI

/// A Downloads button in the toolbar once a tab has downloaded something
/// (`CefBrowser.downloads`): its popover lists them, with their progress,
/// and cancels, resumes or shows each in the Finder; Clear takes the
/// finished ones out of the list (`CefProfile.removeDownloads(where:)`).
struct Downloads: BrowserFeature {
    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .trailing { DownloadsButton(browser: browser) }
    }
}

private struct DownloadsButton: View {
    let browser: CefBrowser
    @State private var isPresented = false

    private var isActive: Bool { browser.downloads.contains { $0.state == .inProgress } }

    var body: some View {
        if !browser.downloads.isEmpty {
            Button("Downloads", systemImage: isActive ? "arrow.down.circle.dotted" : "arrow.down.circle") { isPresented.toggle() }
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Downloads").font(.headline)
                            Spacer()
                            Button("Clear") {
                                (browser.configuration.profile ?? .default).removeDownloads { $0.browser === browser }
                            }
                            .buttonStyle(.link)
                        }
                        ForEach(browser.downloads.reversed()) { download in
                            DownloadRow(download: download)
                        }
                    }
                    .padding()
                    .frame(width: 320)
                }
        }
    }
}

private struct DownloadRow: View {
    let download: CefDownload

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.fileURL?.lastPathComponent ?? download.suggestedFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch download.state {
                case .completed:
                    Button("Show in Finder") {
                        if let path = download.fileURL { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                case .cancelled:
                    Text("Canceled").font(.caption).foregroundStyle(.secondary)
                case .interrupted(let reason):
                    Text("Failed (\(reason.description))").font(.caption).foregroundStyle(.secondary)
                case .paused:
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                case .inProgress:
                    if let fraction = download.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if download.canResume {
                Button("Resume", systemImage: "arrow.clockwise.circle.fill", action: download.resume)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            if !download.state.isFinished {
                Button("Cancel", systemImage: "xmark.circle.fill", action: download.cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
