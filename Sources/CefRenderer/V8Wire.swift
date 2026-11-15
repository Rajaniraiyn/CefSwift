import CCef
import CefBase

/// Converts between V8 values and the wire format, through the V8 C API:
/// no `JSON` object and no injected script takes part, and no
/// intermediate tree or JSON text is built.
///
/// Values are read as `JSON.stringify` would write them: an object's
/// members are its own enumerable string-keyed properties, in the order
/// the document's `Object.keys` lists them; `undefined` and functions are
/// left out of objects and are `null` in arrays; Dates are ISO strings;
/// and a value that refers back to one of its containers, or nests deeper
/// than `CefWireLimits.maximumDepth`, is `null`. An `ArrayBuffer` travels
/// as bytes. Typed arrays and `DataView`s are objects to the V8 C API,
/// which cannot tell them apart from others, so pass their `buffer`. A
/// `Proxy` is an object to the C API too, so a proxied array travels as an
/// object with index keys.
///
/// Reading properties runs page code (getters, `Proxy` traps, and
/// `Object.keys` itself, which a page may replace), and that code can
/// throw. Writing then fails as a whole with that exception, rather than
/// sending what was read so far.
///
/// Every function runs inside a V8 context, on the renderer's main thread.
@MainActor
enum V8Wire {
    private typealias Value = UnsafeMutablePointer<cef_v8_value_t>

    /// The deepest nesting written; deeper values become `null`.
    static let maximumDepth = CefWireLimits.maximumDepth

    // MARK: V8 → wire

    /// Writes `value` (borrowed), `null` for a value JSON leaves out.
    ///
    /// Throws when page code run by the walk throws, or when the value is
    /// beyond `CefWireLimits`; `buffer` then holds part of a value, to be
    /// discarded.
    ///
    /// An `ArrayBuffer` of at least ``CefWireBuffer/deferredThreshold``
    /// bytes is not copied here when nothing is read after it: the buffer
    /// copies it from the `ArrayBuffer`'s memory as the message is built,
    /// once. Before the walk next runs anything that can run page code, it
    /// copies such bytes into the buffer instead (a second copy), since
    /// that code could detach the `ArrayBuffer` or free its memory. So
    /// build and send the message before returning to JavaScript or
    /// running anything else in the context.
    static func write(_ value: UnsafeMutablePointer<cef_v8_value_t>?, to buffer: inout CefWireBuffer) throws(V8Exception) {
        var walk = Walk()
        guard let value, try walk.write(value, to: &buffer) else {
            buffer.appendNull()
            return
        }
        if let problem = buffer.limitViolation { throw V8Exception(message: "The value cannot be sent: \(problem).") }
    }

    /// Whether JSON leaves `value` out of an object.
    private static func isOmitted(_ value: Value) -> Bool {
        value.pointee.is_undefined(value) != 0 || value.pointee.is_function(value) != 0
    }

    /// The exception `value`'s last call threw, cleared, or `fallback`.
    private static func exception(of value: Value, _ fallback: String) -> V8Exception {
        defer { _ = value.pointee.clear_exception(value) }
        guard value.pointee.has_exception(value) != 0 else { return V8Exception(message: fallback) }
        return V8Exception(adopting: value.pointee.get_exception(value)) ?? V8Exception(message: fallback)
    }

    /// One walk over a value.
    @MainActor
    private struct Walk {
        var ancestors: [Value] = []
        /// The context's `Object.keys`, looked up when first needed.
        var objectKeys: V8Value?

        /// Writes `value`; returns `false`, writing nothing, for a value
        /// JSON leaves out.
        mutating func write(_ value: Value, to buffer: inout CefWireBuffer) throws(V8Exception) -> Bool {
            let v = value.pointee
            if isOmitted(value) { return false }
            guard buffer.valueCount < CefWireLimits.maximumValueCount,
                  buffer.totalCount <= CefWireLimits.maximumPayloadSize
            else { throw V8Exception(message: "The value cannot be sent: \(buffer.limitViolation ?? "it is too large").") }
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
                try writeArrayBuffer(value, to: &buffer)
            } else if v.is_object(value) == 0 || v.is_promise(value) != 0 {
                let empty = buffer.open(.object)
                buffer.close(empty, count: 0)
            } else if ancestors.count >= maximumDepth || ancestors.contains(where: { isSame($0, value) }) {
                buffer.appendNull()
            } else {
                ancestors.append(value)
                defer { ancestors.removeLast() }
                if v.is_array(value) != 0 {
                    try writeArray(value, to: &buffer)
                } else {
                    try writeObject(value, to: &buffer)
                }
            }
            return true
        }

        /// The bytes of an `ArrayBuffer`. CEF's pointer to them is valid
        /// while the `cef_v8_value_t` lives, and only page code can detach
        /// the buffer, so a deferred copy keeps the value and the walk
        /// copies the bytes in before running page code
        /// (``CefWireBuffer/materializeDeferred()``).
        private func writeArrayBuffer(_ value: Value, to buffer: inout CefWireBuffer) throws(V8Exception) {
            let count = value.pointee.get_array_buffer_byte_length(value)
            guard count <= CefWireLimits.maximumPayloadSize - buffer.totalCount else {
                throw V8Exception(message: "The value cannot be sent: an ArrayBuffer of \(count) bytes is too large.")
            }
            guard count > 0, let data = value.pointee.get_array_buffer_data(value) else {
                buffer.append(bytes: 0) { _ in }
                return
            }
            let source = UnsafeRawPointer(data)
            cefAddRef(value)
            let owner = V8Value(adopting: value)
            buffer.append(bytes: count) { target in
                withExtendedLifetime(owner) { target.copyMemory(from: source, byteCount: count) }
            }
        }

        private mutating func writeArray(_ array: Value, to buffer: inout CefWireBuffer) throws(V8Exception) {
            let length = Int(array.pointee.get_array_length(array))
            // CEF reports a length beyond `Int32.max` as negative.
            guard length >= 0, length <= CefWireLimits.maximumValueCount - buffer.valueCount else {
                throw V8Exception(message: "The value cannot be sent: an array of \(UInt32(truncatingIfNeeded: length)) elements is too long.")
            }
            let container = buffer.open(.array)
            for index in 0..<length {
                // An element may be a getter.
                buffer.materializeDeferred()
                guard let element = array.pointee.get_value_byindex(array, Int32(index)) else {
                    throw exception(of: array, "Element \(index) could not be read.")
                }
                defer { cefRelease(element) }
                if try !write(element, to: &buffer) {
                    buffer.appendNull()
                }
            }
            buffer.close(container, count: length)
        }

        private mutating func writeObject(_ object: Value, to buffer: inout CefWireBuffer) throws(V8Exception) {
            let keys = try ownKeys(of: object, buffer: &buffer)
            let keyCount = Int(keys.raw.pointee.get_array_length(keys.raw))
            let container = buffer.open(.object)
            var members = 0
            for index in 0..<max(keyCount, 0) {
                buffer.materializeDeferred()
                guard let key = keys.raw.pointee.get_value_byindex(keys.raw, Int32(index)) else {
                    throw exception(of: keys.raw, "The object's keys could not be read.")
                }
                defer { cefRelease(key) }
                guard key.pointee.is_string(key) != 0 else {
                    throw V8Exception(message: "Object.keys returned a key that is not a string.")
                }
                let name = key.pointee.get_string_value(key)
                defer { if let name { cef_string_userfree_utf16_free(name) } }
                // A getter or a `Proxy` trap may run, and throw.
                guard let member = object.pointee.get_value_bykey(object, name) else {
                    throw exception(of: object, "A property could not be read.")
                }
                defer { cefRelease(member) }
                guard !isOmitted(member) else { continue }
                buffer.append(key: UnsafeBufferPointer(start: name?.pointee.str, count: name?.pointee.length ?? 0))
                _ = try write(member, to: &buffer)
                members += 1
            }
            buffer.close(container, count: members)
        }

        /// `Object.keys(object)`: own enumerable string keys, as
        /// `JSON.stringify` reads them. CEF's `get_keys` is not used: it
        /// lists enumerable properties of the prototype chain too, and a
        /// `Proxy` whose trap throws makes it abort the renderer, where a
        /// call reports the exception.
        private mutating func ownKeys(of object: Value, buffer: inout CefWireBuffer) throws(V8Exception) -> V8Value {
            buffer.materializeDeferred()
            let keysFunction = try objectKeysFunction()
            cefAddRef(object)
            var argument: Value? = object
            guard let result = keysFunction.raw.pointee.execute_function(keysFunction.raw, nil, 1, &argument) else {
                throw exception(of: keysFunction.raw, "The object's keys could not be read.")
            }
            let keys = V8Value(adopting: result)
            guard keys.raw.pointee.is_array(keys.raw) != 0 else {
                throw V8Exception(message: "Object.keys did not return an array.")
            }
            return keys
        }

        private mutating func objectKeysFunction() throws(V8Exception) -> V8Value {
            if let objectKeys { return objectKeys }
            guard let context = cef_v8_context_get_current_context() else {
                throw V8Exception(message: "There is no JavaScript context.")
            }
            defer { cefRelease(context) }
            guard let global = V8Value(adopting: context.pointee.get_global(context)),
                  let object = global["Object"], let keys = object["keys"], keys.isFunction
            else { throw V8Exception(message: "Object.keys is not available.") }
            objectKeys = keys
            return keys
        }
    }

    private static func isSame(_ a: Value, _ b: Value) -> Bool {
        // `is_same` consumes its argument.
        cefAddRef(b)
        return a.pointee.is_same(a, b) != 0
    }

    // MARK: Wire → V8

    /// The V8 value for the wire value at `reader`, with one reference for
    /// the caller; `null` for malformed data or data beyond
    /// `CefWireLimits`, checked before any value is made.
    static func read(_ reader: inout CefWireReader) -> UnsafeMutablePointer<cef_v8_value_t>? {
        guard (try? reader.validateValue()) != nil else { return cef_v8_value_create_null() }
        return (try? readValue(&reader, depth: 0)) ?? cef_v8_value_create_null()
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
            guard depth < maximumDepth else { throw CefWireReader.Failure.beyondLimits }
            let (_, count) = try reader.readContainer()
            guard let array = cef_v8_value_create_array(Int32(clamping: count)) else { return nil }
            for index in 0..<count {
                // The setter consumes the element's reference.
                let element = try readValue(&reader, depth: depth + 1) ?? cef_v8_value_create_null()
                _ = array.pointee.set_value_byindex(array, Int32(index), element)
            }
            return array
        case .object:
            guard depth < maximumDepth else { throw CefWireReader.Failure.beyondLimits }
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
