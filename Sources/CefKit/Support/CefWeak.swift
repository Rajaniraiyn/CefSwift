/// A weak reference that never changes which object it names, so a
/// `Sendable` callback owner can hold one.
///
/// `weak let` says the same without a box, but needs Swift 6.2; the package
/// builds with 6.0. The reference is written once, in `init`, and reading a
/// weak reference is safe on any thread, which is what `@unchecked` vouches
/// for.
final class CefWeak<Object: AnyObject & Sendable>: @unchecked Sendable {
    private weak var reference: Object?

    init(_ object: Object?) {
        reference = object
    }

    var object: Object? { reference }
}
