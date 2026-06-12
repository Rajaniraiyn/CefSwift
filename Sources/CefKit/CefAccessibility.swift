import CCef
import Foundation

/// A decoded snapshot of a `cef_value_t` from CEF's accessibility tree.
///
/// CEF delivers AX tree/location changes as nested `cef_value_t` graphs
/// (dictionaries, lists, scalars). The borrowed CEF objects are only valid for
/// the duration of the handler callback, so we eagerly decode the whole graph
/// into this Swift value type, which is then safe to keep and walk on the main
/// actor (e.g. to mirror into `NSAccessibilityElement`s).
public indirect enum CefAXValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case dictionary([String: CefAXValue])
    case list([CefAXValue])

    /// Convenience: the dictionary payload, if this is a `.dictionary`.
    public var dictionary: [String: CefAXValue]? {
        if case let .dictionary(d) = self { return d }
        return nil
    }
    /// Convenience: the list payload, if this is a `.list`.
    public var list: [CefAXValue]? {
        if case let .list(l) = self { return l }
        return nil
    }
    /// Convenience: the string payload, if this is a `.string`.
    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// Subscript into a dictionary value.
    public subscript(_ key: String) -> CefAXValue? { dictionary?[key] }
}

extension CefAXValue {
    /// Recursively decodes a borrowed `cef_value_t`. Depth-guarded against
    /// pathological/cyclic trees.
    static func decode(_ value: UnsafeMutablePointer<cef_value_t>?, depth: Int = 0) -> CefAXValue {
        guard let value, depth < 64 else { return .null }
        switch value.pointee.get_type?(value) {
        case VTYPE_BOOL:
            return .bool((value.pointee.get_bool?(value) ?? 0) != 0)
        case VTYPE_INT:
            return .int(Int(value.pointee.get_int?(value) ?? 0))
        case VTYPE_DOUBLE:
            return .double(value.pointee.get_double?(value) ?? 0)
        case VTYPE_STRING:
            return .string(CefStringUtil.takingUserFree(value.pointee.get_string?(value)) ?? "")
        case VTYPE_DICTIONARY:
            guard let dict = value.pointee.get_dictionary?(value) else { return .null }
            defer { cefRelease(UnsafeMutableRawPointer(dict)) }
            return decodeDictionary(dict, depth: depth)
        case VTYPE_LIST:
            guard let list = value.pointee.get_list?(value) else { return .null }
            defer { cefRelease(UnsafeMutableRawPointer(list)) }
            return decodeList(list, depth: depth)
        default:
            return .null
        }
    }

    private static func decodeDictionary(
        _ dict: UnsafeMutablePointer<cef_dictionary_value_t>, depth: Int
    ) -> CefAXValue {
        var out: [String: CefAXValue] = [:]
        guard let keyList = cef_string_list_alloc() else { return .dictionary(out) }
        defer { cef_string_list_free(keyList) }
        guard dict.pointee.get_keys?(dict, keyList) != 0 else { return .dictionary(out) }
        for i in 0..<cef_string_list_size(keyList) {
            var keyStr = cef_string_t()
            guard cef_string_list_value(keyList, i, &keyStr) != 0 else { continue }
            let key = CefStringUtil.string(from: keyStr)
            cef_string_utf16_clear(&keyStr)
            let child = CefStringUtil.withCefString(key) { cefKey -> UnsafeMutablePointer<cef_value_t>? in
                dict.pointee.get_value?(dict, cefKey)
            }
            if let child {
                out[key] = decode(child, depth: depth + 1)
                cefRelease(UnsafeMutableRawPointer(child))
            }
        }
        return .dictionary(out)
    }

    private static func decodeList(
        _ list: UnsafeMutablePointer<cef_list_value_t>, depth: Int
    ) -> CefAXValue {
        var out: [CefAXValue] = []
        let count = list.pointee.get_size?(list) ?? 0
        out.reserveCapacity(count)
        for i in 0..<count {
            let child = list.pointee.get_value?(list, i)
            out.append(decode(child, depth: depth + 1))
            if let child { cefRelease(UnsafeMutableRawPointer(child)) }
        }
        return .list(out)
    }
}

extension BrowserClient {
    /// Allocates the `cef_accessibility_handler_t` for an OSR browser. CEF
    /// invokes these on the UI thread (== main under the external pump) once
    /// accessibility is enabled via `set_accessibility_state(STATE_ENABLED)`.
    func makeAccessibilityHandler() {
        let handler = cefAllocate(cef_accessibility_handler_t.self, owner: self)
        handler.pointee.on_accessibility_tree_change = { handlerSelf, value in
            let decoded = CefAXValue.decode(value)
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrAccessibilityTreeDidChange(decoded)
            }
        }
        handler.pointee.on_accessibility_location_change = { handlerSelf, value in
            let decoded = CefAXValue.decode(value)
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrAccessibilityLocationDidChange(decoded)
            }
        }
        accessibilityPointer = handler
    }
}
