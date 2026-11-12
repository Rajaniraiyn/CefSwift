import CCef
import CefBase

/// A `cef_registration_t` kept alive for as long as something observes
/// through it, such as a stream of preference or site-setting changes.
///
/// Chromium keeps an observer registered until its registration object is
/// destroyed, and the registration must go before the request context it
/// belongs to; ``releaseAll()`` lets every one go before Chromium shuts
/// down.
@MainActor
final class CefObserverRegistration {
    private static var live: [ObjectIdentifier: CefObserverRegistration] = [:]

    private var registration: CefRef<cef_registration_t>?
    private var finish: (() -> Void)?

    /// Keeps `registration`, a +1 reference, until ``cancel()``.
    init?(adopting registration: UnsafeMutablePointer<cef_registration_t>?) {
        guard let registration else { return nil }
        self.registration = CefRef(adopting: registration)
        Self.live[ObjectIdentifier(self)] = self
    }

    /// Ends the observation. Safe to call more than once.
    func cancel() {
        registration = nil
        finish = nil
        Self.live[ObjectIdentifier(self)] = nil
    }

    /// Whether the observation is still registered.
    var isActive: Bool { registration != nil }

    /// Ends every observation, before Chromium shuts down.
    static func releaseAll() {
        let all = live.values
        live = [:]
        for registration in all {
            registration.registration = nil
            registration.finish?()
            registration.finish = nil
        }
    }

    /// The number of observations registered, for tests.
    static var liveCount: Int { live.count }

    /// Ties `registration` to `continuation`: when the stream's consumer
    /// stops iterating, the observation ends on the main actor.
    func end<Element>(with continuation: AsyncStream<Element>.Continuation) {
        finish = { continuation.finish() }
        continuation.onTermination = { [self] _ in
            Task { @MainActor in self.cancel() }
        }
    }
}
