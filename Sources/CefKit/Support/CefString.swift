import CCef
import Foundation

// Internal cef_string_t helpers. Creation/destruction is framework-free
// (backed by ccef_string_set_utf16) so these work in unit tests without the
// CEF framework loaded. Only `takingUserFree` touches a libcef export.

enum CefStringUtil {
    /// Reads a borrowed `cef_string_t` (UTF-16) into a Swift String.
    static func string(from cef: UnsafePointer<cef_string_t>?) -> String {
        guard let cef else { return "" }
        return string(from: cef.pointee)
    }

    /// Reads a borrowed `cef_string_t` value into a Swift String.
    static func string(from cef: cef_string_t) -> String {
        guard let str = cef.str, cef.length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: str, count: cef.length), as: UTF16.self)
    }

    /// Consumes a `cef_string_userfree_t` returned by CEF: reads it and
    /// frees it with `cef_string_userfree_utf16_free`. Requires the
    /// framework to be loaded.
    static func takingUserFree(_ cef: cef_string_userfree_t?) -> String? {
        guard let cef else { return nil }
        defer { cef_string_userfree_utf16_free(cef) }
        return string(from: cef.pointee)
    }

    /// Copies `value` into `target`, releasing any previous contents.
    /// Pass `nil` to clear the field.
    static func set(_ value: String?, into target: inout cef_string_t) {
        guard let value, !value.isEmpty else {
            ccef_string_clear(&target)
            return
        }
        let utf16 = Array(value.utf16)
        _ = utf16.withUnsafeBufferPointer { buffer in
            ccef_string_set_utf16(buffer.baseAddress, buffer.count, &target)
        }
    }

    /// Runs `body` with a temporary `cef_string_t` holding `value`.
    static func withCefString<R>(_ value: String, _ body: (UnsafePointer<cef_string_t>) throws -> R) rethrows -> R {
        var cef = cef_string_t()
        set(value, into: &cef)
        defer { ccef_string_clear(&cef) }
        return try body(&cef)
    }
}
