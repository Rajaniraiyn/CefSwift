import Foundation

/// A passkey kept by the app: a WebAuthn discoverable credential for one
/// site and one account, with its private key.
///
/// Passkeys of this kind belong to a ``CefPasskeyStore`` and are used by a
/// ``CefPasskeyController`` whose policy is ``CefPasskeyController/Policy/app(_:)``.
/// They are software keys (ECDSA P-256): the app holds the private key, and
/// Chromium holds a copy only while it answers one request.
public struct CefPasskey: Sendable, Hashable, Identifiable, Codable {
    /// The credential ID, as the site sees it in `PublicKeyCredential.rawId`.
    public var id: Data
    /// The relying party: the domain the passkey signs in to, such as
    /// `example.com`. Pages on that domain and its subdomains may use it.
    public var relyingPartyID: String
    /// The site's identifier for the account (`user.id` at registration).
    public var userHandle: Data
    /// The account name the site gave at registration, such as an email
    /// address.
    public var userName: String
    /// The account's display name the site gave at registration.
    public var userDisplayName: String
    /// The private key in PKCS #8 DER form. Treat it as a secret: anyone
    /// holding it can sign in as this account.
    public var privateKey: Data
    /// How many times the passkey has signed; sites use it to detect cloned
    /// keys.
    public var signCount: UInt32
    /// When the passkey was created.
    public var creationDate: Date
    /// When the passkey last signed in, if it has.
    public var lastUsedDate: Date?

    public init(
        id: Data, relyingPartyID: String, userHandle: Data, userName: String, userDisplayName: String = "",
        privateKey: Data, signCount: UInt32 = 0, creationDate: Date = .now, lastUsedDate: Date? = nil
    ) {
        self.id = id
        self.relyingPartyID = relyingPartyID
        self.userHandle = userHandle
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.privateKey = privateKey
        self.signCount = signCount
        self.creationDate = creationDate
        self.lastUsedDate = lastUsedDate
    }

    /// Whether a page on `host` may use this passkey: the host is the
    /// relying party's domain or one of its subdomains.
    public func isUsable(onHost host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let party = relyingPartyID.lowercased()
        guard !party.isEmpty else { return false }
        return host == party || host.hasSuffix("." + party)
    }
}

/// A WebAuthn request a page made with `navigator.credentials.create()` or
/// `navigator.credentials.get()`, delivered to
/// ``CefPasskeyDelegate/browser(_:decidePasskeyFor:)``.
public struct CefPasskeyRequest: Sendable, Equatable {
    /// What the page asks for.
    public enum Kind: Sendable, Equatable {
        /// `navigator.credentials.create()`: make a passkey for an account.
        case registration
        /// `navigator.credentials.get()`: sign in with a passkey.
        case assertion
    }

    /// Whether the page registers a passkey or signs in with one.
    public var kind: Kind
    /// The origin of the document that called, such as
    /// `https://login.example.com`. Chromium reports it; a page cannot forge
    /// it. It is a subframe's origin when ``isMainFrame`` is `false`.
    public var origin: String
    /// Whether the main frame made the request.
    public var isMainFrame: Bool
    /// Whether the call happened while the page had a user gesture, such as
    /// right after a click. A page that waits for the user with conditional
    /// mediation (passkeys offered in an address-field autofill list) calls
    /// without one, usually as it loads.
    public var hasUserGesture: Bool
    /// For an assertion, the store's passkeys that a page on this origin
    /// may use, most recently used first. Empty for a registration.
    public var passkeys: [CefPasskey]

    /// The host of ``origin``, such as `login.example.com`, for display.
    public var host: String { URL(string: origin)?.host() ?? origin }

    public init(kind: Kind, origin: String, isMainFrame: Bool = true, hasUserGesture: Bool = true, passkeys: [CefPasskey] = []) {
        self.kind = kind
        self.origin = origin
        self.isMainFrame = isMainFrame
        self.hasUserGesture = hasUserGesture
        self.passkeys = passkeys
    }
}

/// The answer to a ``CefPasskeyRequest``.
///
/// Answering ``createPasskey`` or ``signIn(with:)`` tells the site that the
/// user was verified (the WebAuthn UV flag). Verify the user first, for
/// example with `LAContext`, as ``CefPasskeyPresenter`` does.
public enum CefPasskeyDecision: Sendable, Equatable {
    /// For a registration: create a passkey and save it to the store.
    case createPasskey
    /// For an assertion: sign in with this passkey.
    case signIn(with: CefPasskey)
    /// Refuse. The page's promise rejects with `NotAllowedError`.
    case deny
    /// Leave the request unanswered, as Safari and Chrome leave a
    /// conditional request until the user picks a passkey. It ends when the
    /// page aborts it, navigates, or its timeout passes.
    case ignore
}

/// A ``CefPasskeyStore`` call that failed while a ``CefPasskeyController``
/// answered a WebAuthn request, delivered to
/// ``CefPasskeyDelegate/browser(_:passkeyStoreDidFail:)``.
public struct CefPasskeyStoreError: Error, Sendable, CustomStringConvertible {
    /// What the controller asked the store to do.
    public enum Operation: Sendable, Equatable {
        /// ``CefPasskeyStore/checkAvailability()`` before a registration.
        /// The page's call was refused with `NotAllowedError`.
        case checkAvailability
        /// Reading the passkeys for an assertion. The page's call was
        /// refused with `NotAllowedError`.
        case read
        /// Saving the passkey a registration created, or the new sign count
        /// after a sign-in. The page already has its answer; ``passkey``
        /// holds what was not saved, so the app can keep it another way or
        /// tell the user.
        case save
    }

    /// What failed.
    public var operation: Operation
    /// The request's origin.
    public var origin: String
    /// The passkey that was not saved, for ``Operation/save``.
    public var passkey: CefPasskey?
    /// The store's error, described.
    public var message: String

    public var description: String {
        "passkey store \(operation) failed for \(origin): \(message)"
    }
}

// MARK: - Base64

extension Data {
    /// Base64url without padding, as WebAuthn encodes binary values.
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes standard base64 or base64url, with or without padding.
    init?(base64OrBase64URL string: String) {
        var text = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: text)
    }
}
