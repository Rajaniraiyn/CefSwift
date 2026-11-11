import CCef
import CoreGraphics
import Foundation

// Structs CefSwift implements are allocated by ccef_object_alloc, which
// places a hidden header before the struct holding an atomic reference count
// and a retained Swift owner. Callbacks recover the owner with
// ccef_object_get_swift.

/// Releases the Swift owner when an object's reference count reaches zero.
private let cefObjectOnZero: @convention(c) (UnsafeMutableRawPointer?) -> Void = { opaque in
    guard let opaque else { return }
    Unmanaged<AnyObject>.fromOpaque(opaque).release()
}

/// Allocates a zeroed CEF struct whose first member is
/// `cef_base_ref_counted_t`, retaining `owner` until the last reference is
/// released. The caller holds the one initial reference.
func cefAllocate<T>(_ type: T.Type, owner: AnyObject) -> UnsafeMutablePointer<T> {
    let opaque = Unmanaged.passRetained(owner).toOpaque()
    guard let raw = ccef_object_alloc(MemoryLayout<T>.stride, opaque, cefObjectOnZero) else {
        Unmanaged<AnyObject>.fromOpaque(opaque).release()
        fatalError("CefSwift: out of memory allocating \(T.self)")
    }
    return raw.assumingMemoryBound(to: T.self)
}

/// The owner passed to `cefAllocate`, recovered from the `self` pointer of a
/// callback.
func cefOwner<T: AnyObject>(_ type: T.Type, _ cefSelf: UnsafeMutableRawPointer?) -> T? {
    guard let cefSelf, let opaque = ccef_object_get_swift(cefSelf) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue() as? T
}

/// Adds a reference to a reference-counted CEF object, ours or Chromium's.
func cefAddRef(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    base.pointee.add_ref(base)
}

/// Releases a reference to a reference-counted CEF object, ours or Chromium's.
func cefRelease(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    _ = base.pointee.release(base)
}

// MARK: - Typed pointers

/// Adds a reference to a reference-counted CEF object.
func cefAddRef<T>(_ object: UnsafeMutablePointer<T>?) {
    cefAddRef(UnsafeMutableRawPointer(object))
}

/// Releases a reference to a reference-counted CEF object.
func cefRelease<T>(_ object: UnsafeMutablePointer<T>?) {
    cefRelease(UnsafeMutableRawPointer(object))
}

/// The owner passed to `cefAllocate`, recovered from the `self` pointer of a
/// callback.
func cefOwner<T: AnyObject, S>(_ type: T.Type, _ cefSelf: UnsafeMutablePointer<S>?) -> T? {
    cefOwner(type, UnsafeMutableRawPointer(cefSelf))
}

/// `object` with a reference added for the caller, as `get_*_handler`
/// callbacks must return it.
func cefRetained<T>(_ object: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<T>? {
    cefAddRef(object)
    return object
}

/// Owns one reference to a CEF object and releases it on deinit.
///
/// Reference counting is thread-safe, so the box is `Sendable`; which
/// threads may call the object's methods depends on its CEF type.
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
    /// Gives up ownership: returns the pointer with an extra reference for
    /// the caller, typically to hand to CEF.
    func detach() -> UnsafeMutablePointer<T> {
        cefAddRef(pointer)
        return pointer
    }

    convenience init?(adopting pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        self.init(adopting: pointer)
    }
}

/// The strings in a borrowed `cef_string_list_t`.
func cefStrings(from list: cef_string_list_t?) -> [String] {
    guard let list else { return [] }
    return (0..<cef_string_list_size(list)).compactMap { index in
        var value = cef_string_t()
        defer { cef_string_utf16_clear(&value) }
        guard cef_string_list_value(list, index, &value) != 0 else { return nil }
        return CefStringUtil.string(from: value)
    }
}

/// A color as CEF's sRGB ARGB `cef_color_t`, or transparent black when the
/// color cannot be converted.
func cefColor(_ color: CGColor) -> cef_color_t {
    guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let c = srgb.components, c.count >= 4
    else { return 0 }
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
    return (byte(c[3]) << 24) | (byte(c[0]) << 16) | (byte(c[1]) << 8) | byte(c[2])
}
