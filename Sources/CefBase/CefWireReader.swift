import CCef

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
