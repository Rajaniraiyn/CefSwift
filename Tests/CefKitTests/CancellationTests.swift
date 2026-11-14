import CCef
import Foundation
import Testing

@testable import CefBase
@testable import CefKit

/// `CefResumeOnce.cancellable`, which every Chromium completion callback
/// behind a public `async` call waits through.
@MainActor
struct CancellationTests {
    /// A stand-in for a CEF callback object holding the box.
    final class Callback: Sendable {
        let once: CefResumeOnce<Int>
        init(_ once: CefResumeOnce<Int>) { self.once = once }
    }

    @Test func returnsTheCompletion() async throws {
        var kept: Callback?
        let value = try await CefResumeOnce<Int>.cancellable(fallback: -1) { once in
            kept = Callback(once)
            DispatchQueue.global().async { [kept] in kept?.once.resume(returning: 7) }
        }
        #expect(value == 7)
        _ = kept
    }

    @Test func cancellationThrowsAtOnceAndDropsALateCompletion() async {
        let holder = Holder()
        let task = Task { @MainActor in
            try await CefResumeOnce<Int>.cancellable(fallback: -1) { holder.callback = Callback($0) }
        }
        while holder.callback == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Chromium completes later: dropped, and reported as such.
        #expect(holder.callback?.once.resume(returning: 3) == false)
        #expect(holder.callback?.once.isFinished == true)
    }

    @Test func anAlreadyCancelledTaskNeverStarts() async {
        let holder = Holder()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CefResumeOnce<Int>.cancellable(fallback: -1) { holder.callback = Callback($0) }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(holder.callback == nil)
    }

    @Test func aDroppedCallbackResumesWithTheFallback() async throws {
        // CEF released the callback without calling it.
        let value = try await CefResumeOnce<Int>.cancellable(fallback: -1) { once in
            _ = Callback(once)
        }
        #expect(value == -1)
    }

    @MainActor final class Holder {
        var callback: Callback?
    }

    // MARK: Cookies

    @Test func cookiesKeepEverythingCEFStores() {
        let expires = Date(timeIntervalSince1970: 1_900_000_000)
        let cookie = CefProfile.Cookie(
            name: "n", value: "v", domain: ".example.com", path: "/a", isSecure: true, isHTTPOnly: true,
            expirationDate: expires, sameSite: .strict, priority: .low)
        var raw = cookie.makeRaw()
        defer { raw.clear() }
        let back = CefProfile.Cookie(raw: raw)
        #expect(back == cookie)
        #expect(raw.same_site == CEF_COOKIE_SAME_SITE_STRICT_MODE && raw.priority == CEF_COOKIE_PRIORITY_LOW)

        let session = CefProfile.Cookie(name: "s", value: "1", domain: "www.example.com")
        var sessionRaw = session.makeRaw()
        defer { sessionRaw.clear() }
        #expect(sessionRaw.has_expires == 0 && CefProfile.Cookie(raw: sessionRaw).expirationDate == nil)
    }

    /// Each profile has a media router of its own.
    @Test func eachProfileHasItsOwnMediaRouter() {
        let incognito = CefProfile.incognito()
        #expect(incognito.mediaRouter === incognito.mediaRouter)
        #expect(incognito.mediaRouter !== CefProfile.incognito().mediaRouter)
        #expect(!incognito.mediaRouter.isAvailable)  // Chromium is not running.
    }

    @Test func aCookieIsSetForTheURLItsDomainMakes() {
        #expect(CefProfile.Cookie(name: "a", value: "1", domain: ".example.com", isSecure: true).defaultURL?.absoluteString
            == "https://example.com/")
        #expect(CefProfile.Cookie(name: "a", value: "1", domain: "host.test", path: "/p").defaultURL?.absoluteString
            == "http://host.test/p")
        #expect(CefProfile.Cookie(name: "a", value: "1").defaultURL == nil)
    }
}
