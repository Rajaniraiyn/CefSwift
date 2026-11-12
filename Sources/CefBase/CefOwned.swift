import CCef

/// One reference to a CEF object that a callback received, owned by the
/// callback's scope.
///
/// It is not copyable, and it releases its reference when it goes out of
/// scope unless a consuming method took the reference first: handed it to
/// CEF (``passed()``, for a function that consumes its argument), adopted
/// it into a ``CefRef`` (``adopted()``), or released it early
/// (``release()``). So no path through a callback can leak the reference
/// or release it twice, and it costs no allocation.
///
/// ```swift
/// handler.pointee.on_before_resource_load = { s, browser, frame, request, callback in
///     let request = CefOwned(request)        // released on every return
///     guard let owner = cefOwner(Filter.self, s), let request else { return RV_CONTINUE }
///     …
/// }
/// ```
package struct CefOwned<T>: ~Copyable {
    package let pointer: UnsafeMutablePointer<T>

    /// Takes over the caller's reference; `nil` for a NULL pointer.
    package init?(_ pointer: UnsafeMutablePointer<T>?) {
        guard let pointer else { return nil }
        self.pointer = pointer
    }

    deinit {
        cefRelease(pointer)
    }

    /// Releases the reference now.
    package consuming func release() {
        // deinit releases it.
    }

    /// The pointer with this reference, for a CEF function that consumes
    /// its argument.
    package consuming func passed() -> UnsafeMutablePointer<T> {
        let pointer = self.pointer
        discard self
        return pointer
    }

    /// The reference in a box that outlives the scope.
    package consuming func adopted() -> CefRef<T> {
        CefRef(adopting: passed())
    }
}
