import Foundation
import Observation

extension CefProfile {
    /// Where the profile's downloads go when the browser's delegate leaves
    /// the decision to the profile, as the default delegate does.
    public enum DownloadPolicy: Sendable, Hashable {
        /// Save in the user's Downloads folder, under the suggested name,
        /// numbered when the name is taken. The default, as in Safari and
        /// Chrome.
        case downloadsFolder
        /// Save in `folder`, under the suggested name, numbered when the
        /// name is taken.
        case folder(URL)
        /// Ask where to save each download, with ``CefDownloadPresenter``'s
        /// save panel.
        case ask
        /// Cancel every download.
        case disabled
    }

    /// Where this profile's downloads go, unless the browser's delegate
    /// decides otherwise in
    /// ``CefBrowserDelegate/browser(_:decideDestinationFor:)``. Takes
    /// effect for the next download; the default is ``DownloadPolicy/downloadsFolder``.
    ///
    /// ```swift
    /// CefProfile.default.downloadPolicy = .ask
    /// ```
    public var downloadPolicy: DownloadPolicy {
        get { downloadStore.policy }
        set { downloadStore.policy = newValue }
    }

    /// The downloads of every browser of this profile, oldest first, since
    /// the app started. Observable: a view reading it updates as downloads
    /// start, and each ``CefDownload`` as it progresses.
    public var downloads: [CefDownload] { downloadStore.downloads }

    /// The download Chromium identifies as `id` in this profile, made from
    /// `snapshot` if it is new, and listed in `browser`'s downloads too.
    func trackDownload(_ snapshot: CefDownload.Snapshot, startedBy browser: CefBrowser) -> CefDownload {
        if let existing = downloadStore.byID[snapshot.id] { return existing }
        let download = CefDownload(snapshot, browser: browser, profile: self)
        downloadStore.byID[snapshot.id] = download
        downloadStore.downloads.append(download)
        browser.downloads.append(download)
        return download
    }
}

/// A profile's download policy and downloads.
@MainActor
@Observable
final class CefDownloadStore {
    var policy = CefProfile.DownloadPolicy.downloadsFolder
    var downloads: [CefDownload] = []
    @ObservationIgnored var byID: [UInt32: CefDownload] = [:]
}
