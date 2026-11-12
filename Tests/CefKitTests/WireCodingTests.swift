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
        #expect(try roundTrip([1, 2, 3]) == [1, 2, 3])
        #expect(try roundTrip([Int]()) == [])
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
