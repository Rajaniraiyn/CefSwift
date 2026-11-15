import Darwin
import Foundation
import os

/// Writes a body from ``CefProfile/download(for:to:configuration:)``
/// straight into its destination, as Chromium hands it over.
///
/// Chromium's IO thread only queues each chunk; opening, writing and
/// closing run in order on a serial queue of the writer's own. No reader
/// can fall behind, so a download never overflows; what waits in memory
/// is what the disk has not taken yet.
final class URLRequestFileWriter: Sendable {
    let destination: URL
    private let queue = DispatchQueue(label: "CefSwift.download", qos: .userInitiated)
    /// The destination's descriptor, or -1. Used only by jobs on `queue`;
    /// the lock only satisfies the compiler, it is never contended.
    private let descriptor = OSAllocatedUnfairLock(initialState: Int32(-1))
    /// The first failed file operation; later writes are skipped.
    private let failure = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
    private let failureHandler = OSAllocatedUnfairLock<(@Sendable (any Error) -> Void)?>(initialState: nil)

    init(destination: URL) {
        self.destination = destination
    }

    /// Called, on the writer's queue, when the destination cannot be
    /// opened or written.
    func onFailure(_ handler: @escaping @Sendable (any Error) -> Void) {
        failureHandler.withLock { $0 = handler }
    }

    /// Creates the destination, or empties it.
    func open() {
        queue.async {
            let fd = Darwin.open(self.destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            if fd < 0 { return self.failed(errno) }
            self.descriptor.withLock { $0 = fd }
        }
    }

    func write(_ chunk: Data) {
        queue.async {
            guard self.failure.withLock({ $0 == nil }) else { return }
            let fd = self.descriptor.withLock { $0 }
            let code: Int32? = chunk.withUnsafeBytes { bytes in
                var done = 0
                while done < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    done += n
                }
                return nil
            }
            if let code { self.failed(code) }
        }
    }

    /// Closes the destination once every chunk is written; a failed
    /// write removes it and is the result.
    func finish(_ completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        queue.async {
            let error = self.failure.withLock { $0 }
            let closed = self.closeDescriptor()
            if let error = error ?? closed.map(self.error(for:)) {
                try? FileManager.default.removeItem(at: self.destination)
                return completion(.failure(error))
            }
            completion(.success(()))
        }
    }

    /// Closes and removes the destination, once queued writes have run.
    func discard(_ completion: @escaping @Sendable () -> Void) {
        queue.async {
            _ = self.closeDescriptor()
            try? FileManager.default.removeItem(at: self.destination)
            completion()
        }
    }

    /// Returns once every operation queued so far has run.
    func operationsFinished() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// Closes the descriptor; the `errno` of a failed close.
    private func closeDescriptor() -> Int32? {
        let fd = descriptor.withLock { fd in
            defer { fd = -1 }
            return fd
        }
        guard fd >= 0 else { return nil }
        return close(fd) == 0 ? nil : errno
    }

    private func failed(_ code: Int32) {
        let error = error(for: code)
        let isFirst = failure.withLock { failure in
            guard failure == nil else { return false }
            failure = error
            return true
        }
        if isFirst { failureHandler.withLock { $0 }?(error) }
    }

    private func error(for code: Int32) -> any Error {
        let kind: CocoaError.Code = switch code {
        case ENOENT, ENOTDIR: .fileNoSuchFile
        case EACCES, EPERM, EROFS: .fileWriteNoPermission
        case ENOSPC, EDQUOT: .fileWriteOutOfSpace
        default: .fileWriteUnknown
        }
        let underlying = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: underlying])
    }
}
