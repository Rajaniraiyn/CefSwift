import CCef
import CefBase

/// Converts between V8 values and the wire format, through the V8 C API
/// and nothing else: no page script, `JSON` object or prototype method
/// takes part, and no intermediate tree or JSON text is built.
///
/// Values are read as `JSON.stringify` would write them: own enumerable
/// properties, `undefined` and functions left out of objects and `null` in
/// arrays, Dates as ISO strings, `null` for a value that refers back to
/// one of its containers. An `ArrayBuffer` travels as bytes. Typed arrays
/// and `DataView`s are objects to the V8 C API, which cannot tell them
/// apart from others, so pass their `buffer`.
///
/// Every function runs inside a V8 context, on the renderer's main thread.
@MainActor
enum V8Wire {
    private typealias Value = UnsafeMutablePointer<cef_v8_value_t>

    /// The deepest nesting written; deeper values become `null`.
    static let maximumDepth = 64

    // MARK: V8 → wire

    /// Writes `value` (borrowed), `null` for a value JSON leaves out.
    ///
    /// An `ArrayBuffer` of at least ``CefWireBuffer/deferredThreshold``
    /// bytes is not copied here: the buffer reads it from the
    /// `ArrayBuffer`'s memory when the message is built. Build and send the
    /// message before returning to JavaScript, while the value cannot be
    /// collected or detached.
    static func write(_ value: UnsafeMutablePointer<cef_v8_value_t>?, to buffer: inout CefWireBuffer) {
        var ancestors: [Value] = []
        guard let value, write(value, to: &buffer, ancestors: &ancestors) else {
            buffer.appendNull()
            return
        }
    }

    /// Whether JSON leaves `value` out of an object.
    private static func isOmitted(_ value: Value) -> Bool {
        value.pointee.is_undefined(value) != 0 || value.pointee.is_function(value) != 0
    }

    /// Writes `value`; returns `false`, writing nothing, for a value JSON
    /// leaves out.
    private static func write(_ value: Value, to buffer: inout CefWireBuffer, ancestors: inout [Value]) -> Bool {
        let v = value.pointee
        if isOmitted(value) { return false }
        if v.is_null(value) != 0 {
            buffer.appendNull()
        } else if v.is_bool(value) != 0 {
            buffer.append(v.get_bool_value(value) != 0)
        } else if v.is_int(value) != 0 {
            buffer.append(v.get_int_value(value))
        } else if v.is_uint(value) != 0 {
            buffer.append(Double(v.get_uint_value(value)))
        } else if v.is_double(value) != 0 {
            buffer.append(v.get_double_value(value))
        } else if v.is_string(value) != 0 {
            buffer.append(utf16: value)
        } else if v.is_date(value) != 0 {
            buffer.append(JSONValue.isoDate(milliseconds: V8Value.milliseconds(of: v.get_date_value(value))))
        } else if v.is_array_buffer(value) != 0 {
            let count = v.get_array_buffer_byte_length(value)
            if let data = v.get_array_buffer_data(value), count > 0 {
                let source = UnsafeRawPointer(data)
                buffer.append(bytes: count) { $0.copyMemory(from: source, byteCount: count) }
            } else {
                buffer.append(bytes: 0) { _ in }
            }
        } else if v.is_object(value) == 0 || v.is_promise(value) != 0 {
            let empty = buffer.open(.object)
            buffer.close(empty, count: 0)
        } else if ancestors.count >= maximumDepth || ancestors.contains(where: { isSame($0, value) }) {
            buffer.appendNull()
        } else {
            ancestors.append(value)
            defer { ancestors.removeLast() }
            if v.is_array(value) != 0 {
                writeArray(value, to: &buffer, ancestors: &ancestors)
            } else {
                writeObject(value, to: &buffer, ancestors: &ancestors)
            }
        }
        return true
    }

    private static func writeArray(_ array: Value, to buffer: inout CefWireBuffer, ancestors: inout [Value]) {
        let length = Int(array.pointee.get_array_length(array))
        let container = buffer.open(.array)
        for index in 0..<length {
            let element = array.pointee.get_value_byindex(array, Int32(index))
            defer { cefRelease(element) }
            if element == nil || !write(element!, to: &buffer, ancestors: &ancestors) {
                buffer.appendNull()
            }
        }
        buffer.close(container, count: length)
    }

    private static func writeObject(_ object: Value, to buffer: inout CefWireBuffer, ancestors: inout [Value]) {
        let container = buffer.open(.object)
        var members = 0
        // A failed get_keys adds no key.
        cefForEachString(filledBy: { _ = object.pointee.get_keys(object, $0) }) { key in
            guard let member = object.pointee.get_value_bykey(object, key) else { return }
            defer { cefRelease(member) }
            guard !isOmitted(member) else { return }
            buffer.append(key: UnsafeBufferPointer(start: key.pointee.str, count: key.pointee.length))
            _ = write(member, to: &buffer, ancestors: &ancestors)
            members += 1
        }
        buffer.close(container, count: members)
    }

    private static func isSame(_ a: Value, _ b: Value) -> Bool {
        // `is_same` consumes its argument.
        cefAddRef(b)
        return a.pointee.is_same(a, b) != 0
    }

    // MARK: Wire → V8

    /// The V8 value for the wire value at `reader`, with one reference for
    /// the caller; `null` for malformed data.
    static func read(_ reader: inout CefWireReader) -> UnsafeMutablePointer<cef_v8_value_t>? {
        (try? readValue(&reader, depth: 0)) ?? cef_v8_value_create_null()
    }

    private static func readValue(_ reader: inout CefWireReader, depth: Int) throws -> Value? {
        switch try reader.readTag() {
        case .null: return cef_v8_value_create_null()
        case .false: return cef_v8_value_create_bool(0)
        case .true: return cef_v8_value_create_bool(1)
        case .int32: return cef_v8_value_create_int(try reader.readInt32Body())
        case .float64: return cef_v8_value_create_double(try reader.readDoubleBody())
        case .string:
            return CefStringUtil.withCefString(utf8: try reader.readRun()) { cef_v8_value_create_string($0) }
        case .bytes:
            return arrayBuffer(copying: try reader.readRun())
        case .array:
            let (_, count) = try reader.readContainer()
            guard let array = cef_v8_value_create_array(Int32(clamping: count)) else { return nil }
            for index in 0..<count {
                // The setter consumes the element's reference.
                let element = try readValue(&reader, depth: depth + 1) ?? cef_v8_value_create_null()
                _ = array.pointee.set_value_byindex(array, Int32(index), element)
            }
            return array
        case .object:
            let (_, count) = try reader.readContainer()
            guard let object = cef_v8_value_create_object(nil, nil) else { return nil }
            for _ in 0..<count {
                let key = try reader.readRun()
                let member = try readValue(&reader, depth: depth + 1) ?? cef_v8_value_create_null()
                CefStringUtil.withCefString(utf8: key) {
                    _ = object.pointee.set_value_bykey(object, $0, member, V8_PROPERTY_ATTRIBUTE_NONE)
                }
            }
            return object
        }
    }

    /// An `ArrayBuffer` holding a copy of `bytes`.
    ///
    /// The copy is the one the renderer cannot avoid: with V8's sandbox,
    /// which Chromium enables, an `ArrayBuffer` can only use memory inside
    /// the sandbox (`cef_v8_value_create_array_buffer` over outside memory
    /// returns NULL), so bytes from shared memory are copied into a backing
    /// store that the `ArrayBuffer` then owns, without a further copy.
    static func arrayBuffer(copying bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<cef_v8_value_t>? {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return cef_v8_value_create_array_buffer_with_copy(nil, 0)
        }
        if let store = cef_v8_backing_store_create(bytes.count) {
            if let target = store.pointee.data(store) {
                target.copyMemory(from: base, byteCount: bytes.count)
                // Consumes the store.
                return cef_v8_value_create_array_buffer_from_backing_store(store)
            }
            cefRelease(store)
        }
        return cef_v8_value_create_array_buffer_with_copy(UnsafeMutableRawPointer(mutating: base), bytes.count)
    }
}
