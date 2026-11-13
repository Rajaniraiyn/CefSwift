import CefBase
import Foundation

// `Codable` over CefBase's wire format, for bridge arguments, results and
// evaluation values. Encoding writes the wire bytes directly; decoding
// reads them in place. Neither builds JSON text or a `CefJSON` tree, and
// primitives cost no allocation: an encode or decode allocates one
// container box per struct, array or dictionary, as `Codable` requires.
//
// The format is JSON's data model plus bytes. `Data` travels as bytes
// (an `ArrayBuffer` in the page) and decodes from bytes or a base64
// string; `URL` as its absolute string; `Date` as `Codable` encodes it
// (seconds since 2001) and decodes from a number or an ISO 8601 string, which
// is how a page's `Date` arrives.

// MARK: - CefJSON

extension CefJSON {
    /// Writes the value in the wire format.
    func write(to buffer: inout CefWireBuffer) {
        switch self {
        case .null: buffer.appendNull()
        case .bool(let value): buffer.append(value)
        case .number(let value):
            if value.rounded() == value, let small = Int32(exactly: value) { buffer.append(small) } else { buffer.append(value) }
        case .string(let value): buffer.append(value)
        case .array(let elements):
            let container = buffer.open(.array)
            for element in elements { element.write(to: &buffer) }
            buffer.close(container, count: elements.count)
        case .object(let members):
            let container = buffer.open(.object)
            for (key, member) in members {
                buffer.append(key: key)
                member.write(to: &buffer)
            }
            buffer.close(container, count: members.count)
        }
    }

    /// Reads a wire value. Bytes become a base64 string, as `JSONEncoder`
    /// writes `Data`.
    init(wire reader: inout CefWireReader) throws {
        switch try reader.readTag() {
        case .null: self = .null
        case .false: self = .bool(false)
        case .true: self = .bool(true)
        case .int32: self = .number(Double(try reader.readInt32Body()))
        case .float64: self = .number(try reader.readDoubleBody())
        case .string: self = .string(String(decoding: try reader.readRun(), as: UTF8.self))
        case .bytes:
            let run = try reader.readRun()
            self = .string(Data(run).base64EncodedString())
        case .array:
            let (_, count) = try reader.readContainer()
            var elements: [CefJSON] = []
            elements.reserveCapacity(count)
            for _ in 0..<count { elements.append(try CefJSON(wire: &reader)) }
            self = .array(elements)
        case .object:
            let (_, count) = try reader.readContainer()
            var members: [String: CefJSON] = [:]
            members.reserveCapacity(count)
            for _ in 0..<count {
                let key = String(decoding: try reader.readRun(), as: UTF8.self)
                members[key] = try CefJSON(wire: &reader)
            }
            self = .object(members)
        }
    }
}

// MARK: - Benchmarks

/// The wire codec, for SelfTest's codec benchmark.
@_spi(Testing) public enum CefWireBenchmark {
    /// Encoded bytes.
    public final class Encoded {
        fileprivate var buffer: CefWireBuffer
        fileprivate init(_ buffer: consuming CefWireBuffer) { self.buffer = buffer }
        public var count: Int { buffer.totalCount }
    }

    public static func encode(_ value: some Encodable) throws -> Encoded {
        Encoded(try CefWireEncoder.payload(value))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from encoded: Encoded) throws -> T {
        try CefWireDecoder(bytes: encoded.buffer.bytes).decode(type)
    }
}
