import CefBase
import Foundation

// MARK: - Decoding

/// Decodes `Decodable` values from wire bytes, in place.
final class CefWireDecoder: Decoder {
    let payload: CefWirePayload?
    /// The bytes being read, which `payload` keeps alive when set.
    let bytes: UnsafeRawBufferPointer
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    /// Where the next value starts.
    fileprivate var offset: Int
    /// Where each container depth last found a key, to try first.
    fileprivate var hints: [Int] = []

    init(payload: CefWirePayload, offset: Int) {
        self.payload = payload
        bytes = payload.bytes
        self.offset = offset
    }

    /// Reads bytes the caller keeps alive for the decoder's lifetime.
    init(bytes: UnsafeRawBufferPointer, offset: Int = 0) {
        payload = nil
        self.bytes = bytes
        self.offset = offset
    }

    fileprivate var reader: CefWireReader { CefWireReader(bytes, offset: offset) }

    /// Decodes the value at the current offset and moves past it.
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        if let special = try decodeSpecial(type) { return special }
        let start = offset
        let value = try T(from: self)
        // A type that reads less than the whole value (or nothing) still
        // moves past all of it.
        var reader = CefWireReader(bytes, offset: start)
        try reader.skipValue()
        offset = reader.offset
        return value
    }

    private func decodeSpecial<T: Decodable>(_ type: T.Type) throws -> T? {
        if T.self == Data.self { return try readData() as? T }
        if T.self == CefJSON.self {
            var reader = self.reader
            let json = try CefJSON(wire: &reader)
            offset = reader.offset
            return json as? T
        }
        if T.self == URL.self {
            let text = try readString()
            guard let url = URL(string: text) else { throw corrupted("Invalid URL string \(text)") }
            return url as? T
        }
        if T.self == Date.self {
            if peekTag() == .string {
                let text = try readString()
                guard let date = Self.isoDate(text) else { throw corrupted("Invalid ISO 8601 date \(text)") }
                return date as? T
            }
            return Date(timeIntervalSinceReferenceDate: try readDouble()) as? T
        }
        if T.self == Decimal.self { return Decimal(try readDouble()) as? T }
        return nil
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Primitives

    fileprivate func corrupted(_ message: String, _ key: (any CodingKey)? = nil) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath + (key.map { [$0] } ?? []), debugDescription: message))
    }

    fileprivate func mismatch(_ type: Any.Type, found tag: CefWireTag?, _ key: (any CodingKey)? = nil) -> DecodingError {
        .typeMismatch(type, .init(
            codingPath: codingPath + (key.map { [$0] } ?? []),
            debugDescription: "Expected \(type) but found \(tag.map { "\($0)" } ?? "the end of the data")"))
    }

    fileprivate func readTag() throws -> CefWireTag {
        var reader = self.reader
        do {
            let tag = try reader.readTag()
            offset = reader.offset
            return tag
        } catch {
            throw corrupted("The wire data ends early or holds an unknown tag")
        }
    }

    fileprivate func peekTag() -> CefWireTag? { try? reader.peekTag() }

    fileprivate func readNil() -> Bool {
        guard peekTag() == .null else { return false }
        offset += 1
        return true
    }

    fileprivate func readBool(_ key: (any CodingKey)? = nil) throws -> Bool {
        switch peekTag() {
        case .true: offset += 1; return true
        case .false: offset += 1; return false
        case let tag: throw mismatch(Bool.self, found: tag, key)
        }
    }

    fileprivate func readDouble(_ key: (any CodingKey)? = nil) throws -> Double {
        var reader = self.reader
        switch peekTag() {
        case .int32:
            reader.offset += 1
            let value = try reader.readInt32Body()
            offset = reader.offset
            return Double(value)
        case .float64:
            reader.offset += 1
            let value = try reader.readDoubleBody()
            offset = reader.offset
            return value
        case let tag:
            throw mismatch(Double.self, found: tag, key)
        }
    }

    fileprivate func readInteger<I: FixedWidthInteger>(_ type: I.Type, _ key: (any CodingKey)? = nil) throws -> I {
        var reader = self.reader
        switch peekTag() {
        case .int32:
            reader.offset += 1
            let value = try reader.readInt32Body()
            guard let exact = I(exactly: value) else { throw corrupted("\(value) does not fit in \(I.self)", key) }
            offset = reader.offset
            return exact
        case .float64:
            reader.offset += 1
            let value = try reader.readDoubleBody()
            guard let exact = I(exactly: value) else { throw corrupted("\(value) is not an exact \(I.self)", key) }
            offset = reader.offset
            return exact
        case let tag:
            throw mismatch(I.self, found: tag, key)
        }
    }

    fileprivate func readString(_ key: (any CodingKey)? = nil) throws -> String {
        guard peekTag() == .string else { throw mismatch(String.self, found: peekTag(), key) }
        var reader = self.reader
        reader.offset += 1
        let run = try reader.readRun()
        offset = reader.offset
        return String(decoding: run, as: UTF8.self)
    }

    /// Bytes, or a base64 string. Bytes in shared memory are not copied:
    /// the `Data` keeps the mapping alive.
    fileprivate func readData() throws -> Data {
        switch peekTag() {
        case .bytes:
            var reader = self.reader
            reader.offset += 1
            let run = try reader.readRun()
            offset = reader.offset
            guard let base = run.baseAddress, !run.isEmpty else { return Data() }
            if let payload, payload.isShared, run.count >= CefWireBuffer.deferredThreshold {
                return Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: run.count,
                    deallocator: .custom { _, _ in withExtendedLifetime(payload) {} })
            }
            return Data(bytes: base, count: run.count)
        case .string:
            let text = try readString()
            guard let data = Data(base64Encoded: text) else { throw corrupted("The string is not base64") }
            return data
        case .array:
            // An array of byte values, as `Data` encodes itself elsewhere.
            return Data(try [UInt8](from: self))
        case let tag:
            throw mismatch(Data.self, found: tag)
        }
    }

    // MARK: Containers

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard peekTag() == .object else { throw mismatch([String: Any].self, found: peekTag()) }
        var reader = self.reader
        reader.offset += 1
        let (end, count) = try reader.readContainer()
        let depth = codingPath.count
        if hints.count <= depth { hints.append(contentsOf: repeatElement(0, count: depth + 1 - hints.count)) }
        hints[depth] = reader.offset
        return KeyedDecodingContainer(KeyedContainer<Key>(
            decoder: self, start: reader.offset, end: end, count: count, depth: depth, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard peekTag() == .array else { throw mismatch([Any].self, found: peekTag()) }
        var reader = self.reader
        reader.offset += 1
        let (end, count) = try reader.readContainer()
        return UnkeyedContainer(decoder: self, position: reader.offset, end: end, count: count, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValue(decoder: self, codingPath: codingPath)
    }

    /// Runs `body` with the decoder at `position`, then restores it.
    fileprivate func at<R>(_ position: Int, key: (any CodingKey)?, _ body: () throws -> R) rethrows -> R {
        let saved = offset
        offset = position
        if let key { codingPath.append(key) }
        defer {
            offset = saved
            if key != nil { codingPath.removeLast() }
        }
        return try body()
    }

    private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let decoder: CefWireDecoder
        let start: Int
        let end: Int
        let count: Int
        let depth: Int
        var codingPath: [any CodingKey]

        var allKeys: [Key] {
            var keys: [Key] = []
            var reader = CefWireReader(decoder.bytes, offset: start)
            for _ in 0..<count {
                guard let run = try? reader.readRun() else { break }
                if let key = Key(stringValue: String(decoding: run, as: UTF8.self)) { keys.append(key) }
                guard (try? reader.skipValue()) != nil else { break }
            }
            return keys
        }

        /// The offset of `key`'s value: tried first where the last lookup
        /// ended, since members are usually read in order.
        private func find(_ key: Key) -> Int? {
            var name = key.stringValue
            return name.withUTF8 { wanted -> Int? in
                let hint = decoder.hints.count > depth ? decoder.hints[depth] : start
                for from in [hint, start] where from >= start && from < end {
                    var reader = CefWireReader(decoder.bytes, offset: from)
                    while reader.offset < end {
                        guard let run = try? reader.readRun() else { return nil }
                        let valueStart = reader.offset
                        if run.count == wanted.count, run.elementsEqual(UnsafeRawBufferPointer(wanted)) {
                            guard (try? reader.skipValue()) != nil else { return nil }
                            if decoder.hints.count > depth { decoder.hints[depth] = reader.offset }
                            return valueStart
                        }
                        guard (try? reader.skipValue()) != nil else { return nil }
                        if from != start, reader.offset >= end { break }
                    }
                    if from == start { break }
                }
                return nil
            }
        }

        private func value(_ key: Key) throws -> Int {
            guard let position = find(key) else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value for \(key.stringValue)"))
            }
            return position
        }

        func contains(_ key: Key) -> Bool { find(key) != nil }

        func decodeNil(forKey key: Key) throws -> Bool {
            try decoder.at(value(key), key: nil) { decoder.peekTag() == .null }
        }

        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
            try decoder.at(try value(key), key: nil) { try decoder.readBool(key) }
        }
        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            try decoder.at(try value(key), key: nil) { try decoder.readString(key) }
        }
        func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
            try decoder.at(try value(key), key: nil) { try decoder.readDouble(key) }
        }
        func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
            Float(try decoder.at(try value(key), key: nil) { try decoder.readDouble(key) })
        }
        func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try integer(type, key) }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try integer(type, key) }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try integer(type, key) }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try integer(type, key) }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try integer(type, key) }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try integer(type, key) }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try integer(type, key) }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try integer(type, key) }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try integer(type, key) }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try integer(type, key) }

        private func integer<I: FixedWidthInteger>(_ type: I.Type, _ key: Key) throws -> I {
            try decoder.at(try value(key), key: nil) { try decoder.readInteger(type, key) }
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            try decoder.at(try value(key), key: key) { try decoder.decode(type) }
        }

        func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
            guard let position = find(key) else { return nil }
            return try decoder.at(position, key: key) { decoder.peekTag() == .null ? nil : try decoder.decode(type) }
        }

        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            try decoder.at(try value(key), key: key) { try decoder.container(keyedBy: type) }
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try decoder.at(try value(key), key: key) { try decoder.unkeyedContainer() }
        }

        func superDecoder() throws -> any Decoder {
            guard let key = Key(stringValue: "super") else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "No super key"))
            }
            return try superDecoder(forKey: key)
        }

        func superDecoder(forKey key: Key) throws -> any Decoder {
            try decoder.subDecoder(at: try value(key))
        }
    }

    /// A decoder of its own for the value at `position`.
    fileprivate func subDecoder(at position: Int) throws -> any Decoder {
        let sub = payload.map { CefWireDecoder(payload: $0, offset: position) }
            ?? CefWireDecoder(bytes: bytes, offset: position)
        sub.codingPath = codingPath
        return sub
    }

    private struct UnkeyedContainer: UnkeyedDecodingContainer {
        let decoder: CefWireDecoder
        var position: Int
        let end: Int
        let count: Int?
        var codingPath: [any CodingKey]
        var currentIndex = 0

        init(decoder: CefWireDecoder, position: Int, end: Int, count: Int, codingPath: [any CodingKey]) {
            self.decoder = decoder
            self.position = position
            self.end = end
            self.count = count
            self.codingPath = codingPath
        }

        var isAtEnd: Bool { currentIndex >= (count ?? 0) }

        private struct Index: CodingKey {
            var intValue: Int?
            var stringValue: String { "Index \(intValue ?? 0)" }
            init(_ index: Int) { intValue = index }
            init?(intValue: Int) { self.intValue = intValue }
            init?(stringValue: String) { nil }
        }

        private mutating func next<R>(_ body: (CefWireDecoder) throws -> R) throws -> R {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(R.self, .init(
                    codingPath: codingPath + [Index(currentIndex)], debugDescription: "The array has no more elements"))
            }
            let saved = decoder.offset
            decoder.offset = position
            defer { decoder.offset = saved }
            let value = try body(decoder)
            // Primitive reads move the decoder; nested values too.
            position = decoder.offset
            currentIndex += 1
            return value
        }

        mutating func decodeNil() throws -> Bool {
            guard !isAtEnd, CefWireReader(decoder.bytes, offset: position).peekTagOrNil == .null else { return false }
            position += 1
            currentIndex += 1
            return true
        }

        mutating func decode(_ type: Bool.Type) throws -> Bool { try next { decoder in try decoder.readBool() } }
        mutating func decode(_ type: String.Type) throws -> String { try next { decoder in try decoder.readString() } }
        mutating func decode(_ type: Double.Type) throws -> Double { try next { decoder in try decoder.readDouble() } }
        mutating func decode(_ type: Float.Type) throws -> Float { Float(try next { decoder in try decoder.readDouble() }) }
        mutating func decode(_ type: Int.Type) throws -> Int { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: Int8.Type) throws -> Int8 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: Int16.Type) throws -> Int16 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: Int32.Type) throws -> Int32 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: Int64.Type) throws -> Int64 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: UInt.Type) throws -> UInt { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next { decoder in try decoder.readInteger(type) } }
        mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next { decoder in try decoder.readInteger(type) } }

        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let index = Index(currentIndex)
            return try next { decoder in
                decoder.codingPath.append(index)
                defer { decoder.codingPath.removeLast() }
                return try decoder.decode(type)
            }
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
            let container = try decoder.at(position, key: Index(currentIndex)) { try decoder.container(keyedBy: type) }
            try skip()
            return container
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let container = try decoder.at(position, key: Index(currentIndex)) { try decoder.unkeyedContainer() }
            try skip()
            return container
        }

        mutating func superDecoder() throws -> any Decoder {
            let sub = try decoder.subDecoder(at: position)
            try skip()
            return sub
        }

        private mutating func skip() throws {
            var reader = CefWireReader(decoder.bytes, offset: position)
            try reader.skipValue()
            position = reader.offset
            currentIndex += 1
        }
    }

    private struct SingleValue: SingleValueDecodingContainer {
        let decoder: CefWireDecoder
        var codingPath: [any CodingKey]

        func decodeNil() -> Bool { decoder.peekTag() == .null }
        func decode(_ type: Bool.Type) throws -> Bool { try decoder.readBool() }
        func decode(_ type: String.Type) throws -> String { try decoder.readString() }
        func decode(_ type: Double.Type) throws -> Double { try decoder.readDouble() }
        func decode(_ type: Float.Type) throws -> Float { Float(try decoder.readDouble()) }
        func decode(_ type: Int.Type) throws -> Int { try decoder.readInteger(type) }
        func decode(_ type: Int8.Type) throws -> Int8 { try decoder.readInteger(type) }
        func decode(_ type: Int16.Type) throws -> Int16 { try decoder.readInteger(type) }
        func decode(_ type: Int32.Type) throws -> Int32 { try decoder.readInteger(type) }
        func decode(_ type: Int64.Type) throws -> Int64 { try decoder.readInteger(type) }
        func decode(_ type: UInt.Type) throws -> UInt { try decoder.readInteger(type) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.readInteger(type) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.readInteger(type) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.readInteger(type) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.readInteger(type) }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type) }
    }
}

extension CefWireReader {
    var peekTagOrNil: CefWireTag? { try? peekTag() }
}

extension CefWirePayload {
    /// Decodes the payload's value at `reader`'s offset as `T`.
    func decode<T: Decodable>(_ type: T.Type = T.self, at offset: Int) throws -> T {
        try CefWireDecoder(payload: self, offset: offset).decode(type)
    }
}
