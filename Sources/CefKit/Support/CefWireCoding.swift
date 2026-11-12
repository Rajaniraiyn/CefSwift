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

// MARK: - Encoding

/// Encodes `Encodable` values into a ``CefWireBuffer``.
final class CefWireEncoder: Encoder {
    var buffer: CefWireBuffer
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    /// Open containers, innermost last. A write to a container first
    /// closes those opened after it.
    fileprivate var open: [CefWireBuffer.Container] = []
    /// A value is expected next; the first container request takes it.
    fileprivate var expectingValue = false
    /// The number of open containers when the current value started.
    fileprivate var valueBase = 0

    init(header: CefWireHeader? = nil) {
        buffer = CefWireBuffer()
        if let header { buffer.append(header: header) }
    }

    /// Writes `value` as one wire value.
    func encode<T: Encodable>(_ value: T) throws {
        let base = open.count
        let previous = (expectingValue, valueBase)
        expectingValue = true
        valueBase = base
        defer { (expectingValue, valueBase) = previous }
        if try encodeSpecial(value) {
            expectingValue = false
        } else {
            try value.encode(to: self)
        }
        if expectingValue {
            // The value wrote nothing.
            buffer.appendNull()
        }
        close(above: base)
    }

    /// Types with a wire form of their own.
    ///
    /// The types are compared first: a cast of a value of another type
    /// would box it.
    private func encodeSpecial<T: Encodable>(_ value: T) throws -> Bool {
        if T.self == Data.self, let data = value as? Data {
            appendBytes(data)
        } else if T.self == URL.self, let url = value as? URL {
            buffer.append(url.absoluteString)
        } else if T.self == CefJSON.self, let json = value as? CefJSON {
            json.write(to: &buffer)
        } else if T.self == Decimal.self, let decimal = value as? Decimal {
            buffer.append(NSDecimalNumber(decimal: decimal).doubleValue)
        } else {
            return false
        }
        return true
    }

    private func appendBytes(_ data: Data) {
        let count = data.count
        buffer.append(bytes: count) { target in
            data.withUnsafeBytes { source in
                if let base = source.baseAddress { target.copyMemory(from: base, byteCount: count) }
            }
        }
    }

    /// Closes open containers beyond the first `count`.
    fileprivate func close(above count: Int) {
        while open.count > count {
            buffer.close(open.removeLast())
        }
    }

    /// Takes the expected value for a container, or returns the one this
    /// value opened before.
    fileprivate func takeContainer(_ tag: CefWireTag) -> Int {
        if expectingValue {
            expectingValue = false
            open.append(buffer.open(tag))
            return open.count - 1
        }
        precondition(open.count == valueBase + 1, "CefWireEncoder: a value may encode one container")
        return valueBase
    }

    /// Starts writing an element of the container at `index`.
    fileprivate func beginElement(of index: Int) {
        close(above: index + 1)
        open[index].count += 1
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedContainer(encoder: self, index: takeContainer(.object), codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        UnkeyedContainer(encoder: self, index: takeContainer(.array), codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValue(encoder: self, codingPath: codingPath)
    }

    // MARK: Primitives

    fileprivate func write(_ value: Bool) { buffer.append(value) }
    fileprivate func write(_ value: String) { buffer.append(value) }
    fileprivate func write(_ value: Double) { buffer.append(value) }

    fileprivate func write<I: BinaryInteger>(_ value: I, path: [any CodingKey]) throws {
        if let small = Int32(exactly: value) {
            buffer.append(small)
        } else if let double = Double(exactly: value), abs(double) <= 9_007_199_254_740_992 {
            buffer.append(double)
        } else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: path, debugDescription: "\(value) cannot be represented exactly as a JavaScript number"))
        }
    }

    fileprivate func encodeNested<T: Encodable>(_ value: T, key: (any CodingKey)?) throws {
        if let key { codingPath.append(key) }
        defer { if key != nil { codingPath.removeLast() } }
        try encode(value)
    }

    // MARK: Containers

    private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let encoder: CefWireEncoder
        let index: Int
        var codingPath: [any CodingKey]

        private func key(_ key: Key) {
            encoder.beginElement(of: index)
            encoder.buffer.append(key: key.stringValue)
        }

        mutating func encodeNil(forKey key: Key) throws { self.key(key); encoder.buffer.appendNull() }
        mutating func encode(_ value: Bool, forKey key: Key) throws { self.key(key); encoder.write(value) }
        mutating func encode(_ value: String, forKey key: Key) throws { self.key(key); encoder.write(value) }
        mutating func encode(_ value: Double, forKey key: Key) throws { self.key(key); encoder.write(value) }
        mutating func encode(_ value: Float, forKey key: Key) throws { self.key(key); encoder.write(Double(value)) }
        mutating func encode(_ value: Int, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath + [key]) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath + [key]) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath + [key]) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { self.key(key); try encoder.write(value, path: codingPath + [key]) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            self.key(key)
            try encoder.encodeNested(value, key: key)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            self.key(key)
            encoder.expectingValue = true
            return encoder.container(keyedBy: keyType)
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            self.key(key)
            encoder.expectingValue = true
            return encoder.unkeyedContainer()
        }

        mutating func superEncoder() -> any Encoder { superEncoder(named: "super") }
        mutating func superEncoder(forKey key: Key) -> any Encoder { superEncoder(named: key.stringValue) }

        private func superEncoder(named name: String) -> any Encoder {
            encoder.beginElement(of: index)
            encoder.buffer.append(key: name)
            return NestedEncoder(parent: encoder)
        }
    }

    private struct UnkeyedContainer: UnkeyedEncodingContainer {
        let encoder: CefWireEncoder
        let index: Int
        var codingPath: [any CodingKey]
        var count: Int { Int(encoder.open.count > index ? encoder.open[index].count : 0) }

        private func element() { encoder.beginElement(of: index) }

        mutating func encodeNil() throws { element(); encoder.buffer.appendNull() }
        mutating func encode(_ value: Bool) throws { element(); encoder.write(value) }
        mutating func encode(_ value: String) throws { element(); encoder.write(value) }
        mutating func encode(_ value: Double) throws { element(); encoder.write(value) }
        mutating func encode(_ value: Float) throws { element(); encoder.write(Double(value)) }
        mutating func encode(_ value: Int) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int8) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int16) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int32) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: Int64) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt8) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt16) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt32) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode(_ value: UInt64) throws { element(); try encoder.write(value, path: codingPath) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            element()
            try encoder.encodeNested(value, key: nil)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            element()
            encoder.expectingValue = true
            return encoder.container(keyedBy: keyType)
        }

        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            element()
            encoder.expectingValue = true
            return encoder.unkeyedContainer()
        }

        mutating func superEncoder() -> any Encoder {
            element()
            return NestedEncoder(parent: encoder)
        }
    }

    private struct SingleValue: SingleValueEncodingContainer {
        let encoder: CefWireEncoder
        var codingPath: [any CodingKey]

        private func value() {
            precondition(encoder.expectingValue, "CefWireEncoder: a single value container encodes one value")
            encoder.expectingValue = false
        }

        mutating func encodeNil() throws { value(); encoder.buffer.appendNull() }
        mutating func encode(_ v: Bool) throws { value(); encoder.write(v) }
        mutating func encode(_ v: String) throws { value(); encoder.write(v) }
        mutating func encode(_ v: Double) throws { value(); encoder.write(v) }
        mutating func encode(_ v: Float) throws { value(); encoder.write(Double(v)) }
        mutating func encode(_ v: Int) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: Int8) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: Int16) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: Int32) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: Int64) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: UInt) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: UInt8) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: UInt16) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: UInt32) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode(_ v: UInt64) throws { value(); try encoder.write(v, path: codingPath) }
        mutating func encode<T: Encodable>(_ v: T) throws {
            precondition(encoder.expectingValue, "CefWireEncoder: a single value container encodes one value")
            // The nested value takes the expected slot itself.
            encoder.expectingValue = false
            try encoder.encode(v)
        }
    }

    /// The encoder handed out by `superEncoder`: writes one value.
    private final class NestedEncoder: Encoder {
        let parent: CefWireEncoder
        var codingPath: [any CodingKey] { parent.codingPath }
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        init(parent: CefWireEncoder) {
            self.parent = parent
            parent.expectingValue = true
        }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> { parent.container(keyedBy: type) }
        func unkeyedContainer() -> any UnkeyedEncodingContainer { parent.unkeyedContainer() }
        func singleValueContainer() -> any SingleValueEncodingContainer { parent.singleValueContainer() }
    }
}

extension CefWireEncoder {
    /// The wire form of `value`, after `header` and whatever `prefix`
    /// writes.
    static func payload(
        _ value: some Encodable, header: CefWireHeader? = nil, prefix: (inout CefWireBuffer) -> Void = { _ in }
    ) throws -> CefWireBuffer {
        let encoder = CefWireEncoder(header: header)
        prefix(&encoder.buffer)
        try encoder.encode(value)
        return encoder.takeBuffer()
    }

    /// The bytes written, leaving the encoder empty.
    func takeBuffer() -> CefWireBuffer {
        var taken = CefWireBuffer(capacity: 0)
        swap(&taken, &buffer)
        return taken
    }
}

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
