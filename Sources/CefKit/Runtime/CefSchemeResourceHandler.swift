import CCef
import Foundation
import UniformTypeIdentifiers
import CefBase
import os

// MARK: - CEF structs

/// Owner of a `cef_scheme_handler_factory_t`, which creates a
/// ``SchemeResourceHandler`` for each request on the IO thread.
final class SchemeHandlerFactory: Sendable {
    private let handler: any CefSchemeHandler

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    /// Builds the factory. The returned pointer carries one reference for
    /// the caller, which registration hands to CEF.
    func makeFactory() -> UnsafeMutablePointer<cef_scheme_handler_factory_t> {
        let factory = cefAllocate(cef_scheme_handler_factory_t.self, owner: self)
        factory.pointee.create = { factorySelf, browser, frame, _, request in
            // The resource handler reads the request in `open`.
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(request)
            guard let owner = cefOwner(SchemeHandlerFactory.self, factorySelf) else { return nil }
            return SchemeResourceHandler(handler: owner.handler).makeHandler()
        }
        return factory
    }
}

/// Where a body's producer delivers chunks. Writing waits while the page
/// is more than ``SchemeResourceHandler/bufferLimit`` bytes behind, and
/// throws once the request is cancelled.
struct SchemeBodyWriter: Sendable {
    fileprivate let handler: SchemeResourceHandler

    func write(_ chunk: Data) async throws {
        try await handler.write(chunk)
    }
}

/// Owner of the `cef_resource_handler_t` for one request.
///
/// CEF calls `open`, `skip` and `read` in sequence from no fixed thread,
/// and `get_response_headers` and `cancel` on the IO thread; the body's
/// producer runs elsewhere. All of them meet in the locked ``State``. A
/// read that finds no data waits: CEF keeps its buffer until the read
/// callback runs, which the producer does when the next chunk arrives.
final class SchemeResourceHandler: Sendable {
    /// How far a producer may run ahead of the page.
    static let bufferLimit = 1 << 20

    /// A read CEF is waiting on.
    private struct PendingRead {
        nonisolated(unsafe) let buffer: UnsafeMutableRawPointer
        let capacity: Int
        let callback: CefRef<cef_resource_read_callback_t>
    }

    /// What `get_response_headers` reports.
    struct Head {
        var status: Int
        var headers: [String: String]
        var mimeType: String
        /// The number of bytes served, when known.
        var length: Int?
    }

    private struct State {
        var response: CefSchemeResponse?
        var head: Head?
        /// The request's `Range` header.
        var rangeHeader: String?
        /// Bytes still to serve, when a range limits them.
        var remaining: Int?
        /// Chunks not yet read, and how much of the first one has been.
        var chunks: [Data] = []
        var offset = 0
        var bufferedBytes = 0
        /// Bytes to drop from the front of the body, for a range request.
        var bytesToSkip = 0
        var isFinished = false
        var isCancelled = false
        var failureCode: Int32?
        var producer: Task<Void, Never>?
        var isProducerStarted = false
        var pendingRead: PendingRead?
        /// Writers waiting for the page to catch up.
        var writers: [CheckedContinuation<Void, any Error>] = []
        /// A file body's reader, once the first read opened it.
        var file: SchemeFileReader?
    }

    private let handler: any CefSchemeHandler
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    // MARK: Response

    private func install(_ response: CefSchemeResponse) -> Bool {
        let length = response.body.length
        return state.withLock { state in
            guard !state.isCancelled else { return false }
            state.response = response
            var head = Head(status: response.status, headers: response.headers, mimeType: response.mimeType, length: length)
            var skipped = 0
            // Ranges are answered here; Chromium's own skip calls are then
            // no-ops (see `skip`).
            if response.status == 200, let header = state.rangeHeader {
                switch SchemeByteRange(header: header, totalLength: length) {
                case .whole:
                    break
                case .partial(let range):
                    head.status = 206
                    head.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(length.map(String.init) ?? "*")"
                    head.length = range.count
                    skipped = range.lowerBound
                    state.remaining = range.count
                case .unsatisfiable:
                    head.status = 416
                    head.headers["Content-Range"] = "bytes */\(length ?? 0)"
                    head.length = 0
                    state.remaining = 0
                    state.isFinished = true
                    state.isProducerStarted = true
                }
            }
            if length != nil, head.headers.keys.allSatisfy({ $0.caseInsensitiveCompare("Accept-Ranges") != .orderedSame }) {
                head.headers["Accept-Ranges"] = "bytes"
            }
            state.head = head
            if !state.isProducerStarted, case .data(let data) = response.body.source {
                let kept = data.dropFirst(skipped)
                state.chunks = kept.isEmpty ? [] : [kept]
                state.bufferedBytes = kept.count
                state.isFinished = true
                state.isProducerStarted = true
            } else {
                state.bytesToSkip = skipped
            }
            return true
        }
    }

    private var currentHead: Head? {
        state.withLock { $0.head }
    }

    // MARK: Producing

    /// Starts reading a file or stream body; called with the state locked.
    private func startProducerIfNeeded(_ state: inout State) {
        guard !state.isProducerStarted, let response = state.response else { return }
        state.isProducerStarted = true
        let writer = SchemeBodyWriter(handler: self)
        switch response.body.source {
        case .data, .file:
            // Data is buffered whole by `install`; files are read by `read`.
            break
        case .stream(_, let pump):
            state.producer = Task { [weak self] in
                do {
                    try await pump(writer)
                    self?.finish(failureCode: nil)
                } catch is CancellationError {
                } catch {
                    self?.finish(failureCode: -2)
                }
            }
        }
    }

    fileprivate func write(_ chunk: Data) async throws {
        try Task.checkCancellation()
        let fulfilled: (CefRef<cef_resource_read_callback_t>, Int32)? = try state.withLock { state in
            guard !state.isCancelled else { throw CancellationError() }
            var kept = chunk
            if state.bytesToSkip > 0 {
                let dropped = min(state.bytesToSkip, kept.count)
                state.bytesToSkip -= dropped
                kept = Data(kept.dropFirst(dropped))
            }
            guard !kept.isEmpty else { return nil }
            state.chunks.append(kept)
            state.bufferedBytes += kept.count
            return Self.fulfillPendingRead(&state)
        }
        if let (callback, count) = fulfilled {
            callback.pointer.pointee.cont(callback.pointer, count)
        }
        // Wait while the page is behind.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumeNow: Result<Void, any Error>? = state.withLock { state in
                if state.isCancelled { return .failure(CancellationError()) }
                if state.bufferedBytes <= Self.bufferLimit { return .success(()) }
                state.writers.append(continuation)
                return nil
            }
            if let resumeNow { continuation.resume(with: resumeNow) }
        }
    }

    private func finish(failureCode: Int32?) {
        let fulfilled: (CefRef<cef_resource_read_callback_t>, Int32)? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            state.isFinished = true
            state.failureCode = failureCode
            return Self.fulfillPendingRead(&state)
        }
        if let (callback, count) = fulfilled {
            callback.pointer.pointee.cont(callback.pointer, count)
        }
    }

    /// Answers the waiting read, if data or the end has arrived. Returns
    /// the callback to run, outside the lock, with its result.
    private static func fulfillPendingRead(_ state: inout State) -> (CefRef<cef_resource_read_callback_t>, Int32)? {
        guard let read = state.pendingRead else { return nil }
        let count = copy(from: &state, into: read.buffer, capacity: read.capacity)
        if count > 0 {
            state.pendingRead = nil
            return (read.callback, Int32(count))
        }
        guard state.isFinished else { return nil }
        state.pendingRead = nil
        return (read.callback, state.failureCode ?? 0)
    }

    /// Copies buffered bytes into CEF's buffer, waking writers once the
    /// buffer has room. Returns the number of bytes copied.
    private static func copy(from state: inout State, into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int {
        let capacity = min(capacity, state.remaining ?? .max)
        var copied = 0
        while copied < capacity, let first = state.chunks.first {
            let count = min(capacity - copied, first.count - state.offset)
            first.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                (buffer + copied).copyMemory(from: base + state.offset, byteCount: count)
            }
            copied += count
            state.offset += count
            if state.offset == first.count {
                state.chunks.removeFirst()
                state.offset = 0
            }
        }
        state.bufferedBytes -= copied
        if let remaining = state.remaining {
            state.remaining = remaining - copied
            if remaining - copied == 0, !state.isFinished {
                // The range is served: stop the producer.
                state.isFinished = true
                state.chunks = []
                state.bufferedBytes = 0
                state.producer?.cancel()
                let writers = state.writers
                state.writers = []
                writers.forEach { $0.resume(throwing: CancellationError()) }
                return copied
            }
        }
        if state.bufferedBytes <= bufferLimit, !state.writers.isEmpty {
            let writers = state.writers
            state.writers = []
            writers.forEach { $0.resume() }
        }
        return copied
    }

    // MARK: CEF callbacks

    private func read(into buffer: UnsafeMutableRawPointer, capacity: Int, callback: CefRef<cef_resource_read_callback_t>) -> (handled: Bool, count: Int32) {
        if let file = fileReader() {
            // CEF calls `read` on its thread pool, where blocking file reads
            // are what Chromium does for its own files: the bytes go from
            // the file straight into CEF's buffer.
            let count = file.read(into: buffer, capacity: capacity)
            return count > 0 ? (true, Int32(count)) : (false, Int32(count))
        }
        // CEF keeps the buffer valid until the callback runs.
        nonisolated(unsafe) let buffer = buffer
        return state.withLock { state in
            let count = Self.copy(from: &state, into: buffer, capacity: capacity)
            if count > 0 { return (true, Int32(count)) }
            if state.isFinished || state.isCancelled {
                // Zero completes the response; a negative count fails it.
                return (false, state.failureCode ?? 0)
            }
            state.pendingRead = PendingRead(buffer: buffer, capacity: capacity, callback: callback)
            startProducerIfNeeded(&state)
            return (true, 0)
        }
    }

    /// The reader of a file body, opened on the first read.
    private func fileReader() -> SchemeFileReader? {
        state.withLock { state in
            if let file = state.file { return file }
            guard !state.isCancelled, case .file(let url)? = state.response?.body.source else { return nil }
            let file = SchemeFileReader(url: url, offset: state.bytesToSkip, remaining: state.remaining)
            state.bytesToSkip = 0
            state.file = file
            return file
        }
    }

    /// Chromium skips to the start of a requested range itself, but then
    /// reports the rest of the body with the handler's status and length.
    /// `install` answers ranges completely (status 206, `Content-Range`, the
    /// range's bytes only), so Chromium's skip has nothing left to do and
    /// is reported done.
    private func skip(_ count: Int64) -> Int64 {
        state.withLock { $0.response == nil ? -2 : count }  // -2: ERR_FAILED
    }

    private func cancel() {
        let (producer, writers) = state.withLock { state in
            state.isCancelled = true
            state.pendingRead = nil
            defer { state.writers = [] }
            return (state.producer, state.writers)
        }
        producer?.cancel()
        writers.forEach { $0.resume(throwing: CancellationError()) }
    }

    /// Builds the handler. The returned pointer carries one reference for the
    /// caller.
    func makeHandler() -> UnsafeMutablePointer<cef_resource_handler_t> {
        let resource = cefAllocate(cef_resource_handler_t.self, owner: self)

        resource.pointee.open = { handlerSelf, request, handleRequest, callback in
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let request, let handleRequest, let callback
            else {
                cefRelease(request)
                cefRelease(callback)
                handleRequest?.pointee = 1
                return 0  // cancel
            }
            // The request must not outlive this call, so copy what is needed.
            let captured = SchemeResourceHandler.capture(request)
            cefRelease(request)
            let range = captured.headers.first { $0.key.caseInsensitiveCompare("Range") == .orderedSame }?.value
            me.state.withLock { $0.rangeHeader = range }

            // Answer asynchronously, continuing the callback once the
            // response is ready. The handler runs with its own isolation.
            handleRequest.pointee = 0
            let pending = CefRef(adopting: callback)
            Task {
                let response = await me.handler.response(for: captured)
                if me.install(response) {
                    pending.pointer.pointee.cont(pending.pointer)
                }
            }
            return 1
        }

        resource.pointee.get_response_headers = { handlerSelf, cefResponse, responseLength, _ in
            defer { cefRelease(cefResponse) }
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let cefResponse,
                let head = me.currentHead
            else {
                responseLength?.pointee = 0
                return
            }
            cefResponse.pointee.set_status(cefResponse, Int32(head.status))
            CefStringUtil.withCefString(head.mimeType) { mime in
                cefResponse.pointee.set_mime_type(cefResponse, mime)
            }
            // Swift strings are UTF-8; say so, or Chromium guesses Latin-1.
            if head.mimeType.hasPrefix("text/") || head.mimeType.hasSuffix("json") {
                CefStringUtil.withCefString("utf-8") { cefResponse.pointee.set_charset(cefResponse, $0) }
            }
            if !head.headers.isEmpty, let map = cef_string_multimap_alloc() {
                for (name, value) in head.headers {
                    CefStringUtil.withCefString(name) { cefName in
                        CefStringUtil.withCefString(value) { cefValue in
                            _ = cef_string_multimap_append(map, cefName, cefValue)
                        }
                    }
                }
                cefResponse.pointee.set_header_map(cefResponse, map)
                cef_string_multimap_free(map)
            }
            // -1: read until the body ends.
            responseLength?.pointee = Int64(head.length ?? -1)
        }

        resource.pointee.skip = { handlerSelf, bytesToSkip, bytesSkipped, callback in
            // Answered synchronously; the callback is unused.
            cefRelease(callback)
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let bytesSkipped
            else { return 0 }
            let skipped = me.skip(bytesToSkip)
            bytesSkipped.pointee = skipped
            return skipped >= 0 ? 1 : 0
        }

        resource.pointee.read = { handlerSelf, dataOut, bytesToRead, bytesRead, callback in
            // Adopted before anything can return early.
            let callback = CefRef(adopting: callback)
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let dataOut, let bytesRead, let callback
            else { return 0 }
            let (handled, count) = me.read(into: dataOut, capacity: Int(bytesToRead), callback: callback)
            bytesRead.pointee = count
            return handled ? 1 : 0
        }

        resource.pointee.cancel = { handlerSelf in
            cefOwner(SchemeResourceHandler.self, handlerSelf)?.cancel()
        }

        return resource
    }

    /// Copies the URL, method, headers and body of a borrowed `cef_request_t`.
    private static func capture(_ request: UnsafeMutablePointer<cef_request_t>) -> CefSchemeRequest {
        let urlString = CefStringUtil.takingUserFree(request.pointee.get_url(request)) ?? ""
        let method = CefStringUtil.takingUserFree(request.pointee.get_method(request)) ?? "GET"

        var headers: [String: String] = [:]
        if let map = cef_string_multimap_alloc() {
            request.pointee.get_header_map(request, map)
            for index in 0..<cef_string_multimap_size(map) {
                var key = cef_string_t()
                var value = cef_string_t()
                if cef_string_multimap_key(map, index, &key) != 0,
                   cef_string_multimap_value(map, index, &value) != 0
                {
                    let name = CefStringUtil.string(from: key)
                    let headerValue = CefStringUtil.string(from: value)
                    headers[name] = headers[name].map { "\($0), \(headerValue)" } ?? headerValue
                }
                cef_string_utf16_clear(&key)
                cef_string_utf16_clear(&value)
            }
            cef_string_multimap_free(map)
        }

        var body: Data?
        if let postData = request.pointee.get_post_data(request) {
            defer { cefRelease(postData) }
            let count = postData.pointee.get_element_count(postData)
            if count > 0 {
                var elements = [UnsafeMutablePointer<cef_post_data_element_t>?](repeating: nil, count: count)
                var actualCount = count
                elements.withUnsafeMutableBufferPointer { buffer in
                    postData.pointee.get_elements(postData, &actualCount, buffer.baseAddress)
                }
                var collected = Data()
                for element in elements.prefix(actualCount).compactMap({ $0 }) {
                    defer { cefRelease(element) }
                    guard element.pointee.get_type(element) == PDE_TYPE_BYTES else { continue }
                    let byteCount = element.pointee.get_bytes_count(element)
                    guard byteCount > 0 else { continue }
                    var chunk = Data(count: byteCount)
                    chunk.withUnsafeMutableBytes { bytes in
                        _ = element.pointee.get_bytes(element, byteCount, bytes.baseAddress)
                    }
                    collected.append(chunk)
                }
                if !collected.isEmpty { body = collected }
            }
        }

        return CefSchemeRequest(
            url: URL(string: urlString),
            urlString: urlString,
            method: method,
            headers: headers,
            body: body
        )
    }
}

/// Reads a file body for ``SchemeResourceHandler``: `pread(2)` into the
/// buffer CEF passes to `read`, with no intermediate copy. CEF calls
/// `read` in sequence, so the lock is never contended; it only makes the
/// position safe to move between Chromium's pool threads.
final class SchemeFileReader: Sendable {
    private let descriptor: Int32
    private let position: OSAllocatedUnfairLock<(offset: Int, remaining: Int?)>

    init(url: URL, offset: Int, remaining: Int?) {
        descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        position = OSAllocatedUnfairLock(initialState: (offset, remaining))
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Reads up to `capacity` bytes into `buffer`. Returns the count, 0 at
    /// the end, or -2 (`ERR_FAILED`) when the file cannot be read.
    func read(into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int {
        guard descriptor >= 0 else { return -2 }
        // CEF keeps the buffer valid for the call.
        nonisolated(unsafe) let buffer = buffer
        return position.withLock { position in
            let wanted = min(capacity, position.remaining ?? .max)
            guard wanted > 0 else { return 0 }
            var count: Int
            repeat {
                count = pread(descriptor, buffer, wanted, off_t(position.offset))
            } while count < 0 && errno == EINTR
            guard count >= 0 else { return -2 }
            position.offset += count
            position.remaining = position.remaining.map { $0 - count }
            return count
        }
    }
}

/// The part of a body a `Range` header asks for (RFC 9110, section 14).
/// Only a single byte range is answered; anything else gets the whole body.
enum SchemeByteRange: Equatable {
    case whole
    case partial(ClosedRange<Int>)
    case unsatisfiable

    /// - Parameter totalLength: the body's length, or `nil` when unknown,
    ///   in which case only a range with both ends can be served.
    init(header: String, totalLength: Int?) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes="), !trimmed.contains(",") else {
            self = .whole
            return
        }
        let spec = trimmed.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            self = .whole
            return
        }
        let first = Self.position(parts[0]), last = Self.position(parts[1])
        let range: ClosedRange<Int>
        switch (first, last, totalLength) {
        case let (first?, last?, total) where first <= last:
            guard let total else {
                range = first...last
                break
            }
            guard first < total else {
                self = .unsatisfiable
                return
            }
            range = first...min(last, total - 1)
        case let (first?, nil, total?) where parts[1].allSatisfy(\.isWhitespace):
            guard first < total else {
                self = .unsatisfiable
                return
            }
            range = first...(total - 1)
        case let (nil, suffix?, total?) where parts[0].allSatisfy(\.isWhitespace):
            guard suffix > 0, total > 0 else {
                self = .unsatisfiable
                return
            }
            range = max(total - min(suffix, total), 0)...(total - 1)
        default:
            self = .whole
            return
        }
        // A range whose length does not fit in an `Int`, such as
        // `bytes=0-9223372036854775807` of a body of unknown length, is
        // ignored.
        let (span, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        guard !overflow, span < Int.max else {
            self = .whole
            return
        }
        self = .partial(range)
    }

    /// A byte position: ASCII digits only, as RFC 9110 has it, that fit in
    /// an `Int`. `nil` for anything else, signs included.
    private static func position(_ text: Substring) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(digits)
    }
}
