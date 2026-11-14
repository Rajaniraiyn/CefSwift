import CefBase
import Foundation

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
        // The renderer rejects a payload beyond the limits, so it is an
        // encoding error here rather than a value the page never gets.
        if base == 0, let problem = buffer.limitViolation {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "CefWire: \(problem)"))
        }
    }

    /// Types with a wire form of their own.
    ///
    /// The types are compared first: a cast of a value of another type
    /// would box it.
    private func encodeSpecial<T: Encodable>(_ value: T) throws -> Bool {
        if T.self == Data.self, let data = value as? Data {
            guard data.count <= CefWireLimits.maximumPayloadSize else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: codingPath, debugDescription: "CefWire: \(data.count) bytes are beyond the payload limit"))
            }
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

    fileprivate func write<I: BinaryInteger>(_ value: I, path: @autoclosure () -> [any CodingKey]) throws {
        if let small = Int32(exactly: value) {
            buffer.append(small)
        } else if let double = Double(exactly: value), abs(double) <= 9_007_199_254_740_992 {
            buffer.append(double)
        } else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: path(), debugDescription: "\(value) cannot be represented exactly as a JavaScript number"))
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
