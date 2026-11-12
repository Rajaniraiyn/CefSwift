import Foundation

/// A property-list value: what `cefapp.json` can say about an Info.plist or
/// an entitlements file. Decodes from JSON and converts to and from the
/// Foundation objects `PropertyListSerialization` reads and writes.
enum PlistValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// The value as `PropertyListSerialization` takes it.
    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .integer(let value): return value
        case .real(let value): return value
        case .date(let value): return value
        case .data(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .dictionary(let values): return values.mapValues(\.foundationObject)
        }
    }

    /// Converts a value that `PropertyListSerialization` or
    /// `JSONSerialization` produced. Returns nil for anything else.
    init?(foundationObject object: Any) {
        switch object {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            // Booleans are NSNumbers too; tell them apart by their type.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .real(value.doubleValue)
            } else {
                self = .integer(value.intValue)
            }
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .data(value)
        case let values as [Any]:
            var converted: [PlistValue] = []
            for value in values {
                guard let element = PlistValue(foundationObject: value) else { return nil }
                converted.append(element)
            }
            self = .array(converted)
        case let values as [String: Any]:
            var converted: [String: PlistValue] = [:]
            for (key, value) in values {
                guard let element = PlistValue(foundationObject: value) else { return nil }
                converted[key] = element
            }
            self = .dictionary(converted)
        default:
            return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [PlistValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var dictionaryValue: [String: PlistValue]? {
        if case .dictionary(let values) = self { return values }
        return nil
    }

    /// The strings in an array value, or the value itself if it is a
    /// string. Entitlements such as `keychain-access-groups` are arrays of
    /// strings.
    var strings: [String] {
        switch self {
        case .string(let value): return [value]
        case .array(let values): return values.compactMap(\.stringValue)
        default: return []
        }
    }

    /// Whether an entitlement with this value grants anything: `false`, an
    /// empty string and an empty array grant nothing.
    var isGranting: Bool {
        switch self {
        case .bool(let value): return value
        case .string(let value): return !value.isEmpty
        case .array(let values): return !values.isEmpty
        case .dictionary(let values): return !values.isEmpty
        default: return true
        }
    }

    /// Replaces each string, recursively.
    func mapStrings(_ transform: (String) throws -> String) rethrows -> PlistValue {
        switch self {
        case .string(let value): return .string(try transform(value))
        case .array(let values): return .array(try values.map { try $0.mapStrings(transform) })
        case .dictionary(let values): return .dictionary(try values.mapValues { try $0.mapStrings(transform) })
        default: return self
        }
    }
}

extension PlistValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .real(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let values = try? container.decode([PlistValue].self) {
            self = .array(values)
        } else if let values = try? container.decode([String: PlistValue].self) {
            self = .dictionary(values)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A property-list value cannot be null.")
        }
    }
}

/// A property-list dictionary, the shape of an Info.plist or an
/// entitlements file.
typealias PlistDictionary = [String: PlistValue]

enum Plist {
    /// Merges `overlay` into `base`. Dictionaries merge key by key, arrays
    /// are concatenated without repeating equal elements, and any other
    /// value in `overlay` replaces the one in `base`.
    static func merge(_ base: PlistDictionary, _ overlay: PlistDictionary) -> PlistDictionary {
        var result = base
        for (key, value) in overlay {
            result[key] = merge(result[key], value)
        }
        return result
    }

    private static func merge(_ base: PlistValue?, _ overlay: PlistValue) -> PlistValue {
        switch (base, overlay) {
        case (.dictionary(let old)?, .dictionary(let new)):
            return .dictionary(merge(old, new))
        case (.array(let old)?, .array(let new)):
            var combined = old
            for element in new where !combined.contains(element) {
                combined.append(element)
            }
            return .array(combined)
        default:
            return overlay
        }
    }

    /// Reads a property-list file whose top level is a dictionary: XML,
    /// binary or OpenStep.
    static func read(_ url: URL) throws -> PlistDictionary {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CefPluginError("Could not read \(url.path): \(error.localizedDescription)")
        }
        return try decode(data, source: url.path)
    }

    static func decode(_ data: Data, source: String) throws -> PlistDictionary {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw CefPluginError("\(source) is not a property list: \(error.localizedDescription)")
        }
        guard case .dictionary(let dictionary)? = PlistValue(foundationObject: object) else {
            throw CefPluginError("\(source) must contain a dictionary at its top level.")
        }
        return dictionary
    }

    static func xmlData(_ dictionary: PlistDictionary) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary.mapValues(\.foundationObject), format: .xml, options: 0)
    }

    static func write(_ dictionary: PlistDictionary, to url: URL) throws {
        try xmlData(dictionary).write(to: url)
    }
}
