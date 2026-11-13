import CCef

// Structs CefSwift implements are allocated by ccef_object_alloc, which
// places a hidden header before the struct holding an atomic reference count
// and a retained Swift owner. Callbacks recover the owner with
// ccef_object_get_swift.

/// Releases the Swift owner when an object's reference count reaches zero.
private let cefObjectOnZero: @convention(c) (UnsafeMutableRawPointer?) -> Void = { opaque in
    guard let opaque else { return }
    let owner = Unmanaged<AnyObject>.fromOpaque(opaque)
    CefCensus.add(.implemented(String(describing: type(of: owner.takeUnretainedValue()))), -1)
    owner.release()
}

/// Allocates a zeroed CEF struct whose first member is
/// `cef_base_ref_counted_t`, retaining `owner` until the last reference is
/// released. The caller holds the one initial reference.
package func cefAllocate<T>(_ type: T.Type, owner: AnyObject) -> UnsafeMutablePointer<T> {
    let opaque = Unmanaged.passRetained(owner).toOpaque()
    CefCensus.add(.implemented(String(describing: Swift.type(of: owner))), 1)
    guard let raw = ccef_object_alloc(MemoryLayout<T>.stride, opaque, cefObjectOnZero) else {
        Unmanaged<AnyObject>.fromOpaque(opaque).release()
        fatalError("CefSwift: out of memory allocating a CEF object")
    }
    return raw.assumingMemoryBound(to: T.self)
}

/// The owner passed to `cefAllocate`, recovered from the `self` pointer of a
/// callback.
package func cefOwner<T: AnyObject>(_ type: T.Type, _ cefSelf: UnsafeMutableRawPointer?) -> T? {
    guard let cefSelf, let opaque = ccef_object_get_swift(cefSelf) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue() as? T
}

/// Adds a reference to a reference-counted CEF object, ours or Chromium's.
package func cefAddRef(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    base.pointee.add_ref(base)
}

/// Releases a reference to a reference-counted CEF object, ours or Chromium's.
package func cefRelease(_ object: UnsafeMutableRawPointer?) {
    guard let object else { return }
    let base = object.assumingMemoryBound(to: cef_base_ref_counted_t.self)
    _ = base.pointee.release(base)
}

// MARK: - Typed pointers

/// Adds a reference to a reference-counted CEF object.
package func cefAddRef<T>(_ object: UnsafeMutablePointer<T>?) {
    cefAddRef(UnsafeMutableRawPointer(object))
}

/// Releases a reference to a reference-counted CEF object.
package func cefRelease<T>(_ object: UnsafeMutablePointer<T>?) {
    cefRelease(UnsafeMutableRawPointer(object))
}

/// The owner passed to `cefAllocate`, recovered from the `self` pointer of a
/// callback.
package func cefOwner<T: AnyObject, S>(_ type: T.Type, _ cefSelf: UnsafeMutablePointer<S>?) -> T? {
    cefOwner(type, UnsafeMutableRawPointer(cefSelf))
}

/// `object` with a reference added for the caller, as `get_*_handler`
/// callbacks must return it.
package func cefRetained<T>(_ object: UnsafeMutablePointer<T>?) -> UnsafeMutablePointer<T>? {
    cefAddRef(object)
    return object
}

/// Owns one reference to a CEF object and releases it on deinit.
///
/// Reference counting is thread-safe, so the box is `Sendable`; which
/// threads may call the object's methods depends on its CEF type.
package final class CefRef<T>: @unchecked Sendable {
    package let pointer: UnsafeMutablePointer<T>

    /// Takes ownership of the caller's +1 reference.
    package init(adopting pointer: UnsafeMutablePointer<T>) {
        self.pointer = pointer
        CefCensus.add(.reference(String(describing: T.self)), 1)
    }

    /// Adds its own reference, leaving the caller's untouched.
    package init(retaining pointer: UnsafeMutablePointer<T>) {
        cefAddRef(pointer)
        self.pointer = pointer
        CefCensus.add(.reference(String(describing: T.self)), 1)
    }

    deinit {
        CefCensus.add(.reference(String(describing: T.self)), -1)
        cefRelease(pointer)
    }
}

extension CefRef {
    /// The pointer with a reference added for the caller, typically to hand
    /// to a CEF function that consumes it. The box keeps its own reference.
    package func retainedPointer() -> UnsafeMutablePointer<T> {
        cefAddRef(pointer)
        return pointer
    }

    package convenience init?(adopting pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        self.init(adopting: pointer)
    }
}

/// The strings in a borrowed `cef_string_list_t`.
package func cefStrings(from list: cef_string_list_t?) -> [String] {
    var strings: [String] = []
    cefForEachString(in: list) { strings.append(CefStringUtil.string(from: $0)) }
    return strings
}

/// Calls `body` with each string in a borrowed `cef_string_list_t`, as a
/// `cef_string_t` valid for the call, so a key can be looked up with CEF's
/// own string and decoded at most once.
package func cefForEachString(in list: cef_string_list_t?, _ body: (UnsafePointer<cef_string_t>) -> Void) {
    guard let list else { return }
    for index in 0..<cef_string_list_size(list) {
        var value = cef_string_t()
        defer { cef_string_utf16_clear(&value) }
        guard cef_string_list_value(list, index, &value) != 0 else { continue }
        body(&value)
    }
}
