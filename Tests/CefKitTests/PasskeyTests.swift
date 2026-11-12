import Foundation
import Testing

@testable import CefKit

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
}
