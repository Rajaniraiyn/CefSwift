import Foundation
import os
import Testing

@testable import CefKit

// The parts of CefProfile.bytes(for:) and download(for:to:) that need no
// Chromium: the stream buffer that keeps unread bytes in memory, then in a
// spill file, and the writer that puts a download into its file.

@Suite struct URLRequestStreamBufferTests {
    private struct Failure: Error, Equatable { var id = 1 }

    /// A buffer spilling into a directory of the test's own.
    private func makeBuffer(memory: Int, overflow: CefProfile.RequestConfiguration.StreamOverflowPolicy = .spillToDisk(limit: nil))
        throws -> (URLRequestStreamBuffer, URL)
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cefswift-stream-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let limits = URLRequestStreamBuffer.Limits(memory: memory, overflow: overflow, spillDirectory: directory,
                                                   url: URL(string: "https://example.com/body")!)
        return (URLRequestStreamBuffer(limits: limits), directory)
    }

    private func bytes(_ range: Range<Int>) -> Data { Data(range.map { UInt8($0 % 251) }) }

    /// Reads until the end, or until `count` bytes when given.
    private func read(_ buffer: URLRequestStreamBuffer, count: Int? = nil) async throws -> Data {
        var data = Data()
        while count.map({ data.count < $0 }) ?? true, let chunk = try await buffer.next() { data.append(chunk) }
        return data
    }

    private func entries(_ directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["unreadable"]
    }

    @Test func chunksInMemoryComeBackInOrderThenTheEnd() async throws {
        let (buffer, directory) = try makeBuffer(memory: 100)
        defer { try? FileManager.default.removeItem(at: directory) }
        for part in [0..<10, 10..<30, 30..<35] { #expect(buffer.append(bytes(part)) == .accepted) }
        buffer.finish()
        #expect(try await read(buffer) == bytes(0..<35))
        #expect(try await buffer.next() == nil)
        #expect(buffer.statistics == .init(peakMemoryBytes: 35, peakSpilledBytes: 0, spilledBytes: 0))
        #expect(!buffer.hasSpillFile)
    }

    @Test func bytesPastTheMemoryLimitSpillAndComeBackExactly() async throws {
        let (buffer, directory) = try makeBuffer(memory: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        for start in stride(from: 0, to: 40, by: 4) { #expect(buffer.append(bytes(start..<start + 4)) == .accepted) }
        buffer.finish()
        await buffer.fileOperationsFinished()
        #expect(buffer.isSpillFileOpen)
        // Unlinked as soon as it was made.
        #expect(entries(directory).isEmpty)
        let statistics = buffer.statistics
        #expect(statistics.peakMemoryBytes == 8 && statistics.peakSpilledBytes == 32 && statistics.spilledBytes == 32)
        #expect(statistics.peakUnwrittenBytes > 0 && statistics.peakUnwrittenBytes <= 32)
        #expect(try await read(buffer) == bytes(0..<40))
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
        #expect(!buffer.hasSpillFile)
    }

    @Test func manyBatchesAndReadsComeBackExactly() async throws {
        let (buffer, directory) = try makeBuffer(memory: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 300 chunks: several write batches, and several 1 MB reads.
        let size = 10_007
        for index in 0..<300 { _ = buffer.append(bytes(index * size..<(index + 1) * size)) }
        buffer.finish()
        await buffer.fileOperationsFinished()
        #expect(buffer.statistics.spilledBytes == Int64(299 * size))
        #expect(try await read(buffer) == bytes(0..<300 * size))
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
    }

    @Test func aDrainedSpillReturnsToMemory() async throws {
        let (buffer, directory) = try makeBuffer(memory: 8)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = buffer.append(bytes(0..<4))
        _ = buffer.append(bytes(4..<8))
        _ = buffer.append(bytes(8..<12))     // spilled
        #expect(buffer.statistics.spilledBytes == 4)
        #expect(try await read(buffer, count: 12) == bytes(0..<12))
        _ = buffer.append(bytes(12..<16))    // memory again
        #expect(buffer.statistics.spilledBytes == 4)
        // A second spill writes from the start of the truncated file.
        _ = buffer.append(bytes(16..<20))
        _ = buffer.append(bytes(20..<24))    // spilled
        #expect(buffer.statistics.spilledBytes == 8)
        buffer.finish()
        #expect(try await read(buffer) == bytes(12..<24))
    }

    @Test func whileTheFileHoldsBytesNewChunksFollowThem() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = buffer.append(bytes(0..<4))
        _ = buffer.append(bytes(4..<8))      // spilled
        #expect(try await buffer.next() == bytes(0..<4))
        // Memory is empty, but the file is not: this goes after it.
        _ = buffer.append(bytes(8..<10))
        #expect(buffer.statistics.spilledBytes == 6)
        buffer.finish()
        #expect(try await read(buffer) == bytes(4..<10))
    }

    @Test func anyInterleavingOfAppendsAndReadsKeepsEveryByteInOrder() async throws {
        var seed: UInt64 = 0x5EED
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for round in 0..<20 {
            let (buffer, directory) = try makeBuffer(memory: 1 + random(300))
            defer { try? FileManager.default.removeItem(at: directory) }
            var appended = 0
            var received = Data()
            let total = 5_000 + round * 500
            while appended < total {
                if random(3) > 0 {
                    let count = min(1 + random(200), total - appended)
                    #expect(buffer.append(bytes(appended..<appended + count)) == .accepted)
                    appended += count
                } else if received.count < appended {
                    received.append(try #require(try await buffer.next()))
                }
            }
            buffer.finish()
            received.append(try await read(buffer))
            #expect(received == bytes(0..<total), "round \(round)")
            await buffer.fileOperationsFinished()
            #expect(!buffer.isSpillFileOpen)
        }
    }

    @Test func aProducerOnAnotherThreadAndASlowReaderAgreeOnEveryByte() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4096)
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = 2 << 20
        let producer = Thread {
            var sent = 0
            var size = 1
            while sent < total {
                let count = min(size, total - sent)
                _ = buffer.append(self.bytes(sent..<sent + count))
                sent += count
                size = size % 3000 + 37
            }
            buffer.finish()
        }
        producer.start()
        var received = Data()
        var reads = 0
        while let chunk = try await buffer.next() {
            received.append(chunk)
            reads += 1
            if reads % 50 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(received == bytes(0..<total))
        #expect(buffer.statistics.peakMemoryBytes <= 4096 + 3000)
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
    }

    @Test func aWaitingReaderIsHandedTheNextChunk() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = Task { try await buffer.next() }
        try await Task.sleep(for: .milliseconds(50))
        _ = buffer.append(bytes(0..<16))
        #expect(try await reader.value == bytes(0..<16))
        #expect(buffer.statistics.peakMemoryBytes == 0)
    }

    @Test func aWaitingReaderGetsTheEnd() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = Task { try await buffer.next() }
        try await Task.sleep(for: .milliseconds(50))
        buffer.finish()
        #expect(try await reader.value == nil)
    }

    @Test func anErrorComesAfterEveryByteBeforeIt() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = buffer.append(bytes(0..<4))
        _ = buffer.append(bytes(4..<8))      // spilled
        buffer.fail(Failure())
        // Later chunks and ends are ignored.
        #expect(buffer.append(bytes(8..<9)) == .ignored)
        buffer.finish()
        #expect(try await buffer.next() == bytes(0..<4))
        #expect(try await buffer.next() == bytes(4..<8))
        await #expect(throws: Failure()) { try await buffer.next() }
        #expect(try await buffer.next() == nil)
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
    }

    @Test func cancellingMidSpillDropsTheBytesAndClosesTheFile() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        for start in stride(from: 0, to: 64, by: 4) { _ = buffer.append(bytes(start..<start + 4)) }
        #expect(try await buffer.next() == bytes(0..<4))
        await buffer.fileOperationsFinished()
        #expect(buffer.isSpillFileOpen)
        buffer.cancel()
        #expect(try await buffer.next() == nil)
        #expect(buffer.append(bytes(0..<4)) == .ignored)
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
        #expect(!buffer.hasSpillFile)
        #expect(entries(directory).isEmpty)
    }

    @Test func cancellingWakesAWaitingReader() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = Task { try await buffer.next() }
        try await Task.sleep(for: .milliseconds(50))
        buffer.cancel()
        #expect(try await reader.value == nil)
    }

    @Test func abortingDropsUnreadBytesAndThrowsAtOnce() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4)
        defer { try? FileManager.default.removeItem(at: directory) }
        for start in stride(from: 0, to: 16, by: 4) { _ = buffer.append(bytes(start..<start + 4)) }
        buffer.abort(Failure(id: 2))
        await #expect(throws: Failure(id: 2)) { try await buffer.next() }
        await buffer.fileOperationsFinished()
        #expect(!buffer.isSpillFileOpen)
    }

    @Test func theFailPolicyRefusesTheChunkPastTheMemoryLimit() async throws {
        let (buffer, directory) = try makeBuffer(memory: 8, overflow: .fail)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(buffer.append(bytes(0..<4)) == .accepted)
        #expect(buffer.append(bytes(4..<8)) == .accepted)
        #expect(buffer.append(bytes(8..<12)) == .overflowed(.memory(limit: 8)))
        #expect(!buffer.hasSpillFile)
        buffer.fail(Failure())
        #expect(try await read(buffer, count: 8) == bytes(0..<8))
        await #expect(throws: Failure()) { try await buffer.next() }
    }

    @Test func aChunkLargerThanTheLimitIsTakenWhenMemoryIsEmpty() throws {
        let (buffer, directory) = try makeBuffer(memory: 4, overflow: .fail)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(buffer.append(bytes(0..<100)) == .accepted)
        #expect(buffer.append(bytes(0..<1)) == .overflowed(.memory(limit: 4)))
    }

    @Test func theSpillLimitCapsTheFile() async throws {
        let (buffer, directory) = try makeBuffer(memory: 4, overflow: .spillToDisk(limit: 8))
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(buffer.append(bytes(0..<4)) == .accepted)     // memory
        #expect(buffer.append(bytes(4..<8)) == .accepted)     // file: 4
        #expect(buffer.append(bytes(8..<12)) == .accepted)    // file: 8
        #expect(buffer.append(bytes(12..<16)) == .overflowed(.spill(limit: 8)))
        #expect(buffer.statistics.peakSpilledBytes == 8)
        // Reading the file empties it, and the cap counts from zero again.
        #expect(try await read(buffer, count: 12) == bytes(0..<12))
        #expect(buffer.append(bytes(12..<16)) == .accepted)
    }

    @Test func overflowsNameTheirLimit() {
        #expect(URLRequestStreamBuffer.Overflow.memory(limit: 8).detail.contains("streamMemoryLimit"))
        #expect(URLRequestStreamBuffer.Overflow.spill(limit: 8).detail.contains(".spillToDisk"))
    }

    @Test func theDefaultsSpillWithoutALimit() {
        let configuration = CefProfile.RequestConfiguration()
        #expect(configuration.streamOverflow == .spillToDisk(limit: nil))
        #expect(configuration.streamMemoryLimit == 16 << 20)
    }
}

@Suite struct URLRequestFileWriterTests {
    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cefswift-download-tests-\(UUID().uuidString).bin")
    }

    private func finish(_ writer: URLRequestFileWriter) async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }

    @Test func chunksAreWrittenInOrderAndReplaceTheFile() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 9, count: 1000).write(to: url)
        let writer = URLRequestFileWriter(destination: url)
        writer.open()
        writer.write(Data([1, 2, 3]))
        writer.write(Data([4, 5]))
        try await finish(writer).get()
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5]))
    }

    @Test func anEmptyBodyMakesAnEmptyFile() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = URLRequestFileWriter(destination: url)
        writer.open()
        try await finish(writer).get()
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func discardingRemovesThePartialFile() async throws {
        let url = destination()
        let writer = URLRequestFileWriter(destination: url)
        writer.open()
        writer.write(Data([1, 2, 3]))
        await withCheckedContinuation { continuation in writer.discard { continuation.resume() } }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aDestinationThatCannotBeOpenedFails() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cefswift-missing-\(UUID().uuidString)/file.bin")
        let writer = URLRequestFileWriter(destination: url)
        let reported = Flag()
        writer.onFailure { _ in reported.set() }
        writer.open()
        writer.write(Data([1]))
        let result = await finish(writer)
        guard case .failure(let error) = result else { Issue.record("it succeeded"); return }
        #expect((error as? CocoaError)?.code == .fileNoSuchFile)
        #expect(reported.isSet)
    }
}

private final class Flag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    func set() { flag.withLock { $0 = true } }
    var isSet: Bool { flag.withLock { $0 } }
}
