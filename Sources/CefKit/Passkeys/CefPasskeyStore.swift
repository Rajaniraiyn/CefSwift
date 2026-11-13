import Foundation
import Security

/// Where an app keeps the passkeys it answers WebAuthn requests with.
///
/// Pass a store to ``CefBrowser/PasskeyPolicy/app(_:)``. CefKit reads it when a page
/// asks to sign in, saves a passkey after a registration, and saves it
/// again after each sign-in with its new ``CefPasskey/signCount``. List and
/// remove passkeys through the store itself, for example in a settings
/// screen.
///
/// Two stores come with CefKit: ``CefInMemoryPasskeyStore`` and
/// ``CefKeychainPasskeyStore``. Adopt the protocol to keep passkeys
/// elsewhere, such as in a password manager.
@MainActor
public protocol CefPasskeyStore: AnyObject {
    /// Every passkey in the store.
    func passkeys() async throws -> [CefPasskey]
    /// Adds `passkey`, or replaces the one with the same ``CefPasskey/id``.
    func save(_ passkey: CefPasskey) async throws
    /// Removes `passkey`. Removing one that is not stored does nothing.
    func remove(_ passkey: CefPasskey) async throws
    /// Throws if the store cannot save a passkey now. CefKit calls it
    /// before it asks the delegate about a registration, and refuses the
    /// registration when it throws: once the page has its new credential,
    /// a failed save cannot be taken back. The default reads
    /// ``passkeys()``.
    func checkAvailability() async throws
}

extension CefPasskeyStore {
    public func checkAvailability() async throws {
        _ = try await passkeys()
    }

    /// The passkeys a page on `host` may use, most recently used first.
    public func passkeys(usableOnHost host: String) async throws -> [CefPasskey] {
        try await passkeys()
            .filter { $0.isUsable(onHost: host) }
            .sorted { ($0.lastUsedDate ?? $0.creationDate) > ($1.lastUsedDate ?? $1.creationDate) }
    }
}

/// Passkeys kept in memory and lost when the store is released. For tests,
/// previews and private browsing.
@MainActor
public final class CefInMemoryPasskeyStore: CefPasskeyStore {
    private var stored: [CefPasskey] = []

    public init(passkeys: [CefPasskey] = []) {
        stored = passkeys
    }

    public func passkeys() async throws -> [CefPasskey] { stored }

    public func save(_ passkey: CefPasskey) async throws {
        if let index = stored.firstIndex(where: { $0.id == passkey.id }) {
            stored[index] = passkey
        } else {
            stored.append(passkey)
        }
    }

    public func remove(_ passkey: CefPasskey) async throws {
        stored.removeAll { $0.id == passkey.id }
    }
}

/// Passkeys kept in the data protection keychain, one generic-password item
/// per passkey, readable only while the Mac is unlocked and never synced
/// or migrated to another device.
///
/// The data protection keychain needs an app signed with a team identity
/// (Apple Development or Developer ID) and, for a sandboxed app, a
/// keychain access group; an unsigned or ad hoc signed app gets
/// `errSecMissingEntitlement` (-34018) from every call, which this store
/// throws as ``CefError/operationFailed(_:)``. It never uses the file-based
/// login keychain, so it never shows a keychain password prompt.
@MainActor
public final class CefKeychainPasskeyStore: CefPasskeyStore {
    /// The keychain service name the items are filed under.
    public let service: String
    /// The keychain access group, or `nil` for the app's default group.
    public let accessGroup: String?

    /// - Parameters:
    ///   - service: The service name for the items. Defaults to
    ///     `<bundle identifier>.passkeys`.
    ///   - accessGroup: A keychain access group shared with other apps or
    ///     extensions, if any.
    public init(service: String? = nil, accessGroup: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "CefSwift").passkeys"
        self.accessGroup = accessGroup
    }

    public func passkeys() async throws -> [CefPasskey] {
        var query = baseQuery()
        query[kSecMatchLimit] = kSecMatchLimitAll
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "read passkeys")
        let items = (result as? [Data]) ?? []
        let decoder = JSONDecoder()
        return items.compactMap { try? decoder.decode(CefPasskey.self, from: $0) }
    }

    public func save(_ passkey: CefPasskey) async throws {
        let data = try JSONEncoder().encode(passkey)
        var query = baseQuery()
        query[kSecAttrAccount] = passkey.id.base64URLEncodedString
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrLabel: "\(passkey.relyingPartyID) (\(passkey.userName))"]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(update) { $1 }
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecAttrSynchronizable] = false
            try check(SecItemAdd(query as CFDictionary, nil), "save a passkey")
        } else {
            try check(status, "save a passkey")
        }
    }

    public func remove(_ passkey: CefPasskey) async throws {
        var query = baseQuery()
        query[kSecAttrAccount] = passkey.id.base64URLEncodedString
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, "remove a passkey") }
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw CefError.operationFailed("Could not \(action): \(message)")
    }
}
