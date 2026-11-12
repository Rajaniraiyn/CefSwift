import CCef
import CefBase

/// A JSON value, as it crosses between the browser process and pages.
///
/// JavaScript values are read and created through the V8 API, so no page
/// script, `JSON` object or prototype method takes part in the conversion.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == key }?.1
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    // MARK: Text

    /// Parses JSON text with Chromium's parser.
    init?(parsing text: String) {
        guard let value = CefStringUtil.withCefString(text, { cef_parse_json($0, JSON_PARSER_RFC) }) else {
            return nil
        }
        defer { cefRelease(value) }
        self.init(value)
    }

    /// Reads a `cef_value_t` tree.
    init(_ value: UnsafeMutablePointer<cef_value_t>) {
        switch value.pointee.get_type(value) {
        case VTYPE_BOOL:
            self = .bool(value.pointee.get_bool(value) != 0)
        case VTYPE_INT:
            self = .number(Double(value.pointee.get_int(value)))
        case VTYPE_DOUBLE:
            self = .number(value.pointee.get_double(value))
        case VTYPE_STRING:
            self = .string(CefStringUtil.takingUserFree(value.pointee.get_string(value)) ?? "")
        case VTYPE_LIST:
            guard let list = value.pointee.get_list(value) else {
                self = .array([])
                return
            }
            defer { cefRelease(list) }
            self = .array((0..<list.pointee.get_size(list)).map { index in
                guard let item = list.pointee.get_value(list, index) else { return .null }
                defer { cefRelease(item) }
                return JSONValue(item)
            })
        case VTYPE_DICTIONARY:
            guard let dictionary = value.pointee.get_dictionary(value), let keys = cef_string_list_alloc() else {
                self = .object([])
                return
            }
            defer {
                cefRelease(dictionary)
                cef_string_list_free(keys)
            }
            _ = dictionary.pointee.get_keys(dictionary, keys)
            self = .object(cefStrings(from: keys).map { key in
                let item = CefStringUtil.withCefString(key) { dictionary.pointee.get_value(dictionary, $0) }
                defer { cefRelease(item) }
                return (key, item.map(JSONValue.init) ?? .null)
            })
        default:
            self = .null
        }
    }

    /// JSON text.
    var text: String {
        var output = ""
        write(to: &output)
        return output
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            if !value.isFinite {
                output += "null"
            } else if value == value.rounded(), abs(value) < 1e15 {
                output += String(Int64(value))
            } else {
                output += String(value)
            }
        case .string(let value):
            JSONValue.writeString(value, to: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, (key, item)) in members.enumerated() {
                if index > 0 { output += "," }
                JSONValue.writeString(key, to: &output)
                output += ":"
                item.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - JavaScript values

extension JSONValue {
    /// A JavaScript value as `JSON.stringify` would write it, read through
    /// the V8 API: own enumerable properties, `undefined` and functions
    /// left out of objects and `null` in arrays, Dates as ISO strings, and
    /// `null` for a value that refers back to one of its containers.
    @MainActor
    init(_ value: V8Value) {
        var ancestors: [V8Value] = []
        self = JSONValue.read(value, ancestors: &ancestors) ?? .null
    }

    @MainActor
    private static func read(_ value: V8Value, ancestors: inout [V8Value]) -> JSONValue? {
        if value.isUndefined || value.isFunction { return nil }
        if value.isNull { return .null }
        if value.isBool { return .bool(value.boolValue) }
        if value.isInt { return .number(Double(value.intValue)) }
        if value.isUInt { return .number(Double(value.uintValue)) }
        if value.isDouble { return .number(value.doubleValue) }
        if value.isString { return .string(value.stringValue) }
        if value.isDate { return .string(isoDate(milliseconds: value.dateMilliseconds)) }
        guard value.isObject, !value.isArrayBuffer, !value.isPromise else { return .object([]) }
        guard ancestors.count < 64, !ancestors.contains(where: { $0.isSame(value) }) else { return .null }
        ancestors.append(value)
        defer { ancestors.removeLast() }
        if value.isArray {
            return .array((0..<value.arrayLength).map { index in
                value[index].flatMap { read($0, ancestors: &ancestors) } ?? .null
            })
        }
        return .object(value.keys.compactMap { key in
            guard let item = value[key], let json = read(item, ancestors: &ancestors) else { return nil }
            return (key, json)
        })
    }

    /// A JavaScript value for this JSON, created in the entered context.
    @MainActor
    func v8Value() -> V8Value {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            if value == value.rounded(), let int = Int32(exactly: value) { return .int(int) }
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let items):
            let array = V8Value.array(count: items.count)
            for (index, item) in items.enumerated() { array.set(index, item.v8Value()) }
            return array
        case .object(let members):
            let object = V8Value.object()
            for (key, item) in members { object.set(key, item.v8Value()) }
            return object
        }
    }

    /// `Date.prototype.toISOString`'s format.
    static func isoDate(milliseconds: Double) -> String {
        var time = cef_time_t()
        guard milliseconds.isFinite, cef_time_from_doublet(milliseconds / 1000, &time) != 0 else { return "" }
        func padded(_ value: Int32, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let fraction = Int32((milliseconds.truncatingRemainder(dividingBy: 1000) + 1000).truncatingRemainder(dividingBy: 1000))
        return "\(padded(time.year, 4))-\(padded(time.month, 2))-\(padded(time.day_of_month, 2))T"
            + "\(padded(time.hour, 2)):\(padded(time.minute, 2)):\(padded(time.second, 2)).\(padded(fraction, 3))Z"
    }
}
