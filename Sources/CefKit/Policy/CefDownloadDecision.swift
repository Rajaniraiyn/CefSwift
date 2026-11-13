import Foundation

/// Whether and where to save a download: the answer to
/// ``CefBrowserDelegate/browser(_:decideDestinationFor:)``.
public enum CefDownloadDecision: Sendable, Equatable {
    /// Save the download as `file`, exactly: the name is not numbered.
    case save(to: URL)
    /// Save the download in `folder` under its suggested name, numbered
    /// (`report (1).pdf`) when a file of that name exists.
    case saveInFolder(URL)
    /// Ask the user where to save it, with ``CefDownloadPresenter``'s save
    /// panel. Cancelling the panel cancels the download.
    case ask
    /// Cancel the download.
    case cancel

    /// The decision ``CefProfile/downloadPolicy`` of the download's
    /// profile makes, the delegate's default. Return it from your own
    /// implementation for downloads you do not handle.
    @MainActor
    public static func `default`(for download: CefDownload) -> CefDownloadDecision {
        CefDownloadDecision(download.profile?.downloadPolicy ?? .downloadsFolder)
    }

    /// The decision `policy` makes for every download.
    init(_ policy: CefProfile.DownloadPolicy) {
        switch policy {
        case .downloadsFolder: self = .saveInFolder(CefDownloadDestination.downloadsFolder)
        case .folder(let folder): self = .saveInFolder(folder)
        case .ask: self = .ask
        case .disabled: self = .cancel
        }
    }
}

/// Where a decision saves a download.
enum CefDownloadDestination: Equatable {
    /// Save as this file.
    case file(URL)
    /// Show the save panel first.
    case ask
    case cancel

    /// The user's Downloads folder.
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Where `decision` saves a download suggested as `suggestedFilename`.
    /// `exists` tells whether a file is at a path, for numbering.
    static func resolve(
        _ decision: CefDownloadDecision, suggestedFilename: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> CefDownloadDestination {
        switch decision {
        case .cancel: return .cancel
        case .ask: return .ask
        case .save(to: let file): return .file(file)
        case .saveInFolder(let folder):
            return .file(uniqueFile(named: safeFilename(suggestedFilename), in: folder, exists: exists))
        }
    }

    /// `suggested` as one file name: a suggested name must not lead out
    /// of the folder.
    static func safeFilename(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." || name == "/" ? "download" : name
    }

    /// `name` in `folder`, numbered as Chromium and Finder do when a file,
    /// or a download still being written (`.crdownload`), has that name.
    static func uniqueFile(named name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        func taken(_ url: URL) -> Bool {
            exists(url) || exists(url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".crdownload"))
        }
        let first = folder.appendingPathComponent(name)
        guard taken(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 1..<10_000 {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
            if !taken(candidate) { return candidate }
        }
        return first
    }
}
