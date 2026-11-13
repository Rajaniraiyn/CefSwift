import CCef

// The wire format of page-scripting messages: bridge calls and replies,
// events and evaluations. Both processes write and read it directly, the
// browser process from `Codable` types and the renderer from V8 values, so
// no value passes through JSON text or an intermediate tree.
//
// A message's payload is a fixed header followed by values. Every number
// is little-endian; the header is four-byte aligned at the start of the
// payload, which is a `cef_binary_value_t` or a shared memory region.
//
//     value   := tag:u8 body
//     0 null | 1 false | 2 true
//     3 int32:     i32
//     4 float64:   f64
//     5 string:    length:u32 UTF-8 bytes
//     6 array:     byteLength:u32 count:u32 value*
//     7 object:    byteLength:u32 count:u32 (keyLength:u32 UTF-8 key, value)*
//     8 bytes:     length:u32 bytes
//
// `byteLength` counts the bytes after the container's own nine, so a
// reader skips any value in constant time.
//
// Payloads come from another process, which may be compromised, so a
// reader checks a value's structure (`CefWireReader.validateValue()`)
// before building anything from it, and both processes keep to
// `CefWireLimits`: a writer refuses a value beyond them and a reader
// rejects one, so every value one side can write, the other can read.

/// The limits of the wire format, the same for writers and readers.
package enum CefWireLimits {
    /// The deepest nesting of arrays and objects. The renderer writes
    /// `null` for a container deeper than this, as for a cycle.
    package static let maximumDepth = 64
    /// The largest payload, header included: 1 GiB.
    package static let maximumPayloadSize = 1 << 30
    /// The most values in a payload, containers, elements and members
    /// all counted: 16 Mi. A value read from the wire costs a reader at
    /// most a few dozen bytes, so this bounds what decoding allocates.
    package static let maximumValueCount = 1 << 24
}

/// The tags of the wire format.
package enum CefWireTag: UInt8 {
    case null = 0
    case `false` = 1
    case `true` = 2
    case int32 = 3
    case float64 = 4
    case string = 5
    case array = 6
    case object = 7
    case bytes = 8
}

/// The fixed fields at the start of every page-scripting payload, read in
/// place by both processes. What each field means depends on the message;
/// see ``CefPageScriptingMessage``.
package struct CefWireHeader: Equatable {
    package var target: Int32 = 0
    package var call: Int32 = 0
    package var succeeded: Int32 = 0
    package var line: Int32 = 0
    package var column: Int32 = 0
    package var reserved: Int32 = 0

    package init(target: Int32 = 0, call: Int32 = 0, succeeded: Bool = false, line: Int32 = 0, column: Int32 = 0) {
        self.target = target
        self.call = call
        self.succeeded = succeeded ? 1 : 0
        self.line = line
        self.column = column
    }

    package static let size = MemoryLayout<CefWireHeader>.stride
}

/// Writes a payload. It owns its bytes and is not copyable, so a buffer
/// is freed exactly once.
///
/// Byte runs of at least ``deferredThreshold`` bytes are not copied into
/// the buffer: the writer keeps a function that copies them later,
/// straight into the payload's final memory (a shared memory region).
package struct CefWireBuffer: ~Copyable {
    /// Payloads larger than this travel in shared memory.
    package static let sharedMemoryThreshold = 64 << 10
    /// Byte runs at least this long are copied once, into the final memory.
    package static let deferredThreshold = 64 << 10

    package typealias CopyFunction = (UnsafeMutableRawPointer) -> Void

    private(set) var storage: UnsafeMutableRawPointer
    private(set) var capacity: Int
    /// Bytes written to the buffer itself.
    package private(set) var count = 0
    /// Deferred runs: where they go in the buffer's bytes, how long they
    /// are, and the function that copies them.
    private var deferred: [(position: Int, count: Int, copy: CopyFunction)] = []
    private var deferredBytes = 0
    /// How often deferred runs were copied into the buffer, which moves
    /// what follows them.
    private var materializations = 0
    /// Values written, for `CefWireLimits.maximumValueCount`.
    package private(set) var valueCount = 0
    /// Containers open now, and the most that were open at once.
    private var openContainers = 0
    package private(set) var deepestNesting = 0

    package init(capacity: Int = 256) {
        self.capacity = max(capacity, 64)
        storage = .allocate(byteCount: self.capacity, alignment: 16)
    }

    deinit {
        storage.deallocate()
    }

    /// The payload's size: the buffer and the deferred runs.
    package var totalCount: Int { count + deferredBytes }

    /// Whether the payload holds deferred runs or is large.
    package var needsSharedMemory: Bool { !deferred.isEmpty || count > Self.sharedMemoryThreshold }

    /// The buffer's bytes, valid until the next write. Only meaningful
    /// without deferred runs.
    package var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: storage, count: count) }

    private mutating func reserve(_ extra: Int) {
        guard count + extra > capacity else { return }
        var newCapacity = capacity * 2
        while newCapacity < count + extra { newCapacity *= 2 }
        let grown = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        grown.copyMemory(from: storage, byteCount: count)
        storage.deallocate()
        storage = grown
        capacity = newCapacity
    }

    // MARK: Writing

    package mutating func append(header: CefWireHeader) {
        reserve(CefWireHeader.size)
        (storage + count).storeBytes(of: header, as: CefWireHeader.self)
        count += CefWireHeader.size
    }

    @inline(__always)
    package mutating func append(tag: CefWireTag) {
        valueCount += 1
        reserve(1)
        storage.storeBytes(of: tag.rawValue, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    @inline(__always)
    mutating func appendUInt32(_ value: UInt32) {
        reserve(4)
        storage.storeBytes(of: value.littleEndian, toByteOffset: count, as: UInt32.self)
        count += 4
    }

    package mutating func appendNull() { append(tag: .null) }
    package mutating func append(_ value: Bool) { append(tag: value ? .true : .false) }

    package mutating func append(_ value: Int32) {
        valueCount += 1
        reserve(5)
        storage.storeBytes(of: CefWireTag.int32.rawValue, toByteOffset: count, as: UInt8.self)
        storage.storeBytes(of: value.littleEndian, toByteOffset: count + 1, as: Int32.self)
        count += 5
    }

    package mutating func append(_ value: Double) {
        valueCount += 1
        reserve(9)
        storage.storeBytes(of: CefWireTag.float64.rawValue, toByteOffset: count, as: UInt8.self)
        storage.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: count + 1, as: UInt64.self)
        count += 9
    }

    /// An integer: `int32` when it fits, else `float64`.
    package mutating func append(integer value: Int) {
        if let small = Int32(exactly: value) { append(small) } else { append(Double(value)) }
    }

    package mutating func append(_ value: String) {
        var value = value
        value.withUTF8 { append(string: UnsafeRawBufferPointer($0)) }
    }

    /// A string from its UTF-8 bytes.
    package mutating func append(string utf8: UnsafeRawBufferPointer) {
        append(tag: .string)
        appendRaw(utf8)
    }

    /// A JavaScript string value's text, transcoded straight into the
    /// buffer.
    package mutating func append(utf16 value: UnsafeMutablePointer<cef_v8_value_t>) {
        let string = value.pointee.get_string_value(value)
        defer { if let string { cef_string_userfree_utf16_free(string) } }
        append(utf16: UnsafeBufferPointer(start: string?.pointee.str, count: string?.pointee.length ?? 0))
    }

    /// A string from UTF-16 code units, transcoded straight into the buffer.
    package mutating func append(utf16 units: UnsafeBufferPointer<UInt16>) {
        append(tag: .string)
        appendRaw(utf16: units)
    }

    /// An object key from UTF-16 code units.
    package mutating func append(key units: UnsafeBufferPointer<UInt16>) {
        appendRaw(utf16: units)
    }

    package mutating func append(key: String) {
        var key = key
        key.withUTF8 { appendRaw(UnsafeRawBufferPointer($0)) }
    }

    /// A key from a static string, without making a Swift string.
    package mutating func append(key: StaticString) {
        appendRaw(UnsafeRawBufferPointer(start: key.utf8Start, count: key.utf8CodeUnitCount))
    }

    /// Length-prefixed bytes, copied now.
    private mutating func appendRaw(_ bytes: UnsafeRawBufferPointer) {
        reserve(4 + bytes.count)
        storage.storeBytes(of: UInt32(bytes.count).littleEndian, toByteOffset: count, as: UInt32.self)
        if let base = bytes.baseAddress, !bytes.isEmpty {
            (storage + count + 4).copyMemory(from: base, byteCount: bytes.count)
        }
        count += 4 + bytes.count
    }

    /// Length-prefixed UTF-8 from UTF-16. A UTF-16 unit becomes at most
    /// three UTF-8 bytes.
    private mutating func appendRaw(utf16 units: UnsafeBufferPointer<UInt16>) {
        reserve(4 + units.count * 3)
        let start = count + 4
        var written = 0
        let target = (storage + start).assumingMemoryBound(to: UInt8.self)
        var index = 0
        while index < units.count, units[index] < 0x80 {
            target[index] = UInt8(truncatingIfNeeded: units[index])
            index += 1
        }
        written = index
        if index < units.count {
            _ = transcode(units[index...].makeIterator(), from: UTF16.self, to: UTF8.self, stoppingOnError: false) { byte in
                target[written] = byte
                written += 1
            }
        }
        storage.storeBytes(of: UInt32(written).littleEndian, toByteOffset: count, as: UInt32.self)
        count = start + written
    }

    /// Bytes (an `ArrayBuffer` or `Data`). A run of at least
    /// ``deferredThreshold`` bytes is copied later by `copy`, once, into
    /// the payload's final memory, or into the buffer by
    /// ``materializeDeferred()``; `copy` must stay valid until then.
    /// Callers keep `count` within `CefWireLimits.maximumPayloadSize`.
    package mutating func append(bytes count: Int, copy: @escaping CopyFunction) {
        append(tag: .bytes)
        appendUInt32(UInt32(count))
        guard count > 0 else { return }
        if count >= Self.deferredThreshold {
            deferred.append((self.count, count, copy))
            deferredBytes += count
        } else {
            reserve(count)
            copy(storage + self.count)
            self.count += count
        }
    }

    // MARK: Containers

    /// Where an open container's header is, for ``close(_:)``.
    package struct Container {
        /// The header's offset in the buffer's bytes when it was written.
        let position: Int
        /// The deferred bytes before the header then, and how often
        /// deferred runs had been copied in: a later copy moves the header
        /// by those bytes.
        let deferredBefore: Int
        let materializations: Int
        let logicalStart: Int
        package var count: UInt32 = 0
    }

    /// Starts an array or object, whose length and count ``close(_:)``
    /// fills in.
    package mutating func open(_ tag: CefWireTag) -> Container {
        append(tag: tag)
        let position = count
        appendUInt32(0)
        appendUInt32(0)
        openContainers += 1
        deepestNesting = max(deepestNesting, openContainers)
        return Container(
            position: position, deferredBefore: deferredBytes, materializations: materializations,
            logicalStart: count + deferredBytes)
    }

    /// Writes `container`'s length and count.
    package mutating func close(_ container: Container) {
        openContainers -= 1
        let length = UInt32(count + deferredBytes - container.logicalStart)
        let position = container.position
            + (materializations > container.materializations ? container.deferredBefore : 0)
        storage.storeBytes(of: length.littleEndian, toByteOffset: position, as: UInt32.self)
        storage.storeBytes(of: container.count.littleEndian, toByteOffset: position + 4, as: UInt32.self)
    }

    /// Writes `container`'s length and the element count `elements`, for
    /// writers that count elements themselves.
    package mutating func close(_ container: Container, count elements: Int) {
        var container = container
        container.count = UInt32(elements)
        close(container)
    }

    // MARK: Finishing

    /// Copies the deferred runs into the buffer now, a second copy of
    /// their bytes. The renderer calls it before anything that may run
    /// page code, which could detach or free an `ArrayBuffer` whose bytes
    /// a deferred run has yet to read.
    package mutating func materializeDeferred() {
        guard !deferred.isEmpty else { return }
        let total = totalCount
        var newCapacity = capacity
        while newCapacity < total { newCapacity *= 2 }
        let grown = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        copy(to: grown)
        storage.deallocate()
        storage = grown
        capacity = newCapacity
        count = total
        deferred = []
        deferredBytes = 0
        materializations += 1
    }

    /// Why the payload is beyond `CefWireLimits`, or `nil` when it is
    /// within them.
    package var limitViolation: String? {
        if totalCount > CefWireLimits.maximumPayloadSize {
            return "the value is larger than \(CefWireLimits.maximumPayloadSize >> 20) MB"
        }
        if valueCount > CefWireLimits.maximumValueCount {
            return "the value holds more than \(CefWireLimits.maximumValueCount) values"
        }
        if deepestNesting > CefWireLimits.maximumDepth {
            return "the value nests deeper than \(CefWireLimits.maximumDepth) levels"
        }
        return nil
    }

    /// Copies the payload, deferred runs included, to `target`, which has
    /// room for ``totalCount`` bytes.
    package func copy(to target: UnsafeMutableRawPointer) {
        var source = 0, destination = 0
        for run in deferred {
            let before = run.position - source
            (target + destination).copyMemory(from: storage + source, byteCount: before)
            destination += before
            source = run.position
            run.copy(target + destination)
            destination += run.count
        }
        (target + destination).copyMemory(from: storage + source, byteCount: count - source)
    }
}

/// Reads a payload in place.
package struct CefWireReader {
    package let base: UnsafeRawPointer
    package let end: Int
    package var offset: Int

    package init(_ bytes: UnsafeRawBufferPointer, offset: Int = 0) {
        base = bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 16)!
        end = bytes.count
        self.offset = offset
    }

    /// A reader of `base` that stops at `end`.
    private init(base: UnsafeRawPointer, end: Int, offset: Int) {
        self.base = base
        self.end = end
        self.offset = offset
    }

    package enum Failure: Error {
        case truncated
        case badTag(UInt8)
        /// A container whose count, length and contents disagree.
        case inconsistent
        /// A payload beyond `CefWireLimits`.
        case beyondLimits
    }

    package func header() throws -> CefWireHeader {
        guard end >= CefWireHeader.size else { throw Failure.truncated }
        return base.loadUnaligned(as: CefWireHeader.self)
    }

    /// Skips the header; the values follow it.
    package mutating func skipHeader() { offset = max(offset, CefWireHeader.size) }

    @inline(__always)
    private func check(_ needed: Int) throws {
        guard offset + needed <= end else { throw Failure.truncated }
    }

    package var isAtEnd: Bool { offset >= end }

    package func peekTag() throws -> CefWireTag {
        try check(1)
        let raw = base.load(fromByteOffset: offset, as: UInt8.self)
        guard let tag = CefWireTag(rawValue: raw) else { throw Failure.badTag(raw) }
        return tag
    }

    package mutating func readTag() throws -> CefWireTag {
        let tag = try peekTag()
        offset += 1
        return tag
    }

    @inline(__always)
    package mutating func readUInt32() throws -> UInt32 {
        try check(4)
        defer { offset += 4 }
        return UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// The body of an `int32`.
    package mutating func readInt32Body() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// The body of a `float64`.
    package mutating func readDoubleBody() throws -> Double {
        try check(8)
        defer { offset += 8 }
        return Double(bitPattern: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
    }

    /// A length-prefixed run: a string's or key's UTF-8, or bytes.
    package mutating func readRun() throws -> UnsafeRawBufferPointer {
        let length = Int(try readUInt32())
        try check(length)
        defer { offset += length }
        return UnsafeRawBufferPointer(start: base + offset, count: length)
    }

    /// A container's header after its tag: its end offset and count. The
    /// count is at most the length, as every element takes a byte or
    /// more, so a reader may reserve room for it; ``validateValue()``
    /// checks the rest.
    package mutating func readContainer() throws -> (end: Int, count: Int) {
        let length = Int(try readUInt32())
        let count = Int(try readUInt32())
        guard offset + length <= end else { throw Failure.truncated }
        guard count <= length else { throw Failure.inconsistent }
        return (offset + length, count)
    }

    /// Checks that the value at the offset is well formed, without moving:
    /// known tags; every run, member and element inside the payload and
    /// inside its container; each container's count and length describing
    /// exactly what fills it; and the payload within `CefWireLimits`.
    /// Readers that build values from another process's payload check this
    /// first, so malformed data is an error, never a crash, a deep
    /// recursion or an allocation larger than the payload accounts for.
    package func validateValue() throws {
        guard end <= CefWireLimits.maximumPayloadSize else { throw Failure.beyondLimits }
        var reader = self
        var budget = CefWireLimits.maximumValueCount
        try reader.validate(depth: 0, budget: &budget)
    }

    private mutating func validate(depth: Int, budget: inout Int) throws {
        budget -= 1
        guard budget >= 0 else { throw Failure.beyondLimits }
        let tag = try readTag()
        switch tag {
        case .null, .false, .true: break
        case .int32: try check(4); offset += 4
        case .float64: try check(8); offset += 8
        case .string, .bytes: _ = try readRun()
        case .array, .object:
            // The depth bounds the recursion, and so the reader's stack.
            guard depth < CefWireLimits.maximumDepth else { throw Failure.beyondLimits }
            let (containerEnd, count) = try readContainer()
            // An element takes at least its tag; a member also its key's
            // length.
            let smallest = tag == .array ? 1 : 5
            guard count <= (containerEnd - offset) / smallest else { throw Failure.inconsistent }
            var contents = CefWireReader(base: base, end: containerEnd, offset: offset)
            for _ in 0..<count {
                if tag == .object { _ = try contents.readRun() }
                try contents.validate(depth: depth + 1, budget: &budget)
            }
            guard contents.offset == containerEnd else { throw Failure.inconsistent }
            offset = containerEnd
        }
    }

    /// Skips one value in constant time, without checking its contents.
    package mutating func skipValue() throws {
        switch try readTag() {
        case .null, .false, .true: break
        case .int32: try check(4); offset += 4
        case .float64: try check(8); offset += 8
        case .string, .bytes: _ = try readRun()
        case .array, .object: offset = try readContainer().end
        }
    }

    /// A string value's UTF-8 bytes, in place.
    package mutating func readStringBytes() throws -> UnsafeRawBufferPointer {
        guard try readTag() == .string else { throw Failure.badTag(base.load(fromByteOffset: offset - 1, as: UInt8.self)) }
        return try readRun()
    }

    /// A string value as a Swift string.
    package mutating func readString() throws -> String {
        String(decoding: try readStringBytes(), as: UTF8.self)
    }
}

/// A received payload: the bytes of a `cef_binary_value_t` or a shared
/// memory region, kept alive by the CEF objects that hold them.
///
/// The bytes are never written after the message arrives, so the payload
/// may be read from any thread; the last reference releases the CEF
/// objects, which unmaps a shared memory region.
package final class CefWirePayload: @unchecked Sendable {
    // Immutable after init: CEF's received messages are read-only, and
    // the objects holding the bytes are released only in deinit.
    package let bytes: UnsafeRawBufferPointer
    /// Whether the bytes are a shared memory mapping of their own.
    package let isShared: Bool
    private let owners: [UnsafeMutableRawPointer]

    /// Takes over one reference to each of `owners`, released in order.
    private init(bytes: UnsafeRawBufferPointer, isShared: Bool, owners: [UnsafeMutableRawPointer]) {
        self.bytes = bytes
        self.isShared = isShared
        self.owners = owners
        CefCensus.add(.sharedMemoryMapping, isShared ? 1 : 0)
        CefCensus.add(.wirePayload, 1)
    }

    deinit {
        owners.forEach { cefRelease($0) }
        CefCensus.add(.sharedMemoryMapping, isShared ? -1 : 0)
        CefCensus.add(.wirePayload, -1)
    }

    /// The payload of a borrowed message: its shared memory region, or its
    /// first argument when that is binary. `nil` for any other message.
    package convenience init?(message: UnsafeMutablePointer<cef_process_message_t>) {
        if let region = message.pointee.get_shared_memory_region(message) {
            guard region.pointee.is_valid(region) != 0, let memory = region.pointee.memory(region) else {
                cefRelease(region)
                return nil
            }
            self.init(
                bytes: UnsafeRawBufferPointer(start: memory, count: region.pointee.size(region)), isShared: true,
                owners: [UnsafeMutableRawPointer(region)])
            return
        }
        guard let list = message.pointee.get_argument_list(message) else { return nil }
        guard list.pointee.get_size(list) >= 1, list.pointee.get_type(list, 0) == VTYPE_BINARY,
              let binary = list.pointee.get_binary(list, 0)
        else {
            cefRelease(list)
            return nil
        }
        // The binary value's bytes belong to the list, which belongs to
        // the message: hold all three, the message last.
        cefAddRef(message)
        let data = binary.pointee.get_raw_data(binary)
        self.init(
            bytes: UnsafeRawBufferPointer(start: data, count: binary.pointee.get_size(binary)), isShared: false,
            owners: [UnsafeMutableRawPointer(binary), UnsafeMutableRawPointer(list), UnsafeMutableRawPointer(message)])
    }

    package var reader: CefWireReader { CefWireReader(bytes) }
}

extension CefWireBuffer {
    /// A process message named `name` carrying this payload, with one
    /// reference: as its first argument when small, in shared memory
    /// otherwise.
    package func makeMessage(_ name: CefStaticString) -> UnsafeMutablePointer<cef_process_message_t>? {
        if needsSharedMemory {
            guard let builder = cef_shared_process_message_builder_create(name.pointer, totalCount) else { return nil }
            defer { cefRelease(builder) }
            guard builder.pointee.is_valid(builder) != 0, let memory = builder.pointee.memory(builder) else { return nil }
            copy(to: memory)
            return builder.pointee.build(builder)
        }
        guard let message = cef_process_message_create(name.pointer) else { return nil }
        if let list = message.pointee.get_argument_list(message) {
            defer { cefRelease(list) }
            // Creation copies the bytes; the setter consumes the value.
            let binary = cef_binary_value_create(storage, count)
            _ = list.pointee.set_binary(list, 0, binary)
        }
        return message
    }

    /// Sends this payload from `frame` to `process`. Returns whether CEF
    /// took it.
    @discardableResult
    package func send(_ name: CefStaticString, from frame: UnsafeMutablePointer<cef_frame_t>, to process: cef_process_id_t) -> Bool {
        guard frame.pointee.is_valid(frame) != 0, let message = makeMessage(name) else { return false }
        frame.pointee.send_process_message(frame, process, message)
        return true
    }
}
