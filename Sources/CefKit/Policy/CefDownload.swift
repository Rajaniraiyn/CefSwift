import CCef
import Foundation
import Observation
import CefBase

/// A download: what it is, where it goes, how far it got, and its
/// controls.
///
/// Each download is one object for its whole life, updated in place as
/// Chromium reports progress, so a view showing it, or a download manager
/// holding it, follows it by observation. ``CefBrowser/downloads`` lists the
/// downloads a browser started, ``CefProfile/downloads`` those of every
/// browser of a profile.
///
/// ```swift
/// ForEach(CefProfile.default.downloads) { download in
///     ProgressView(download.suggestedFilename, value: download.fractionCompleted ?? 0)
/// }
/// ```
@MainActor
@Observable
public final class CefDownload: Identifiable {
    /// Where a download is.
    public enum State: Sendable, Equatable {
        /// Receiving data.
        case inProgress
        /// Paused with ``CefDownload/pause()``.
        case paused
        /// Finished; the file is at ``CefDownload/fileURL``.
        case completed
        /// Cancelled, by the app, the delegate or the user.
        case cancelled
        /// Stopped by an error. ``CefDownload/resume()`` tries again, from
        /// where it stopped when the server allows that.
        case interrupted(InterruptReason)

        /// Whether the download is over for good: completed or cancelled.
        public var isFinished: Bool { self == .completed || self == .cancelled }
    }

    /// Why a download was interrupted: Chromium's
    /// `download::DownloadInterruptReason`.
    public struct InterruptReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let fileFailed = Self(rawValue: 1)
        public static let fileAccessDenied = Self(rawValue: 2)
        public static let fileNoSpace = Self(rawValue: 3)
        public static let fileNameTooLong = Self(rawValue: 5)
        public static let fileTooLarge = Self(rawValue: 6)
        public static let fileBlocked = Self(rawValue: 11)
        public static let networkFailed = Self(rawValue: 20)
        public static let networkTimeout = Self(rawValue: 21)
        public static let networkDisconnected = Self(rawValue: 22)
        public static let serverDown = Self(rawValue: 23)
        public static let serverFailed = Self(rawValue: 30)
        public static let serverUnauthorized = Self(rawValue: 34)
        public static let serverForbidden = Self(rawValue: 36)
        public static let serverUnreachable = Self(rawValue: 37)
        public static let shutdown = Self(rawValue: 41)
        public static let crash = Self(rawValue: 50)

        public var description: String {
            switch rawValue {
            case 1...19: "file error \(rawValue)"
            case 20...29: "network error \(rawValue)"
            case 30...39: "server error \(rawValue)"
            case 41: "shutdown"
            case 50: "crash"
            default: "error \(rawValue)"
            }
        }
    }

    /// The address the file comes from, after redirects.
    public private(set) var url: URL?
    /// The address the download was asked for, before redirects.
    public private(set) var originalURL: URL?
    /// When the download started.
    public private(set) var startDate: Date?
    /// When the download completed or was cancelled; nil before.
    public private(set) var endDate: Date?
    /// The file name the server or the page suggests, from
    /// `Content-Disposition`, the `download` attribute or the URL.
    public private(set) var suggestedFilename: String
    /// The file's MIME type, as the server sent it; empty when unknown.
    public private(set) var mimeType: String
    /// The file being written, once a destination is chosen; the finished
    /// file once ``state`` is ``State/completed``.
    public private(set) var fileURL: URL?
    /// Bytes received so far.
    public private(set) var receivedBytes: Int64
    /// The expected size in bytes, `nil` when the server did not say.
    public private(set) var expectedBytes: Int64?
    /// The current transfer rate in bytes per second; 0 when not receiving.
    public private(set) var bytesPerSecond: Int64
    public private(set) var state: State
    /// The browser that started the download, while it is open.
    public private(set) weak var browser: CefBrowser?

    /// Chromium's identifier, unique within the download's profile.
    @ObservationIgnored let chromiumID: UInt32
    /// The profile whose policy applies; it holds the download in its list.
    @ObservationIgnored weak var profile: CefProfile?
    /// Pauses, resumes and cancels the download; Chromium hands a new one
    /// with each update. Kept while the download can go on and its browser
    /// is open.
    var control: CefRef<cef_download_item_callback_t>?

    /// How much has arrived, from 0 to 1; `nil` when the size is unknown.
    public var fractionCompleted: Double? {
        if state == .completed { return 1 }
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    /// The time left at the current rate; `nil` when the size or the rate
    /// is unknown, or the download is not receiving.
    public var estimatedTimeRemaining: Duration? {
        guard state == .inProgress, bytesPerSecond > 0, let expectedBytes, expectedBytes >= receivedBytes else { return nil }
        return .seconds(Double(expectedBytes - receivedBytes) / Double(bytesPerSecond))
    }

    /// Whether the download can still go on: in progress, or paused or
    /// interrupted with a control to resume it.
    var canGoOn: Bool {
        state == .inProgress || canResume
    }

    /// Whether ``resume()`` can continue the download: it is paused or
    /// interrupted, and the browser that started it is open.
    public var canResume: Bool {
        switch state {
        case .paused, .interrupted: control != nil
        case .inProgress, .completed, .cancelled: false
        }
    }

    /// Pauses the download.
    public func pause() {
        control.map { $0.pointer.pointee.pause($0.pointer) }
    }

    /// Continues a paused or interrupted download.
    public func resume() {
        control.map { $0.pointer.pointee.resume($0.pointer) }
    }

    /// Cancels the download; Chromium removes its partial file.
    public func cancel() {
        control.map { $0.pointer.pointee.cancel($0.pointer) }
    }

    init(_ snapshot: Snapshot, browser: CefBrowser?, profile: CefProfile?) {
        chromiumID = snapshot.id
        url = snapshot.url
        originalURL = snapshot.originalURL
        startDate = snapshot.startDate
        endDate = snapshot.endDate
        suggestedFilename = snapshot.suggestedFilename
        mimeType = snapshot.mimeType
        fileURL = snapshot.fileURL
        receivedBytes = snapshot.receivedBytes
        expectedBytes = snapshot.expectedBytes
        bytesPerSecond = snapshot.bytesPerSecond
        state = snapshot.state
        self.browser = browser
        self.profile = profile
    }

    /// Takes Chromium's latest figures. Only what changed is set, so
    /// observers see only what moved.
    func apply(_ snapshot: Snapshot) {
        if url != snapshot.url { url = snapshot.url }
        if let original = snapshot.originalURL, originalURL != original { originalURL = original }
        if let start = snapshot.startDate, startDate != start { startDate = start }
        if endDate != snapshot.endDate { endDate = snapshot.endDate }
        if !snapshot.suggestedFilename.isEmpty, suggestedFilename != snapshot.suggestedFilename {
            suggestedFilename = snapshot.suggestedFilename
        }
        if !snapshot.mimeType.isEmpty, mimeType != snapshot.mimeType { mimeType = snapshot.mimeType }
        if let file = snapshot.fileURL, fileURL != file { fileURL = file }
        if receivedBytes != snapshot.receivedBytes { receivedBytes = snapshot.receivedBytes }
        if expectedBytes != snapshot.expectedBytes { expectedBytes = snapshot.expectedBytes }
        let rate = snapshot.state == .inProgress ? snapshot.bytesPerSecond : 0
        if bytesPerSecond != rate { bytesPerSecond = rate }
        if state != snapshot.state { state = snapshot.state }
    }
}

extension CefDownload {
    /// What Chromium reports about a download at one moment.
    struct Snapshot: Sendable, Equatable {
        var id: UInt32
        var url: URL?
        var originalURL: URL?
        var startDate: Date?
        var endDate: Date?
        var suggestedFilename = ""
        var mimeType = ""
        var fileURL: URL?
        var receivedBytes: Int64 = 0
        var expectedBytes: Int64?
        var bytesPerSecond: Int64 = 0
        var state = State.inProgress
    }

    /// The state for Chromium's flags; the first that applies wins.
    nonisolated static func state(
        isComplete: Bool, isCancelled: Bool, isInterrupted: Bool, isPaused: Bool, interruptReason: Int
    ) -> State {
        if isComplete { return .completed }
        if isCancelled { return .cancelled }
        if isInterrupted { return .interrupted(InterruptReason(rawValue: interruptReason)) }
        if isPaused { return .paused }
        return .inProgress
    }
}

extension CefDownload.Snapshot {
    /// Reads a borrowed `cef_download_item_t`.
    init(item: UnsafeMutablePointer<cef_download_item_t>) {
        let urlString = CefStringUtil.takingUserFree(item.pointee.get_url(item)) ?? ""
        let originalString = CefStringUtil.takingUserFree(item.pointee.get_original_url(item)) ?? ""
        let start = item.pointee.get_start_time(item), end = item.pointee.get_end_time(item)
        let path = CefStringUtil.takingUserFree(item.pointee.get_full_path(item)) ?? ""
        let total = item.pointee.get_total_bytes(item)
        self.init(
            id: item.pointee.get_id(item),
            url: URL(string: urlString),
            originalURL: originalString.isEmpty ? nil : URL(string: originalString),
            startDate: start.val == 0 ? nil : start.date,
            endDate: end.val == 0 ? nil : end.date,
            suggestedFilename: CefStringUtil.takingUserFree(item.pointee.get_suggested_file_name(item)) ?? "",
            mimeType: CefStringUtil.takingUserFree(item.pointee.get_mime_type(item)) ?? "",
            fileURL: path.isEmpty ? nil : URL(fileURLWithPath: path),
            receivedBytes: item.pointee.get_received_bytes(item),
            expectedBytes: total > 0 ? total : nil,
            bytesPerSecond: max(0, item.pointee.get_current_speed(item)),
            state: CefDownload.state(
                isComplete: item.pointee.is_complete(item) != 0,
                isCancelled: item.pointee.is_canceled(item) != 0,
                isInterrupted: item.pointee.is_interrupted(item) != 0,
                isPaused: item.pointee.is_paused(item) != 0,
                interruptReason: Int(item.pointee.get_interrupt_reason(item).rawValue))
        )
    }
}
