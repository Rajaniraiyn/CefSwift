import CCef
import Foundation
import CefBase

/// The state of a download, as listed in ``CefBrowser/downloads`` and
/// passed to ``CefBrowserDelegate``.
public struct CefDownload: Sendable, Equatable, Identifiable {
    /// Where a download is.
    public enum State: Sendable, Equatable {
        /// Receiving data.
        case inProgress
        /// Paused with ``CefBrowser/pauseDownload(_:)``.
        case paused
        /// Finished; the file is at ``CefDownload/destinationURL``.
        case completed
        /// Cancelled, by the app, the delegate or the user.
        case cancelled
        /// Stopped by an error. ``CefBrowser/resumeDownload(_:)`` tries
        /// again, from where it stopped when the server allows that.
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

    /// Chromium's identifier for the download, stable across updates.
    public var id: UInt32
    /// The download URL.
    public var url: URL?
    /// Bytes received so far.
    public var receivedBytes: Int64
    /// The expected size in bytes, `nil` when the server did not say.
    public var expectedBytes: Int64?
    public var state: State
    /// Where the file is being written, once a destination is known.
    public var destinationURL: URL?

    /// Whether ``CefBrowser/resumeDownload(_:)`` can continue the
    /// download: it is paused or interrupted.
    public var canResume: Bool {
        switch state {
        case .paused, .interrupted: true
        case .inProgress, .completed, .cancelled: false
        }
    }

    public init(
        id: UInt32,
        url: URL?,
        receivedBytes: Int64,
        expectedBytes: Int64?,
        state: State,
        destinationURL: URL?
    ) {
        self.id = id
        self.url = url
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.state = state
        self.destinationURL = destinationURL
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
        let total = item.pointee.get_total_bytes(item)
        self.init(
            id: item.pointee.get_id(item),
            url: URL(string: urlString),
            receivedBytes: item.pointee.get_received_bytes(item),
            expectedBytes: total > 0 ? total : nil,
            state: Self.state(
                isComplete: item.pointee.is_complete(item) != 0,
                isCancelled: item.pointee.is_canceled(item) != 0,
                isInterrupted: item.pointee.is_interrupted(item) != 0,
                isPaused: item.pointee.is_paused(item) != 0,
                interruptReason: Int(item.pointee.get_interrupt_reason(item).rawValue)),
            destinationURL: path.isEmpty ? nil : URL(fileURLWithPath: path)
        )
    }

    /// The state for Chromium's flags; the first that applies wins.
    static func state(
        isComplete: Bool, isCancelled: Bool, isInterrupted: Bool, isPaused: Bool, interruptReason: Int
    ) -> State {
        if isComplete { return .completed }
        if isCancelled { return .cancelled }
        if isInterrupted { return .interrupted(InterruptReason(rawValue: interruptReason)) }
        if isPaused { return .paused }
        return .inProgress
    }
}
