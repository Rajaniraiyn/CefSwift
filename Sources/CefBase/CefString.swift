import CCef

/// Conversions between Swift strings and UTF-16 `cef_string_t`.
///
/// Everything except ``takingUserFree(_:)`` works without the framework
/// loaded, because CCef implements string storage itself.
///
/// Swift strings are UTF-8 and CEF's are UTF-16, so every crossing
/// transcodes once. Nothing here transcodes twice or keeps an
/// intermediate array: strings going into CEF are transcoded straight
/// into the buffer CEF reads (on the stack for short strings), and
/// strings coming out are decoded straight from CEF's buffer.
package enum CefStringUtil {
    /// Strings up to this many UTF-8 bytes go into CEF from a stack buffer.
    static let stackLimit = 1024

    /// Reads a borrowed `cef_string_t` (UTF-16) into a Swift String.
    package static func string(from cef: UnsafePointer<cef_string_t>?) -> String {
        guard let cef else { return "" }
        return string(from: cef.pointee)
    }

    /// Reads a borrowed `cef_string_t` value into a Swift String.
    package static func string(from cef: cef_string_t) -> String {
        guard let str = cef.str, cef.length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: str, count: cef.length), as: UTF16.self)
    }

    /// Reads and frees a `cef_string_userfree_t` that CEF returned.
    package static func takingUserFree(_ cef: cef_string_userfree_t?) -> String? {
        guard let cef else { return nil }
        defer { cef_string_userfree_utf16_free(cef) }
        return string(from: cef.pointee)
    }

    /// Whether a borrowed `cef_string_t` holds exactly the ASCII text
    /// `ascii`, compared without making a Swift string.
    package static func equals(_ cef: UnsafePointer<cef_string_t>?, _ ascii: StaticString) -> Bool {
        let length = cef?.pointee.length ?? 0
        guard length == ascii.utf8CodeUnitCount else { return false }
        guard length > 0, let str = cef?.pointee.str else { return true }
        let bytes = ascii.utf8Start
        for index in 0..<length where str[index] != UInt16(bytes[index]) { return false }
        return true
    }

    /// Whether a borrowed `cef_string_t` starts with the ASCII text `prefix`.
    package static func hasPrefix(_ cef: UnsafePointer<cef_string_t>?, _ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard let cef, cef.pointee.length >= count else { return false }
        guard count > 0, let str = cef.pointee.str else { return true }
        let bytes = prefix.utf8Start
        for index in 0..<count where str[index] != UInt16(bytes[index]) { return false }
        return true
    }

    /// Copies `value` into `target`, releasing its previous contents. `nil`
    /// or an empty string clears it. One allocation, which `target` owns.
    package static func set(_ value: String?, into target: inout cef_string_t) {
        ccef_string_clear(&target)
        guard var value, !value.isEmpty else { return }
        value.withUTF8 { utf8 in
            let capacity = utf8.count + 1
            let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: capacity)
            let count = transcode(utf8, into: storage)
            storage[count] = 0
            target.str = storage
            target.length = count
            target.dtor = cefStringFree
        }
    }

    /// Runs `body` with a temporary `cef_string_t` holding `value`. CEF
    /// copies a string it keeps, so the storage only lives for the call:
    /// on the stack up to ``stackLimit`` bytes, else one allocation.
    package static func withCefString<R>(_ value: String, _ body: (UnsafePointer<cef_string_t>) throws -> R) rethrows -> R {
        var value = value
        return try value.withUTF8 { utf8 in try withCefString(utf8: UnsafeRawBufferPointer(utf8), body) }
    }

    /// Runs `body` with a temporary `cef_string_t` holding the UTF-8 text
    /// in `utf8`, which is not validated beyond what UTF-16 needs
    /// (malformed sequences become U+FFFD).
    package static func withCefString<R>(
        utf8: UnsafeRawBufferPointer, _ body: (UnsafePointer<cef_string_t>) throws -> R
    ) rethrows -> R {
        let bytes = utf8.bindMemory(to: UInt8.self)
        if bytes.isEmpty {
            var empty = cef_string_t()
            return try body(&empty)
        }
        // A UTF-8 string has at most as many UTF-16 units as bytes.
        if bytes.count <= stackLimit {
            return try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: bytes.count) { buffer in
                var cef = cef_string_t(str: buffer.baseAddress, length: transcode(bytes, into: buffer.baseAddress!), dtor: nil)
                return try body(&cef)
            }
        }
        let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: bytes.count)
        defer { storage.deallocate() }
        var cef = cef_string_t(str: storage, length: transcode(bytes, into: storage), dtor: nil)
        return try body(&cef)
    }

    /// Transcodes UTF-8 into UTF-16 at `target`, which has room for
    /// `utf8.count` units. Returns the number of units written.
    static func transcode(_ utf8: UnsafeBufferPointer<UInt8>, into target: UnsafeMutablePointer<UInt16>) -> Int {
        var count = 0
        // ASCII, the common case, needs no decoder.
        var index = 0
        while index < utf8.count, utf8[index] < 0x80 {
            target[index] = UInt16(utf8[index])
            index += 1
        }
        count = index
        guard index < utf8.count else { return count }
        _ = Swift.transcode(
            utf8[index...].makeIterator(), from: UTF8.self, to: UTF16.self, stoppingOnError: false
        ) { unit in
            target[count] = unit
            count += 1
        }
        return count
    }
}

/// A `cef_string_t` with fixed contents for the life of the process,
/// for names passed to CEF again and again: message names, switches,
/// header and property names. Its storage is never freed.
package final class CefStaticString: @unchecked Sendable {
    // Immutable after init; the storage is never written or freed again.
    private let storage: UnsafeMutablePointer<cef_string_t>

    package init(_ value: StaticString) {
        let count = value.utf8CodeUnitCount
        let units = UnsafeMutablePointer<UInt16>.allocate(capacity: count + 1)
        let written = CefStringUtil.transcode(UnsafeBufferPointer(start: value.utf8Start, count: count), into: units)
        units[written] = 0
        storage = .allocate(capacity: 1)
        storage.initialize(to: cef_string_t(str: units, length: written, dtor: nil))
        text = String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: count), as: UTF8.self)
    }

    /// The string as a Swift String.
    package let text: String

    /// The string for a CEF function, which only reads it.
    package var pointer: UnsafePointer<cef_string_t> { UnsafePointer(storage) }

    /// Whether a borrowed `cef_string_t` holds this string.
    package func matches(_ cef: UnsafePointer<cef_string_t>?) -> Bool {
        guard let cef else { return storage.pointee.length == 0 }
        let length = storage.pointee.length
        guard cef.pointee.length == length else { return false }
        guard length > 0 else { return true }
        guard let mine = storage.pointee.str, let theirs = cef.pointee.str else { return false }
        for index in 0..<length where mine[index] != theirs[index] { return false }
        return true
    }
}

private let cefStringFree: @convention(c) (UnsafeMutablePointer<UInt16>?) -> Void = { pointer in
    pointer?.deallocate()
}
