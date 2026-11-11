import CCef
import CoreGraphics
import Foundation

// Internal helpers for the "extended struct" trick: CEF handler structs are
// allocated through ccef_object_alloc(), which prepends a hidden header
// holding an atomic refcount plus a retained Swift owner pointer. The owner
// is recovered inside C callbacks via ccef_object_get_swift().

/// Releases the retained Swift owner when a ccef object's refcount hits zero.
private let cefObjectOnZero: @convention(c) (UnsafeMutableRawPointer?) -> Void = { opaque in
    guard let opaque else { return }
    Unmanaged<AnyObject>.fromOpaque(opaque).release()
}

/// Allocates a zeroed, refcounted CEF struct (first member must be
/// `cef_base_ref_counted_t`) whose hidden header retains `owner`.
/// Initial refcount is 1, owned by the caller; handing the struct to CEF
/// transfers that reference.
func cefAllocate<T>(_ type: T.Type, owner: AnyObject) -> UnsafeMutablePointer<T> {
    let opaque = Unmanaged.passRetained(owner as AnyObject).toOpaque()
    guard let raw = ccef_object_alloc(MemoryLayout<T>.stride, opaque, cefObjectOnZero) else {
        Unmanaged<AnyObject>.fromOpaque(opaque).release()
        fatalError("CefSwift: out of memory allocating \(T.self)")
    }
    return raw.assumingMemoryBound(to: T.self)
}

/// Recovers the Swift owner installed by `cefAllocate` from the `self`
/// pointer CEF passes to a struct callback.
func cefOwner<T: AnyObject>(_ type: T.Type, _ cefSelf: UnsafeMutableRawPointer?) -> T? {
    guard let cefSelf, let opaque = ccef_object_get_swift(cefSelf) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue() as? T
}

/// Adds a reference to any CEF object (ours or CEF's) given a pointer to a
/// struct whose first member is `cef_base_ref_counted_t`.
func cefAddRef(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    base.pointee.add_ref?(base)
}

/// Releases a reference on any CEF object given a pointer to a struct whose
/// first member is `cef_base_ref_counted_t`.
func cefRelease(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    _ = base.pointee.release?(base)
}

// MARK: - Typed conveniences

/// Adds a reference to a CEF object given its typed pointer.
func cefAddRef<T>(_ object: UnsafeMutablePointer<T>?) {
    cefAddRef(UnsafeMutableRawPointer(object))
}

/// Releases a reference on a CEF object given its typed pointer.
func cefRelease<T>(_ object: UnsafeMutablePointer<T>?) {
    cefRelease(UnsafeMutableRawPointer(object))
}

/// Recovers the Swift owner from the typed `self` pointer of a CEF callback.
func cefOwner<T: AnyObject, S>(_ type: T.Type, _ cefSelf: UnsafeMutablePointer<S>?) -> T? {
    cefOwner(type, UnsafeMutableRawPointer(cefSelf))
}

/// Returns `handler` with an extra reference for the caller, the shape CEF
/// expects from every `get_*_handler` callback.
func cefRetained<T>(_ handler: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<T>? {
    cefAddRef(handler)
    return handler
}

/// Owns one reference to a CEF object and releases it on deinit.
///
/// CEF objects are thread-safe refcounted, so the box is `Sendable`; whether
/// the *methods* of the wrapped object may be called off the UI thread is
/// documented per CEF type.
final class CefRef<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>

    /// Takes ownership of the caller's +1 reference.
    init(adopting pointer: UnsafeMutablePointer<T>) {
        self.pointer = pointer
    }

    /// Adds its own reference, leaving the caller's untouched.
    init(retaining pointer: UnsafeMutablePointer<T>) {
        cefAddRef(pointer)
        self.pointer = pointer
    }

    deinit {
        cefRelease(pointer)
    }
}

extension CefRef {
    convenience init?(adopting pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        self.init(adopting: pointer)
    }
}

/// Reads a `cef_string_list_t` into Swift strings (the list stays owned by
/// the caller).
func cefStrings(from list: cef_string_list_t?) -> [String] {
    guard let list else { return [] }
    return (0..<cef_string_list_size(list)).compactMap { index in
        var value = cef_string_t()
        defer { cef_string_utf16_clear(&value) }
        guard cef_string_list_value(list, index, &value) != 0 else { return nil }
        return CefStringUtil.string(from: value)
    }
}

/// Converts an sRGB-convertible color to CEF's ARGB `cef_color_t`.
func cefColor(_ color: CGColor) -> cef_color_t {
    guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let c = srgb.components, c.count >= 4
    else { return 0 }
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
    return (byte(c[3]) << 24) | (byte(c[0]) << 16) | (byte(c[1]) << 8) | byte(c[2])
}
