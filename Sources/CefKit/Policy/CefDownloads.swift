import CCef
import Foundation

/// The state of a download, as listed in ``CefBrowser/downloads`` and
/// passed to ``CefBrowserDelegate``.
public struct CefDownload: Sendable, Equatable, Identifiable {
    /// Chromium's identifier for the download, stable across updates.
    public var id: UInt32
    /// The download URL.
    public var url: URL?
    /// Bytes received so far.
    public var receivedBytes: Int64
    /// The expected size in bytes, or 0 when unknown.
    public var totalBytes: Int64
    /// Whether the download finished successfully.
    public var isComplete: Bool
    /// Whether the download was cancelled or interrupted.
    public var isCancelled: Bool
    /// Where the file is being written, once a destination is known.
    public var fullPath: URL?

    public init(
        id: UInt32,
        url: URL?,
        receivedBytes: Int64,
        totalBytes: Int64,
        isComplete: Bool,
        isCancelled: Bool,
        fullPath: URL?
    ) {
        self.id = id
        self.url = url
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.isComplete = isComplete
        self.isCancelled = isCancelled
        self.fullPath = fullPath
    }
}

/// Whether and where to save a download.
public enum CefDownloadDecision: Sendable {
    /// Save the download to `destination`, a file URL including the file
    /// name, or to `~/Downloads` under the suggested name when `nil`.
    case allow(destination: URL?)
    /// Cancel the download.
    case deny
}

enum CefDownloadDestination {
    /// The file a decision saves to, or `nil` when it cancels the download.
    static func resolve(decision: CefDownloadDecision, suggestedName: String) -> URL? {
        switch decision {
        case .deny:
            return nil
        case .allow(let destination):
            if let destination { return destination }
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            // A suggested name must not lead outside the directory.
            let safeName = (suggestedName as NSString).lastPathComponent
            return downloads.appendingPathComponent(safeName.isEmpty ? "download" : safeName)
        }
    }
}

extension CefDownload {
    /// Reads a borrowed `cef_download_item_t`.
    init(item: UnsafeMutablePointer<cef_download_item_t>) {
        let urlString = CefStringUtil.takingUserFree(item.pointee.get_url(item)) ?? ""
        let path = CefStringUtil.takingUserFree(item.pointee.get_full_path(item)) ?? ""
        self.init(
            id: item.pointee.get_id(item),
            url: URL(string: urlString),
            receivedBytes: item.pointee.get_received_bytes(item),
            totalBytes: item.pointee.get_total_bytes(item),
            isComplete: item.pointee.is_complete(item) != 0,
            isCancelled: item.pointee.is_canceled(item) != 0 || item.pointee.is_interrupted(item) != 0,
            fullPath: path.isEmpty ? nil : URL(fileURLWithPath: path)
        )
    }
}
