import Foundation
import Security

/// What the running app's code signature, entitlements and Info.plist let
/// Chromium do, so an app can adapt its UI (for example, hide a hint about
/// a feature its signature leaves out).
///
/// `swift package cef doctor <App.app>` reports the same for a bundle on
/// disk; docs/bundling.md lists what each feature needs.
public struct CefAppCapabilities: Sendable, Equatable {
    /// What kind of certificate signs the app.
    public enum SignatureKind: String, Sendable, Equatable {
        case unsigned
        /// No certificate and no team, as local `cef bundle` builds are.
        case adHoc
        /// Apple Development (or Mac Developer).
        case development
        /// Developer ID Application.
        case developerID
        /// Apple Distribution, for the Mac App Store.
        ///
        /// Diagnostic only: the Mac App Store requires the App Sandbox,
        /// which official CEF builds do not support, and bundling refuses
        /// it (docs/bundling.md, "App Sandbox").
        case appStore
        /// A certificate Apple did not issue to a team, such as a
        /// self-signed one.
        case other

        /// Whether Apple issued the certificate to a team.
        public var hasAppleTeam: Bool {
            self == .development || self == .developerID || self == .appStore
        }
    }

    public let signature: SignatureKind
    /// The signature's team identifier; nil when unsigned, ad hoc or
    /// self-signed.
    public let teamIdentifier: String?
    public let isHardenedRuntime: Bool
    /// Whether the app runs in the App Sandbox
    /// (`com.apple.security.app-sandbox`).
    ///
    /// Diagnostic only: official CEF builds do not run in the App Sandbox
    /// (Chromium registers a Mach service the App Sandbox refuses), and
    /// `cef bundle` and the Xcode build phase refuse it for every
    /// signature, so a bundled app reports `false`.
    public let isAppSandboxed: Bool
    /// The entitlement keys the signature grants (a key whose value is
    /// `false` is left out).
    public let entitlements: Set<String>
    /// The keychain access groups the app may use.
    public let keychainAccessGroups: [String]
    /// The `NS…UsageDescription` keys in the app's Info.plist.
    public let usageDescriptions: Set<String>
    /// Whether the helper that runs Chromium's content decryption module
    /// (`<App> Helper.app`) can load Google's Widevine CDM. Under the
    /// hardened runtime, library validation refuses a library signed by
    /// another team, so a team-signed helper needs
    /// `com.apple.security.cs.disable-library-validation` (the
    /// `protectedMedia` capability in `cefapp.json`). Whether Chromium has
    /// downloaded the CDM is ``CefRuntime/widevine``.
    public let canLoadWidevine: Bool

    /// Creates a value of your own, for previews and tests.
    public init(
        signature: SignatureKind,
        teamIdentifier: String? = nil,
        isHardenedRuntime: Bool = false,
        isAppSandboxed: Bool = false,
        entitlements: Set<String> = [],
        keychainAccessGroups: [String] = [],
        usageDescriptions: Set<String> = [],
        canLoadWidevine: Bool = false
    ) {
        self.signature = signature
        self.teamIdentifier = teamIdentifier
        self.isHardenedRuntime = isHardenedRuntime
        self.isAppSandboxed = isAppSandboxed
        self.entitlements = entitlements
        self.keychainAccessGroups = keychainAccessGroups
        self.usageDescriptions = usageDescriptions
        self.canLoadWidevine = canLoadWidevine
    }

    /// The running app's capabilities.
    public static let current = CefAppCapabilities(
        signingInformation: Self.signingInformationOfSelf(),
        infoDictionary: Bundle.main.infoDictionary ?? [:],
        baseHelperSigningInformation: Self.signingInformationOfBaseHelper())

    /// Evaluates a code signature's information, as
    /// `SecCodeCopySigningInformation` returns it, and an Info.plist.
    /// `baseHelperSigningInformation` is the base helper's; the app's
    /// stands in for it when nil.
    init(signingInformation info: [String: Any]?, infoDictionary: [String: Any],
         baseHelperSigningInformation helperInfo: [String: Any]? = nil) {
        let flags = (info?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info?[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let team = info?[kSecCodeInfoTeamIdentifier as String] as? String
        let leafName = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }

        if info?[kSecCodeInfoIdentifier as String] == nil {
            signature = .unsigned
        } else if flags & 0x2 != 0 {  // kSecCodeSignatureAdhoc
            signature = .adHoc
        } else {
            signature = Self.kind(certificateName: leafName ?? "")
        }
        teamIdentifier = signature.hasAppleTeam ? team : nil
        isHardenedRuntime = flags & 0x10000 != 0  // kSecCodeSignatureRuntime

        let entitlementValues = info?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        entitlements = Set(entitlementValues.compactMap { key, value in
            (value as? Bool) == false ? nil : key
        })
        keychainAccessGroups = entitlementValues["keychain-access-groups"] as? [String] ?? []
        isAppSandboxed = (entitlementValues["com.apple.security.app-sandbox"] as? Bool) == true
        usageDescriptions = Set(infoDictionary.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") })

        let helper = helperInfo ?? info
        let helperFlags = (helper?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let helperEntitlements = helper?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let helperHasTeam = helper?[kSecCodeInfoTeamIdentifier as String] != nil && helperFlags & 0x2 == 0
        let validatesLibraries = helperFlags & 0x10000 != 0
            && (helperEntitlements["com.apple.security.cs.disable-library-validation"] as? Bool) != true
        canLoadWidevine = !(validatesLibraries && helperHasTeam)
    }

    /// Whether ``CefRuntime/SafeStoragePolicy/automatic`` uses the keychain: only
    /// with a team signature, whose "Always Allow" grant survives rebuilds.
    public var usesKeychainAutomatically: Bool { teamIdentifier != nil }

    /// The safe-storage policy Chromium gets for `policy`.
    public func resolvedSafeStorage(_ policy: CefRuntime.SafeStoragePolicy) -> CefRuntime.SafeStoragePolicy {
        switch policy {
        case .keychain, .mockKeychain: return policy
        case .automatic: return usesKeychainAutomatically ? .keychain : .mockKeychain
        }
    }

    /// One line for the log naming what is unavailable because of how the
    /// app is signed, or nil when nothing is.
    func limitationsSummary() -> String? {
        var parts: [String] = []
        let signed = "signed \(signature == .adHoc ? "ad hoc" : signature.rawValue)" +
            (teamIdentifier.map { ", team \($0)" } ?? ", no team")
        if teamIdentifier == nil {
            parts.append("safe storage uses a mock keychain")
        }
        guard !parts.isEmpty else { return nil }
        return "CefSwift: \(signed): " + parts.joined(separator: "; ") + ". See docs/bundling.md#features."
    }

    static func kind(certificateName name: String) -> SignatureKind {
        if name.hasPrefix("Apple Development:") || name.hasPrefix("Mac Developer:") { return .development }
        if name.hasPrefix("Developer ID Application:") { return .developerID }
        if name.hasPrefix("Apple Distribution:") || name.hasPrefix("3rd Party Mac Developer Application:") {
            return .appStore
        }
        return .other
    }

    /// The signing information of `Contents/Frameworks/<App> Helper.app`.
    private static func signingInformationOfBaseHelper() -> [String: Any]? {
        guard let executable = Bundle.main.executableURL?.lastPathComponent else { return nil }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/\(executable) Helper.app", isDirectory: true)
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard FileManager.default.fileExists(atPath: helper.path),
              SecStaticCodeCreateWithPath(helper as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess
        else { return nil }
        return information as? [String: Any]
    }

    private static func signingInformationOfSelf() -> [String: Any]? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess
        else { return nil }
        return information as? [String: Any]
    }
}

extension CefRuntime {
    /// What the app's signature, entitlements and Info.plist let Chromium
    /// do. The same as ``CefAppCapabilities/current``.
    public nonisolated var capabilities: CefAppCapabilities { .current }
}
