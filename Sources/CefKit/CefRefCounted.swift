import CCef
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
