import CCef
import CefBase
import Foundation
import Testing

@testable import CefKit

@Suite struct WireCodingTests {
    struct Inner: Codable, Equatable {
        var name: String
        var flags: [Bool]
    }

    struct Outer: Codable, Equatable {
        var id: Int
        var big: Int64
        var ratio: Double
        var label: String?
        var missing: String?
        var inner: Inner
        var list: [Inner]
        var map: [String: Int]
        var data: Data
        var url: URL
        var unicode: String
        enum Kind: String, Codable { case a, b }
        var kind: Kind
    }

    static let sample = Outer(
        id: 7, big: 1 << 40, ratio: 0.25, label: "x", missing: nil, inner: Inner(name: "in", flags: [true, false]),
        list: [Inner(name: "a", flags: []), Inner(name: "b", flags: [true])], map: ["one": 1, "two": 2],
        data: Data([1, 2, 3]), url: URL(string: "https://example.com/a?b")!, unicode: "Grüße 😀 \u{2028}", kind: .b)

    func roundTrip<T: Codable>(_ value: T) throws -> T {
        let buffer = try CefWireEncoder.payload(value)
        return try buffer.bytes.withMemoryRebound(to: UInt8.self) { _ in
            try CefWireDecoder(bytes: buffer.bytes).decode(T.self)
        }
    }

    @Test func roundTripsCodableTypes() throws {
        #expect(try roundTrip(Self.sample) == Self.sample)
        #expect(try roundTrip(42) == 42)
        #expect(try roundTrip("text") == "text")
        #expect(try roundTrip([1, 2, 3] as [Int]) == [1, 2, 3] as [Int])
        #expect(try roundTrip([Int]()) == [Int]())
        #expect(try roundTrip(Optional<Int>.none) == nil)
        #expect(try roundTrip([[1], [2, 3]]) == [[1], [2, 3]])
    }

    @Test func membersDecodeInAnyOrder() throws {
        struct Reordered: Codable, Equatable {
            var b: Int, a: Int
            enum CodingKeys: String, CodingKey { case a, b }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(b, forKey: .b)
                try container.encode(a, forKey: .a)
            }
        }
        let value = Reordered(b: 2, a: 1)
        #expect(try roundTrip(value) == value)
    }

    @Test func integersTooLargeForJavaScriptFail() {
        #expect(throws: EncodingError.self) { _ = try CefWireEncoder.payload(Int64.max) }
        #expect(throws: DecodingError.self) {
            let buffer = try CefWireEncoder.payload(1.5)
            _ = try CefWireDecoder(bytes: buffer.bytes).decode(Int.self)
        }
    }

    @Test func cefJSONTravelsAsItsTree() throws {
        let json: CefJSON = ["list": [1, "two", false, nil], "nested": ["x": 0.5]]
        let buffer = try CefWireEncoder.payload(json)
        var reader = CefWireReader(buffer.bytes)
        #expect(try CefJSON(wire: &reader) == json)
        // And decodes into a typed value.
        struct Shape: Decodable { var list: [CefJSON]; var nested: [String: Double] }
        let shape = try CefWireDecoder(bytes: buffer.bytes).decode(Shape.self)
        #expect(shape.nested["x"] == 0.5 && shape.list.count == 4)
    }

    @Test func largeBytesAreDeferredAndCopiedOnce() throws {
        let data = Data((0..<(200 << 10)).map { UInt8(truncatingIfNeeded: $0) })
        let buffer = try CefWireEncoder.payload(data, header: CefWireHeader(target: 3))
        let needsSharedMemory = buffer.needsSharedMemory, inline = buffer.count
        #expect(needsSharedMemory)
        #expect(inline < 64)
        let flat = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.totalCount, alignment: 16)
        defer { flat.deallocate() }
        buffer.copy(to: flat.baseAddress!)
        let bytes = UnsafeRawBufferPointer(flat)
        #expect(try CefWireReader(bytes).header().target == 3)
        let decoded = try CefWireDecoder(bytes: bytes, offset: CefWireHeader.size).decode(Data.self)
        #expect(decoded == data)
    }

    @Test func containersRecordTheirLengthAcrossDeferredRuns() throws {
        struct Two: Codable, Equatable { var first: Data; var after: [String] }
        let value = Two(first: Data(count: 100 << 10), after: ["x", "y"])
        let buffer = try CefWireEncoder.payload([value, value])
        let flat = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.totalCount, alignment: 16)
        defer { flat.deallocate() }
        buffer.copy(to: flat.baseAddress!)
        var reader = CefWireReader(UnsafeRawBufferPointer(flat))
        try reader.skipValue()
        #expect(reader.isAtEnd)
        #expect(try CefWireDecoder(bytes: UnsafeRawBufferPointer(flat)).decode([Two].self) == [value, value])
    }

    // MARK: Malformed payloads

    /// Wire bytes written by hand.
    struct Raw {
        var bytes: [UInt8] = []
        mutating func tag(_ tag: CefWireTag) { bytes.append(tag.rawValue) }
        mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        mutating func container(_ tag: CefWireTag, length: UInt32, count: UInt32) { self.tag(tag); u32(length); u32(count) }
    }

    /// Decodes `raw` every way the browser process decodes a renderer's
    /// value, expecting each to throw.
    func expectRejected(_ raw: Raw, sourceLocation: SourceLocation = #_sourceLocation) {
        raw.bytes.withUnsafeBytes { bytes in
            #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try CefWireDecoder(bytes: bytes).decode(CefJSON.self) }
            #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try CefWireDecoder(bytes: bytes).decode([Int].self) }
            #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
                try CefWireDecoder(bytes: bytes).decode([String: Int].self)
            }
            #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
                var reader = CefWireReader(bytes)
                _ = try CefJSON(wire: &reader)
            }
        }
    }

    @Test func rejectsCountsTheBytesCannotHold() {
        // An empty array claiming UInt32.max elements: without the check,
        // `reserveCapacity` asks for tens of gigabytes.
        var raw = Raw()
        raw.container(.array, length: 0, count: .max)
        expectRejected(raw)
        raw = Raw()
        raw.container(.object, length: 0, count: .max)
        expectRejected(raw)
        // Three elements, but room for one.
        raw = Raw()
        raw.container(.array, length: 1, count: 3)
        raw.tag(.null)
        expectRejected(raw)
        // An object member takes at least five bytes.
        raw = Raw()
        raw.container(.object, length: 4, count: 1)
        raw.bytes += [0, 0, 0, 0]
        expectRejected(raw)
    }

    @Test func rejectsChildrenCrossingTheirContainer() {
        // The array says one byte; its string runs on past it, inside the
        // payload.
        var raw = Raw()
        raw.container(.array, length: 2, count: 1)
        raw.tag(.string)
        raw.u32(3)
        raw.bytes += Array("abc".utf8)
        // An outer array holding it and more.
        var outer = Raw()
        outer.container(.array, length: UInt32(raw.bytes.count), count: 1)
        outer.bytes += raw.bytes
        expectRejected(outer)
    }

    @Test func rejectsContainersNotConsumedExactly() {
        // One element counted, two present.
        var raw = Raw()
        raw.container(.array, length: 2, count: 1)
        raw.tag(.null)
        raw.tag(.null)
        expectRejected(raw)
        // Two counted, the length covering only one.
        raw = Raw()
        raw.container(.array, length: 1, count: 2)
        raw.tag(.null)
        raw.tag(.null)
        expectRejected(raw)
    }

    @Test func rejectsExcessiveNestingWithoutRecursingIntoIt() {
        // 100 000 nested arrays: recursion without a limit overflows the
        // stack.
        let depth = 100_000
        var raw = Raw()
        for level in 0..<depth {
            raw.container(.array, length: UInt32((depth - level - 1) * 9 + 1), count: 1)
        }
        raw.tag(.null)
        expectRejected(raw)
    }

    @Test func nestingUpToTheLimitDecodes() throws {
        func nested(_ depth: Int) -> CefJSON { depth == 0 ? .null : .array([nested(depth - 1)]) }
        let deepest = nested(CefWireLimits.maximumDepth)
        let buffer = try CefWireEncoder.payload(deepest)
        #expect(try CefWireDecoder(bytes: buffer.bytes).decode(CefJSON.self) == deepest)
        // One more is refused when written, so it is never sent.
        #expect(throws: EncodingError.self) { _ = try CefWireEncoder.payload(nested(CefWireLimits.maximumDepth + 1)) }
        var raw = Raw()
        for level in 0...CefWireLimits.maximumDepth {
            raw.container(.array, length: UInt32((CefWireLimits.maximumDepth - level) * 9 + 1), count: 1)
        }
        raw.tag(.null)
        expectRejected(raw)
    }

    @Test func rejectsTruncatedAndUnknownData() {
        for bytes: [UInt8] in [
            [], [CefWireTag.int32.rawValue, 1, 2], [CefWireTag.float64.rawValue, 0, 0, 0],
            [CefWireTag.string.rawValue, 9, 0, 0, 0, 65], [CefWireTag.array.rawValue, 0, 0, 0],
            [CefWireTag.object.rawValue, 0, 0, 0, 0, 0, 0], [9], [0xFF],
        ] {
            expectRejected(Raw(bytes: bytes))
        }
        // An unknown tag inside a container.
        var raw = Raw()
        raw.container(.array, length: 1, count: 1)
        raw.bytes.append(42)
        expectRejected(raw)
        // A header alone is too short to read past.
        #expect(throws: (any Error).self) { try CefWireReader(UnsafeRawBufferPointer(start: nil, count: 0)).header() }
    }

    @Test func rejectsPayloadsBeyondTheSizeLimit() {
        // A payload larger than the limit, whose value is tiny: only the
        // size is checked, so the bytes are never touched.
        let base = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        defer { base.deallocate() }
        base.storeBytes(of: CefWireTag.null.rawValue, as: UInt8.self)
        let huge = UnsafeRawBufferPointer(start: base, count: CefWireLimits.maximumPayloadSize + 1)
        #expect(throws: (any Error).self) { try CefWireReader(huge).validateValue() }
        #expect(throws: (any Error).self) { try CefWireDecoder(bytes: huge).decode(CefJSON.self) }
        // Writers refuse the same.
        #expect(throws: EncodingError.self) {
            _ = try CefWireEncoder.payload(Data(count: CefWireLimits.maximumPayloadSize + 1))
        }
    }

    @Test func rejectsTooManyValues() {
        // A container may hold at most as many values as the limit.
        var raw = Raw()
        let count = CefWireLimits.maximumValueCount + 1
        raw.container(.array, length: UInt32(count), count: UInt32(count))
        raw.bytes += [UInt8](repeating: CefWireTag.null.rawValue, count: count)
        raw.bytes.withUnsafeBytes { bytes in
            _ = #expect(throws: DecodingError.self) { try CefWireDecoder(bytes: bytes).decode(CefJSON.self) }
        }
    }

    @Test func malformedValuesSurfaceAsDecodingErrors() {
        var raw = Raw()
        raw.container(.array, length: 0, count: .max)
        raw.bytes.withUnsafeBytes { bytes in
            _ = #expect(throws: DecodingError.self) { try CefWireDecoder(bytes: bytes).decode([Int].self) }
        }
    }

    @Test func deferredRunsCanBeCopiedInMidWrite() throws {
        // A large run followed by more values, materialized while a
        // container that started after it is still open, as the renderer
        // does before running page code.
        let big = [UInt8]((0..<(100 << 10)).map { UInt8(truncatingIfNeeded: $0 * 7) })
        var buffer = CefWireBuffer()
        buffer.append(header: CefWireHeader(target: 5))
        let outer = buffer.open(.array)
        big.withUnsafeBytes { source in
            let base = source.baseAddress!
            buffer.append(bytes: big.count) { $0.copyMemory(from: base, byteCount: big.count) }
        }
        let inner = buffer.open(.object)
        let deferred = buffer.needsSharedMemory
        #expect(deferred)
        buffer.materializeDeferred()
        buffer.append(key: "k")
        buffer.append("after")
        buffer.close(inner, count: 1)
        big.withUnsafeBytes { source in
            let base = source.baseAddress!
            buffer.append(bytes: big.count) { $0.copyMemory(from: base, byteCount: big.count) }
        }
        buffer.close(outer, count: 3)
        let flat = UnsafeMutableRawBufferPointer.allocate(byteCount: buffer.totalCount, alignment: 16)
        defer { flat.deallocate() }
        buffer.copy(to: flat.baseAddress!)
        let encoded = CefJSON.string(Data(big).base64EncodedString())
        let decoder = CefWireDecoder(bytes: UnsafeRawBufferPointer(flat), offset: CefWireHeader.size)
        #expect(try decoder.decode(CefJSON.self) == .array([encoded, ["k": "after"], encoded]))
    }

    @Test func stringsTranscodeBothWays() {
        for text in ["", "ascii", "Grüße", "😀 mixed é", String(repeating: "ä", count: 2000)] {
            let back = CefStringUtil.withCefString(text) { CefStringUtil.string(from: $0) }
            #expect(back == text)
            var cef = cef_string_t()
            CefStringUtil.set(text, into: &cef)
            #expect(CefStringUtil.string(from: cef) == text)
            ccef_string_clear(&cef)
        }
        let name = CefStaticString("cefswift.page.call")
        #expect(name.matches(name.pointer))
        #expect(CefStringUtil.equals(name.pointer, "cefswift.page.call"))
        #expect(!CefStringUtil.equals(name.pointer, "cefswift.page.cal"))
        #expect(CefStringUtil.hasPrefix(name.pointer, "cefswift.page."))
    }
}

@Suite struct ProcessMessageTests {
    @Test func accessorsAreTotal() {
        let message = CefProcessMessage("m", [
            .int(7), .double(.nan), .double(.infinity), .double(-.infinity), .double(1e300), .double(2.5), .double(3),
            .string("s"), .bool(true), .unsupported,
        ])
        #expect(message.int(0) == 7)
        for index in 1...5 { #expect(message.int(index) == nil) }
        #expect(message.int(6) == 3)
        #expect(message.int(7) == nil && message.int(99) == nil && message.int(-1) == nil)
        #expect(message.string(7) == "s" && message.string(0) == nil && message.string(99) == nil)
        #expect(message.bool(8) == true && message.bool(0) == nil && message.bool(9) == nil)
    }

    @Test func malformedSyncMessagesAreRejected() {
        func generation(_ arguments: [CefProcessMessage.Argument]) -> Int? {
            CefPageScripting.reportedGeneration(CefProcessMessage(CefPageScriptingMessage.sync, arguments))
        }
        #expect(generation([.int(4)]) == 4)
        #expect(generation([]) == nil)
        #expect(generation([.int(4), .int(5)]) == nil)
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 2.5, 4] {
            #expect(generation([.double(value)]) == nil)
        }
        #expect(generation([.string("4")]) == nil)
        #expect(generation([.bool(true)]) == nil)
        #expect(generation([.unsupported]) == nil)
    }
}
