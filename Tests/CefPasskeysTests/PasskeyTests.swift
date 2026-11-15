import Foundation
import LocalAuthentication
import Testing

@testable import CefKit
@testable import CefPasskeys

/// Passkey model, encodings and the in-memory store.
@MainActor
struct PasskeyTests {
    static let sample = CefPasskey(
        id: Data([0xFB, 0xFF, 0x01, 0x02]), relyingPartyID: "example.com", userHandle: Data([1, 2, 3, 4]),
        userName: "ada@example.com", userDisplayName: "Ada", privateKey: Data(repeating: 7, count: 138), signCount: 3,
        creationDate: Date(timeIntervalSince1970: 1_000))

    @Test func usableOnTheRelyingPartyAndItsSubdomains() {
        let passkey = Self.sample
        #expect(passkey.isUsable(onHost: "example.com"))
        #expect(passkey.isUsable(onHost: "login.example.com"))
        #expect(passkey.isUsable(onHost: "LOGIN.Example.COM."))
        #expect(!passkey.isUsable(onHost: "badexample.com"))
        #expect(!passkey.isUsable(onHost: "example.com.evil.test"))
        #expect(!passkey.isUsable(onHost: "com"))
        var empty = passkey
        empty.relyingPartyID = ""
        #expect(!empty.isUsable(onHost: "example.com"))
    }

    @Test func base64URLRoundTrip() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00, 0x10])
        #expect(data.base64URLEncodedString == "-_-_ABA")
        #expect(Data(base64OrBase64URL: "-_-_ABA") == data)
        #expect(Data(base64OrBase64URL: "+/+/ABA=") == data)
        #expect(Data(base64OrBase64URL: "A") == nil)
    }

    @Test func devToolsCredentialRoundTrip() throws {
        let passkey = Self.sample
        let json = passkey.devToolsCredential
        // The WebAuthn domain encodes binary fields as standard base64.
        #expect(json["credentialId"].stringValue == "+/8BAg==")
        #expect(json["isResidentCredential"].boolValue == true)
        let decoded = try #require(CefPasskey(devToolsCredential: json))
        #expect(decoded.id == passkey.id)
        #expect(decoded.relyingPartyID == passkey.relyingPartyID)
        #expect(decoded.userHandle == passkey.userHandle)
        #expect(decoded.userName == passkey.userName)
        #expect(decoded.userDisplayName == passkey.userDisplayName)
        #expect(decoded.privateKey == passkey.privateKey)
        #expect(decoded.signCount == 3)
    }

    @Test func devToolsCredentialNeedsIDPartyAndKey() {
        #expect(CefPasskey(devToolsCredential: ["rpId": "example.com", "privateKey": "AAAA"]) == nil)
        #expect(CefPasskey(devToolsCredential: ["credentialId": "AAAA", "privateKey": "AAAA"]) == nil)
        #expect(CefPasskey(devToolsCredential: ["credentialId": "AAAA", "rpId": "example.com"]) == nil)
    }

    @Test func passkeyIsCodable() throws {
        let data = try JSONEncoder().encode(Self.sample)
        #expect(try JSONDecoder().decode(CefPasskey.self, from: data) == Self.sample)
    }

    @Test func inMemoryStoreSavesReplacesAndRemoves() async throws {
        let store = CefInMemoryPasskeyStore()
        var passkey = Self.sample
        try await store.save(passkey)
        passkey.signCount = 9
        try await store.save(passkey)
        #expect(try await store.passkeys().map(\.signCount) == [9])
        try await store.remove(passkey)
        #expect(try await store.passkeys().isEmpty)
    }

    @Test func usablePasskeysAreFilteredAndMostRecentFirst() async throws {
        var older = Self.sample
        var newer = Self.sample
        newer.id = Data([9])
        newer.lastUsedDate = Date(timeIntervalSince1970: 5_000)
        older.lastUsedDate = Date(timeIntervalSince1970: 2_000)
        var other = Self.sample
        other.id = Data([8])
        other.relyingPartyID = "other.test"
        let store = CefInMemoryPasskeyStore(passkeys: [older, other, newer])
        #expect(try await store.passkeys(usableOnHost: "www.example.com").map(\.id) == [newer.id, older.id])
    }

    @Test func requestHostComesFromTheOrigin() {
        #expect(CefPasskeyRequest(kind: .assertion, origin: "https://login.example.com").host == "login.example.com")
        #expect(CefPasskeyRequest(kind: .registration, origin: "http://localhost:8080").host == "localhost")
    }

    // MARK: Failing closed

    @Test func cancellingVerificationEndsTheSystemPrompt() async {
        let context = FakeAuthenticationContext(waitsForInvalidation: true)
        let verification = Task { await CefPasskeyPresenter.verifyUser(reason: "test", with: context) }
        while context.evaluated == 0 { await Task.yield() }
        verification.cancel()
        #expect(await verification.value == .failed)
        #expect(context.invalidated)
    }

    @Test func unavailableVerificationIsNotSuccess() async {
        let none = FakeAuthenticationContext(canEvaluate: false)
        #expect(await CefPasskeyPresenter.verifyUser(reason: "test", with: none) == .unavailable("no biometry"))
        #expect(none.evaluated == 0)
        #expect(await CefPasskeyPresenter.verifyUser(reason: "test", with: FakeAuthenticationContext(result: .success(true))) == .verified)
        #expect(await CefPasskeyPresenter.verifyUser(reason: "test", with: FakeAuthenticationContext(result: .success(false))) == .failed)
        #expect(await CefPasskeyPresenter.verifyUser(
            reason: "test", with: FakeAuthenticationContext(result: .failure(CefError.operationFailed("cancelled")))) == .failed)
    }

    @Test func thePresenterAnswersOnlyAVerifiedUser() {
        let registration = CefPasskeyRequest(kind: .registration, origin: "https://example.com")
        let assertion = CefPasskeyRequest(kind: .assertion, origin: "https://example.com", passkeys: [Self.sample])
        for verification in [CefUserVerification.failed, .unavailable("none")] {
            #expect(CefPasskeyPresenter.decision(for: registration, choosing: 0, after: verification) == .deny)
            #expect(CefPasskeyPresenter.decision(for: assertion, choosing: 0, after: verification) == .deny)
        }
        #expect(CefPasskeyPresenter.decision(for: registration, choosing: 0, after: .verified) == .createPasskey)
        #expect(CefPasskeyPresenter.decision(for: assertion, choosing: 0, after: .verified) == .signIn(with: Self.sample))
        #expect(CefPasskeyPresenter.decision(for: assertion, choosing: 3, after: .verified) == .deny)
    }

    @Test func anUnavailableStoreRefusesARegistrationUnasked() async {
        let request = CefPasskeyRequest(kind: .registration, origin: "https://example.com")
        var asked = false
        var failures: [CefPasskeyStoreError] = []
        let decision = await CefPasskeySession.decide(request, policy: .app(FailingPasskeyStore())) { _ in
            asked = true
            return .createPasskey
        } failed: { failures.append($0) }
        #expect(decision == .deny)
        #expect(!asked)
        #expect(failures.map(\.operation) == [.checkAvailability])
    }

    @Test func anUnreadableStoreRefusesAnAssertion() async {
        let request = CefPasskeyRequest(kind: .assertion, origin: "https://example.com")
        var failures: [CefPasskeyStoreError] = []
        let decision = await CefPasskeySession.decide(request, policy: .app(FailingPasskeyStore())) { _ in
            .signIn(with: Self.sample)
        } failed: { failures.append($0) }
        #expect(decision == .deny)
        #expect(failures.map(\.operation) == [.read])
    }

    @Test func aWorkingStoreReachesTheDelegateWithItsPasskeys() async {
        let request = CefPasskeyRequest(kind: .assertion, origin: "https://www.example.com")
        var seen: [CefPasskey] = []
        let decision = await CefPasskeySession.decide(
            request, policy: .app(CefInMemoryPasskeyStore(passkeys: [Self.sample]))
        ) { request in
            seen = request.passkeys
            return .signIn(with: request.passkeys[0])
        } failed: { _ in Issue.record("no failure expected") }
        #expect(decision == .signIn(with: Self.sample))
        #expect(seen == [Self.sample])
        #expect(await CefPasskeySession.decide(request, policy: .disabled) { _ in .createPasskey } failed: { _ in } == .deny)
    }
}

/// A store whose every call fails, as a keychain without its entitlement does.
@MainActor
final class FailingPasskeyStore: CefPasskeyStore {
    func passkeys() async throws -> [CefPasskey] { throw CefError.operationFailed("errSecMissingEntitlement") }
    func save(_ passkey: CefPasskey) async throws { throw CefError.operationFailed("errSecMissingEntitlement") }
    func remove(_ passkey: CefPasskey) async throws { throw CefError.operationFailed("errSecMissingEntitlement") }
}

/// `LAContext` without the system prompt.
final class FakeAuthenticationContext: CefLocalAuthenticationContext, @unchecked Sendable {
    let canEvaluate: Bool
    let result: Result<Bool, any Error>
    /// Whether an evaluation lasts until `invalidate()`, as a system prompt
    /// the user leaves open does.
    let waitsForInvalidation: Bool
    private let lock = NSLock()
    private var evaluations = 0
    private var wasInvalidated = false
    var evaluated: Int { lock.withLock { evaluations } }
    var invalidated: Bool { lock.withLock { wasInvalidated } }

    init(canEvaluate: Bool = true, result: Result<Bool, any Error> = .success(true), waitsForInvalidation: Bool = false) {
        self.canEvaluate = canEvaluate
        self.result = result
        self.waitsForInvalidation = waitsForInvalidation
    }

    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        if !canEvaluate {
            error?.pointee = NSError(domain: "test", code: -7, userInfo: [NSLocalizedDescriptionKey: "no biometry"])
        }
        return canEvaluate
    }

    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        lock.withLock { evaluations += 1 }
        if waitsForInvalidation {
            // Not cancellation: only `invalidate()` ends the prompt.
            while !invalidated { try? await Task.sleep(for: .milliseconds(5)) }
            throw LAError(.appCancel)
        }
        return try result.get()
    }

    func invalidate() {
        lock.withLock { wasInvalidated = true }
    }
}

@Suite struct PasskeySheetStringTests {
    @Test func stringsComeFromTheResourceBundle() {
        #expect(Bundle.cefPasskeys.bundleURL.lastPathComponent == "CefSwift_CefPasskeys.bundle")
        #expect(Bundle.cefPasskeys.localizedString(forKey: "Choose an account.", value: "missing", table: nil) == "Choose an account.")
        let host = "example.com"
        #expect(String(localized: "Save a passkey for “\(host)”?", bundle: .cefPasskeys) == "Save a passkey for “example.com”?")
    }
}
