import Darwin
import Foundation
import os

/// The part of a body streamed with ``CefProfile/bytes(for:configuration:)``
/// that has arrived and not been read: chunks in memory, then, once
/// ``CefProfile/RequestConfiguration/streamMemoryLimit`` bytes are waiting,
/// a spill file. Free of CEF, so it can be tested without Chromium.
///
/// Chromium pushes the body on its IO thread and cannot be paused, so
/// ``append(_:)`` never waits: it keeps the chunk, hands it to a waiting
/// reader, or queues it for the spill file as it is. Unread bytes are, in
/// order: chunks in memory, which all arrived before the first spilled
/// byte; bytes in the file; a batch being written; chunks queued for the
/// file. Once anything is in the last three, every new chunk joins the
/// queue, until the reader has caught up; the file is then emptied and
/// chunks stay in memory again. The reader takes each part in that
/// order, taking a queued chunk directly when the file has nothing
/// before it, so a reader that keeps up never waits for the disk.
///
/// The file is opened on the first spill, in ``Limits/spillDirectory``,
/// and unlinked at once, so nothing is left on disk if the app crashes;
/// its descriptor is closed when the body ends, is cancelled, or fails.
/// File operations run on one serial queue: writes in batches, so the
/// disk keeps up with a fast network, and reads of written bytes only.
///
/// The end of the body, or its error, reaches the reader only after every
/// byte before it (``finish()``, ``fail(_:)``); cancelling, quitting and
/// a failed file operation drop what is unread (``cancel()``,
/// ``abort(_:)``).
final class URLRequestStreamBuffer: Sendable {
    struct Limits: Sendable {
        /// The most bytes kept in memory; a chunk is always taken when
        /// memory is empty, so the body moves whatever its chunks' size.
        var memory: Int
        var overflow: CefProfile.RequestConfiguration.StreamOverflowPolicy
        /// Where a spill file is made.
        var spillDirectory: URL
        /// For errors.
        var url: URL
    }

    /// What became of an appended chunk.
    enum Appended: Equatable, Sendable {
        /// Kept, handed to the reader, or queued for the spill file.
        case accepted
        /// The body already ended or was cancelled.
        case ignored
        /// Taking it would pass a limit; it was not taken, and the request
        /// should fail.
        case overflowed(Overflow)
    }

    enum Overflow: Equatable, Sendable {
        /// Memory is full and the policy is ``CefProfile/RequestConfiguration/StreamOverflowPolicy/fail``.
        case memory(limit: Int)
        /// The spill file would pass the policy's limit.
        case spill(limit: Int64)

        var detail: String {
            switch self {
            case .memory(let limit):
                "more than \(limit) received bytes were not read and the stream may not spill to disk; "
                    + "raise RequestConfiguration.streamMemoryLimit, read faster, or allow .spillToDisk"
            case .spill(let limit):
                "more than \(limit) received bytes waited in the stream's spill file; "
                    + "raise the .spillToDisk limit or read faster"
            }
        }
    }

    /// How far the body fell behind its reader.
    struct Statistics: Equatable, Sendable {
        /// The most unread bytes held in memory at once.
        var peakMemoryBytes = 0
        /// The most unread bytes in, or queued for, the spill file at once.
        var peakSpilledBytes: Int64 = 0
        /// All bytes that went through, or were queued for, the spill file.
        var spilledBytes: Int64 = 0
        /// The most bytes queued for the spill file and not yet written at
        /// once: memory too, while the disk is behind the network.
        var peakUnwrittenBytes = 0
    }

    private enum Phase {
        case receiving
        /// No more chunks; the result is the reader's once it has read
        /// everything before it.
        case ending(Result<Void, any Error>)
        /// The reader has had the end.
        case done
    }

    private struct State {
        // In memory, before anything spilled.
        var chunks: [Data] = []
        var head = 0
        var memoryBytes = 0

        // Spilled. Offsets in the file: reading has reached `spillRead`,
        // writing `spillWritten`; `inFlightBytes` are being written after
        // that, and `queued` (from `queuedHead`) follow, up to `spillEnd`.
        // All return to zero when the reader catches up.
        var spillRead: Int64 = 0
        var spillWritten: Int64 = 0
        var spillEnd: Int64 = 0
        var inFlightBytes = 0
        var queued: [Data] = []
        var queuedHead = 0
        var queuedBytes = 0
        var isWriting = false
        var isReadingSpill = false
        /// The file must be emptied before the next write.
        var needsTruncation = false

        /// A spill file is open, or will be by the next write.
        var hasFile = false
        var needsOpen = false
        /// No file operation may start any more.
        var isFileClosed = false
        /// Cancelled, quitting, or a file operation failed: unread bytes
        /// were dropped.
        var isDiscarded = false
        var phase = Phase.receiving
        var waiter: CheckedContinuation<Data?, any Error>?
        var statistics = Statistics()
        var fileFailureHandler: (@Sendable (any Error) -> Void)?

        var hasSpilled: Bool { spillEnd != spillRead }
        var hasQueued: Bool { queuedHead < queued.count }
    }

    /// The most read back from the spill file at once.
    static let spillReadSize = 1 << 20
    /// The most written to it at once, in bytes and in chunks.
    static let spillWriteSize = 8 << 20
    static let spillWriteChunks = 64

    let limits: Limits
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "CefSwift.ResponseBody.spill", qos: .userInitiated)
    /// The spill file's descriptor, or -1. Used only by jobs on `queue`;
    /// the lock only satisfies the compiler, it is never contended.
    private let descriptor = OSAllocatedUnfairLock(initialState: Int32(-1))

    private static let openFiles = OSAllocatedUnfairLock(initialState: 0)

    /// Spill files open in the process, for SelfTest.
    static var openFileCount: Int { openFiles.withLock { $0 } }

    init(limits: Limits) {
        var limits = limits
        limits.memory = max(limits.memory, 1)
        self.limits = limits
    }

    /// Called, on the file queue, when the spill file cannot be made,
    /// written or read; the body has already failed with the error.
    func onFileFailure(_ handler: @escaping @Sendable (any Error) -> Void) {
        state.withLock { $0.fileFailureHandler = handler }
    }

    var statistics: Statistics { state.withLock { $0.statistics } }

    /// Whether this body has a spill file open, or its opening queued.
    var hasSpillFile: Bool { state.withLock { $0.hasFile } }

    /// Whether the spill file's descriptor is open, as of the last file
    /// operation; for tests, after ``fileOperationsFinished()``.
    var isSpillFileOpen: Bool { descriptor.withLock { $0 >= 0 } }

    // MARK: Receiving

    /// Takes a received chunk. Never blocks: a chunk for the spill file is
    /// queued for the file queue as it is.
    func append(_ chunk: Data) -> Appended {
        guard !chunk.isEmpty else { return .accepted }
        enum Action { case none, hand(CheckedContinuation<Data?, any Error>), write }
        let (appended, action) = state.withLock { s -> (Appended, Action) in
            guard case .receiving = s.phase, !s.isDiscarded else { return (.ignored, .none) }
            // Nothing spilled: memory, unless it is full.
            if !s.hasSpilled {
                if s.head == s.chunks.count, let waiter = s.waiter {
                    s.waiter = nil
                    return (.accepted, .hand(waiter))
                }
                if s.memoryBytes == 0 || s.memoryBytes + chunk.count <= limits.memory {
                    s.chunks.append(chunk)
                    s.memoryBytes += chunk.count
                    s.statistics.peakMemoryBytes = max(s.statistics.peakMemoryBytes, s.memoryBytes)
                    return (.accepted, .none)
                }
            }
            guard case .spillToDisk(let cap) = limits.overflow else {
                return (.overflowed(.memory(limit: limits.memory)), .none)
            }
            let count = Int64(chunk.count)
            if let cap, s.spillEnd - s.spillRead + count > cap { return (.overflowed(.spill(limit: cap)), .none) }
            if !s.hasFile {
                s.hasFile = true
                s.needsOpen = true
            }
            s.queued.append(chunk)
            s.queuedBytes += chunk.count
            s.spillEnd += count
            s.statistics.spilledBytes += count
            s.statistics.peakSpilledBytes = max(s.statistics.peakSpilledBytes, s.spillEnd - s.spillRead)
            s.statistics.peakUnwrittenBytes = max(s.statistics.peakUnwrittenBytes, s.queuedBytes + s.inFlightBytes)
            guard !s.isWriting else { return (.accepted, .none) }
            s.isWriting = true
            return (.accepted, .write)
        }
        switch action {
        case .none: break
        case .hand(let waiter): waiter.resume(returning: chunk)
        case .write: queue.async { self.writeBatch() }
        }
        return appended
    }

    /// The body ended; the reader gets the end after the last byte.
    func finish() { end(with: .success(())) }

    /// The request failed; the reader gets `error` after the bytes that
    /// arrived before it.
    func fail(_ error: any Error) { end(with: .failure(error)) }

    private func end(with result: Result<Void, any Error>) {
        let (waiter, closes) = state.withLock { s -> (CheckedContinuation<Data?, any Error>?, Bool) in
            guard case .receiving = s.phase, !s.isDiscarded else { return (nil, false) }
            s.phase = .ending(result)
            // A reader waits only when nothing is unread.
            guard let waiter = s.waiter, s.head == s.chunks.count, !s.hasSpilled else { return (nil, false) }
            s.waiter = nil
            s.phase = .done
            return (waiter, Self.closeFile(&s))
        }
        if closes { queueClose() }
        waiter?.resume(with: result.map { nil })
    }

    /// Drops what is unread and closes the spill file; the reader gets
    /// `error` next. Does nothing once the reader has had the end.
    func abort(_ error: any Error) { discard(ending: .failure(error)) }

    /// Drops what is unread and closes the spill file; the reader gets the
    /// end next. For cancellation: the reader checks its task.
    func cancel() { discard(ending: .success(())) }

    private func discard(ending result: Result<Void, any Error>) {
        let (waiter, closes) = state.withLock { s -> (CheckedContinuation<Data?, any Error>?, Bool) in
            if case .done = s.phase { return (nil, false) }
            if s.isDiscarded { return (nil, false) }
            s.isDiscarded = true
            s.chunks = []
            s.head = 0
            s.memoryBytes = 0
            s.queued = []
            s.queuedHead = 0
            s.queuedBytes = 0
            s.spillRead = 0
            s.spillWritten = 0
            s.spillEnd = 0
            let closes = Self.closeFile(&s)
            guard let waiter = s.waiter else {
                s.phase = .ending(result)
                return (nil, closes)
            }
            s.waiter = nil
            s.phase = .done
            return (waiter, closes)
        }
        if closes { queueClose() }
        waiter?.resume(with: result.map { nil })
    }

    // MARK: Reading

    /// The next chunk, in the order they arrived; `nil` at the end, or
    /// once cancelled. One reader at a time.
    func next() async throws -> Data? {
        // Most chunks are in memory: no continuation.
        let ready = state.withLock { s -> Data? in s.waiter == nil ? Self.takeReady(&s) : nil }
        if let ready { return ready }
        return try await withCheckedThrowingContinuation { continuation in
            enum Action { case resume(Result<Data?, any Error>), read(offset: Int64, count: Int), wait }
            let (action, closes) = state.withLock { s -> (Action, Bool) in
                if s.waiter != nil {
                    return (.resume(.failure(CefError.operationFailed("A response body is read by one loop at a time"))), false)
                }
                if let chunk = Self.takeReady(&s) { return (.resume(.success(chunk)), false) }
                if s.hasSpilled {
                    // In the file, or being written: wait for a read, or
                    // for the write, which starts the read.
                    s.waiter = continuation
                    return (Self.startRead(&s).map { .read(offset: $0.offset, count: $0.count) } ?? .wait, false)
                }
                switch s.phase {
                case .receiving:
                    s.waiter = continuation
                    return (.wait, false)
                case .ending(let result):
                    s.phase = .done
                    return (.resume(result.map { nil }), Self.closeFile(&s))
                case .done:
                    return (.resume(.success(nil)), false)
                }
            }
            if closes { queueClose() }
            switch action {
            case .resume(let result): continuation.resume(with: result)
            case .read(let offset, let count): queue.async { self.read(count, at: offset) }
            case .wait: break
            }
        }
    }

    /// The next chunk when it needs no file operation: from memory, or a
    /// queued chunk when the file has nothing unread before it.
    private static func takeReady(_ s: inout State) -> Data? {
        if s.head < s.chunks.count {
            let chunk = s.chunks[s.head]
            s.chunks[s.head] = Data()
            s.head += 1
            s.memoryBytes -= chunk.count
            compact(&s.chunks, head: &s.head)
            return chunk
        }
        guard s.spillRead == s.spillWritten, s.inFlightBytes == 0, s.hasQueued else { return nil }
        let chunk = s.queued[s.queuedHead]
        s.queued[s.queuedHead] = Data()
        s.queuedHead += 1
        s.queuedBytes -= chunk.count
        compact(&s.queued, head: &s.queuedHead)
        // Never written: the file's next write starts after it.
        s.spillRead += Int64(chunk.count)
        s.spillWritten = s.spillRead
        resetIfCaughtUp(&s)
        return chunk
    }

    /// A read of written bytes, unless one is running or none are there.
    private static func startRead(_ s: inout State) -> (offset: Int64, count: Int)? {
        guard !s.isReadingSpill, s.spillRead < s.spillWritten else { return nil }
        s.isReadingSpill = true
        return (s.spillRead, Int(min(Int64(spillReadSize), s.spillWritten - s.spillRead)))
    }

    /// The reader has everything spilled: back to memory, with the file
    /// emptied before its next write.
    private static func resetIfCaughtUp(_ s: inout State) {
        guard s.spillRead == s.spillEnd, s.spillEnd > 0 else { return }
        if s.spillWritten > 0 { s.needsTruncation = true }
        s.spillRead = 0
        s.spillWritten = 0
        s.spillEnd = 0
    }

    private static func compact(_ chunks: inout [Data], head: inout Int) {
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    /// Marks the file closed; true when a close must be queued.
    private static func closeFile(_ s: inout State) -> Bool {
        s.isFileClosed = true
        defer { s.hasFile = false }
        return s.hasFile
    }

    // MARK: File queue

    /// Returns once every file operation queued so far has run, such as the
    /// close that ending or cancelling queued.
    func fileOperationsFinished() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// Writes the queued chunks, a batch per job so that reads can run in
    /// between.
    private func writeBatch() {
        struct Batch { var chunks: ArraySlice<Data>; var offset: Int64; var opens: Bool; var truncates: Bool }
        let batch = state.withLock { s -> Batch? in
            guard !s.isFileClosed, s.hasQueued else {
                s.isWriting = false
                return nil
            }
            var end = s.queuedHead
            var bytes = 0
            while end < s.queued.count, end - s.queuedHead < Self.spillWriteChunks, bytes < Self.spillWriteSize {
                bytes += s.queued[end].count
                end += 1
            }
            let batch = Batch(chunks: s.queued[s.queuedHead..<end], offset: s.spillWritten, opens: s.needsOpen, truncates: s.needsTruncation)
            for index in s.queuedHead..<end { s.queued[index] = Data() }
            s.queuedHead = end
            s.queuedBytes -= bytes
            Self.compact(&s.queued, head: &s.queuedHead)
            s.inFlightBytes = bytes
            s.needsOpen = false
            s.needsTruncation = false
            return batch
        }
        guard let batch else { return }
        do {
            if batch.opens { try openFile() }
            let fd = descriptor.withLock { $0 }
            if batch.truncates, ftruncate(fd, 0) != 0 { throw fileError("could not empty the response's spill file") }
            try Self.write(batch.chunks, to: fd, at: batch.offset) { self.fileError("could not write the response's spill file") }
        } catch {
            return fileFailed(error)
        }
        let (writesMore, read) = state.withLock { s -> (Bool, (offset: Int64, count: Int)?) in
            guard !s.isDiscarded else {
                s.isWriting = false
                return (false, nil)
            }
            s.spillWritten += Int64(s.inFlightBytes)
            s.inFlightBytes = 0
            let read = s.waiter != nil ? Self.startRead(&s) : nil
            s.isWriting = s.hasQueued
            return (s.isWriting, read)
        }
        if let read { self.read(read.count, at: read.offset) }
        if writesMore { queue.async { self.writeBatch() } }
    }

    /// Writes `chunks` contiguously at `offset`, with as few calls as it can.
    private static func write(_ chunks: ArraySlice<Data>, to fd: Int32, at offset: Int64, error: () -> any Error) throws {
        var offset = off_t(offset)
        var pending = Array(chunks)
        var skip = 0  // bytes of pending[0] already written
        while !pending.isEmpty {
            let written: Int = withIOVectors(pending, skipping: skip) { pwritev(fd, $0.baseAddress, Int32($0.count), offset) }
            if written < 0 {
                if errno == EINTR { continue }
                throw error()
            }
            offset += off_t(written)
            var remaining = written + skip
            skip = 0
            while let first = pending.first, remaining >= first.count {
                remaining -= first.count
                pending.removeFirst()
            }
            skip = remaining
        }
    }

    /// Calls `body` with an `iovec` for each chunk, the first starting
    /// `skip` bytes in, nesting one `withUnsafeBytes` per chunk (at most
    /// ``spillWriteChunks`` deep) so that every pointer is valid.
    private static func withIOVectors<R>(_ chunks: [Data], skipping skip: Int, _ body: (UnsafeBufferPointer<iovec>) -> R) -> R {
        func nest(_ index: Int, _ vectors: inout [iovec]) -> R {
            guard index < chunks.count else { return vectors.withUnsafeBufferPointer(body) }
            return chunks[index].withUnsafeBytes { bytes in
                let start = index == 0 ? skip : 0
                vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress! + start), iov_len: bytes.count - start))
                return nest(index + 1, &vectors)
            }
        }
        var vectors: [iovec] = []
        vectors.reserveCapacity(chunks.count)
        return nest(0, &vectors)
    }

    private func read(_ count: Int, at offset: Int64) {
        guard !state.withLock({ $0.isFileClosed }) else { return }
        let fd = descriptor.withLock { $0 }
        var data = Data(count: count)
        do {
            try data.withUnsafeMutableBytes { bytes in
                var done = 0
                while done < count {
                    let n = pread(fd, bytes.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { throw fileError("could not read the response's spill file") }
                    done += n
                }
            }
        } catch {
            return fileFailed(error)
        }
        let chunk = data
        let waiter = state.withLock { s -> CheckedContinuation<Data?, any Error>? in
            guard !s.isDiscarded else { return nil }
            s.isReadingSpill = false
            s.spillRead += Int64(count)
            Self.resetIfCaughtUp(&s)
            if let waiter = s.waiter {
                s.waiter = nil
                return waiter
            }
            // No one waits (not expected): keep the bytes for the next read.
            s.chunks.insert(chunk, at: s.head)
            s.memoryBytes += chunk.count
            return nil
        }
        waiter?.resume(returning: chunk)
    }

    private func openFile() throws {
        let name = ".cefswift-response-\(UUID().uuidString)"
        let temporary = FileManager.default.temporaryDirectory
        var opened = Self.openUnlinked(in: limits.spillDirectory, name: name)
        if opened < 0, limits.spillDirectory.standardizedFileURL != temporary.standardizedFileURL {
            opened = Self.openUnlinked(in: temporary, name: name)
        }
        guard opened >= 0 else { throw fileError("could not create a spill file for the response in \(limits.spillDirectory.path)") }
        let fd = opened
        descriptor.withLock { $0 = fd }
        Self.openFiles.withLock { $0 += 1 }
    }

    /// A new file, opened for reading and writing, already unlinked.
    private static func openUnlinked(in directory: URL, name: String) -> Int32 {
        let path = directory.appendingPathComponent(name, isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        unlink(path)
        return fd
    }

    private func queueClose() {
        queue.async {
            let fd = self.descriptor.withLock { fd in
                defer { fd = -1 }
                return fd
            }
            guard fd >= 0 else { return }
            close(fd)
            Self.openFiles.withLock { $0 -= 1 }
        }
    }

    private func fileError(_ detail: String) -> CefLoadError {
        let code = errno
        // FILE_NO_SPACE, or FAILED.
        return CefLoadError(netError: code == ENOSPC ? -18 : -2, url: limits.url,
                            detail: "\(detail): \(String(cString: strerror(code)))")
    }

    private func fileFailed(_ error: any Error) {
        let handler = state.withLock { $0.fileFailureHandler }
        abort(error)
        handler?(error)
    }
}
