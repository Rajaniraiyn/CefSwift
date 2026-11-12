import CCef
import Foundation
import CefBase

/// A JSON value: the currency type for everything that crosses the
/// Swift ↔ Chromium boundary as structured data — DevTools protocol messages,
/// JavaScript results, preferences.
///
/// ```swift
/// let params: CefJSON = ["expression": "1 + 1", "returnByValue": true]
/// let value = result["result"]["value"].intValue   // 2
/// ```
public enum CefJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CefJSON])
    case object([String: CefJSON])
}

// MARK: Accessors

extension CefJSON {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value,
              abs(value) < 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [CefJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: CefJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member lookup; `.null` for missing keys and non-objects, so lookups chain.
    public subscript(key: String) -> CefJSON {
        objectValue?[key] ?? .null
    }

    /// Element lookup; `.null` when out of range or not an array.
    public subscript(index: Int) -> CefJSON {
        guard let array = arrayValue, array.indices.contains(index) else { return .null }
        return array[index]
    }
}

// MARK: Literals

extension CefJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: CefJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, CefJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: Codable + serialization

extension CefJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CefJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CefJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        // JSON has no NaN or infinity: like `JSON.stringify`, encode them
        // as `null`, so one such number does not spoil the whole tree.
        case .number(let value) where !value.isFinite: try container.encodeNil()
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses JSON text. Throws on malformed input.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(CefJSON.self, from: data)
    }

    /// Converts any `Encodable` value into its JSON representation.
    public init(encoding value: some Encodable) throws {
        if let json = value as? CefJSON {
            self = json
        } else {
            try self.init(data: JSONEncoder().encode(value))
        }
    }

    /// The compact JSON text for this value. A number that is not finite
    /// becomes `null`, as `JSON.stringify` makes it.
    public var data: Data {
        // Every case encodes, non-finite numbers included (as `null`).
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }

    /// The compact JSON text for this value, safe to splice into JavaScript.
    public var text: String {
        String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Decodes this value as `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        if let json = self as? T { return json }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: cef_value_t bridging

extension CefJSON {
    /// Reads a borrowed `cef_value_t`.
    init(cefValue value: UnsafeMutablePointer<cef_value_t>?) {
        guard let value else {
            self = .null
            return
        }
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
            let list = value.pointee.get_list(value)
            defer { cefRelease(list) }
            guard let list else {
                self = .array([])
                return
            }
            self = .array((0..<list.pointee.get_size(list)).map { index in
                let element = list.pointee.get_value(list, index)
                defer { cefRelease(element) }
                return CefJSON(cefValue: element)
            })
        case VTYPE_DICTIONARY:
            let dictionary = value.pointee.get_dictionary(value)
            defer { cefRelease(dictionary) }
            self = .object(Self.members(of: dictionary))
        default:
            self = .null
        }
    }

    /// Reads a borrowed `cef_dictionary_value_t` into a Swift dictionary.
    static func members(of dictionary: UnsafeMutablePointer<cef_dictionary_value_t>?) -> [String: CefJSON] {
        guard let dictionary, let keys = cef_string_list_alloc() else { return [:] }
        defer { cef_string_list_free(keys) }
        _ = dictionary.pointee.get_keys(dictionary, keys)
        var members: [String: CefJSON] = [:]
        for key in cefStrings(from: keys) {
            CefStringUtil.withCefString(key) { cefKey in
                let element = dictionary.pointee.get_value(dictionary, cefKey)
                defer { cefRelease(element) }
                members[key] = CefJSON(cefValue: element)
            }
        }
        return members
    }

    /// Creates a new `cef_value_t` (+1, owned by the caller). CEF setters
    /// consume the reference of every object passed to them, so the children
    /// built here are handed over, not released.
    func makeCefValue() -> UnsafeMutablePointer<cef_value_t>? {
        guard let value = cef_value_create() else { return nil }
        switch self {
        case .null:
            _ = value.pointee.set_null(value)
        case .bool(let flag):
            _ = value.pointee.set_bool(value, flag ? 1 : 0)
        case .number(let number):
            if let exact = Int32(exactly: number) {
                _ = value.pointee.set_int(value, exact)
            } else {
                _ = value.pointee.set_double(value, number)
            }
        case .string(let string):
            CefStringUtil.withCefString(string) { _ = value.pointee.set_string(value, $0) }
        case .array(let elements):
            guard let list = cef_list_value_create() else { break }
            for (index, element) in elements.enumerated() {
                _ = list.pointee.set_value(list, index, element.makeCefValue())
            }
            _ = value.pointee.set_list(value, list)
        case .object(let members):
            guard let dictionary = cef_dictionary_value_create() else { break }
            for (key, member) in members {
                let child = member.makeCefValue()
                CefStringUtil.withCefString(key) { _ = dictionary.pointee.set_value(dictionary, $0, child) }
            }
            _ = value.pointee.set_dictionary(value, dictionary)
        }
        return value
    }
}
