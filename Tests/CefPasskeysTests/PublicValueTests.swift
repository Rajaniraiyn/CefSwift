import CefPasskeys
import Testing

/// An app's tests can make CefPasskeys' plain values without `@testable`.
struct PublicPasskeyValueTests {
    @Test func storeError() {
        let error = CefPasskeyStoreError(operation: .read, origin: "https://example.com", message: "locked")
        #expect(error.passkey == nil)
        #expect(error.description == "passkey store read failed for https://example.com: locked")
    }
}
