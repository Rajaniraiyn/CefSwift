import Foundation

/// What `cef doctor` reads from a built bundle. Collected by
/// `DoctorInspector` with `codesign`, `security`, `spctl`, `stapler` and
/// `xattr`; evaluated here.
struct BundleFacts: Sendable {
    /// One signed item: the app, a helper, the framework or a library.
    struct Part: Sendable {
        var name: String
        var path: String
        var isSigned: Bool = true
        var kind: SignatureKind = .unsigned
        var authority: String?
        var teamIdentifier: String?
        var isHardenedRuntime = false
        var hasSecureTimestamp = false
        var entitlements: PlistDictionary = [:]
        var infoPlist: PlistDictionary = [:]
    }

    var app: Part
    var helpers: [HelperKind: Part] = [:]
    /// The framework, its libraries, the helpers' startup library, and the
    /// app's own libraries, frameworks and signed resource bundles.
    var libraries: [Part] = []
    /// The app's own libraries and frameworks in `Contents/Frameworks`.
    var appLibraries: [String] = []
    /// SwiftPM resource bundles in `Contents/Resources`.
    var resourceBundles: [String] = []
    /// The main executable's architectures.
    var architectures: [String] = []
    /// What `Linkage.problems` finds: code that lacks the app's
    /// architectures, or loads or searches for libraries outside the bundle.
    var linkageProblems: [String] = []
    /// `codesign --verify --strict` on the app, nested code included.
    var verifyError: String?
    var profile: ProvisioningProfile?
    var profileError: String?
    /// `spctl --assess --type execute`: nil when it could not run.
    var gatekeeperAccepted: Bool?
    var gatekeeperOutput: String = ""
    /// `stapler validate`: nil when it could not run.
    var isStapled: Bool?
    var isQuarantined = false
    var footprint: Footprint?

    /// What the bundle's parts weigh, in logical bytes.
    struct Footprint: Sendable {
        var appBytes: Int64 = 0
        var frameworkBinaryBytes: Int64 = 0
        var frameworkResourcesBytes: Int64 = 0
        /// Each locale pack with its gender variants.
        var localePacks: [String: Int64] = [:]
        /// SwiftShader's files; nil when they are left out.
        var softwareGPUBytes: Int64?
        var helperBytes: Int64 = 0
        var appLocalizations: [String] = []
        var developmentLanguage = "en"
    }
}

struct DoctorReport: Encodable, Sendable {
    enum Status: String, Encodable, Sendable, Comparable {
        case ok, info, warning, error

        private var rank: Int { [.ok: 0, .info: 1, .warning: 2, .error: 3][self] ?? 0 }
        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rank < rhs.rank }

        var symbol: String {
            switch self {
            case .ok: return "ok  "
            case .info: return "--  "
            case .warning: return "warn"
            case .error: return "FAIL"
            }
        }
    }

    struct Check: Encodable, Sendable {
        var status: Status
        var title: String
        var detail: String
        var fix: String?
    }

    struct Section: Encodable, Sendable {
        var name: String
        var checks: [Check]
    }

    var app: String
    var bundleIdentifier: String
    var signature: String
    var teamIdentifier: String?
    var keychainPolicy: String
    var passkeyAuthenticators: [String]
    var sections: [Section]

    var errorCount: Int { sections.flatMap(\.checks).filter { $0.status == .error }.count }
    var warningCount: Int { sections.flatMap(\.checks).filter { $0.status == .warning }.count }

    private enum CodingKeys: String, CodingKey {
        case app, bundleIdentifier, signature, teamIdentifier, keychainPolicy, passkeyAuthenticators,
             sections, errors, warnings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(app, forKey: .app)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(signature, forKey: .signature)
        try container.encodeIfPresent(teamIdentifier, forKey: .teamIdentifier)
        try container.encode(keychainPolicy, forKey: .keychainPolicy)
        try container.encode(passkeyAuthenticators, forKey: .passkeyAuthenticators)
        try container.encode(sections, forKey: .sections)
        try container.encode(errorCount, forKey: .errors)
        try container.encode(warningCount, forKey: .warnings)
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func text() -> String {
        var lines = [
            "\(app) (\(bundleIdentifier))",
            "  signature:      \(signature)" + (teamIdentifier.map { ", team \($0)" } ?? ""),
            "  safe storage:   \(keychainPolicy)",
            "  passkeys:       \(passkeyAuthenticators.joined(separator: ", "))",
        ]
        for section in sections {
            lines.append("")
            lines.append(section.name)
            for check in section.checks {
                lines.append("  [\(check.status.symbol)] \(check.title): \(check.detail)")
                if let fix = check.fix { lines.append("         fix: \(fix)") }
            }
        }
        lines.append("")
        lines.append("\(errorCount) error(s), \(warningCount) warning(s).")
        return lines.joined(separator: "\n")
    }
}

enum Doctor {
    static func evaluate(_ facts: BundleFacts, now: Date = Date()) -> DoctorReport {
        let app = facts.app
        let team = app.teamIdentifier
        let runtime = app.isHardenedRuntime
        let info = app.infoPlist
        let entitlements = app.entitlements
        let bundleID = info["CFBundleIdentifier"]?.stringValue ?? "(no bundle identifier)"
        let hasTeam = app.kind.hasAppleTeam && team != nil
        func granted(_ key: String, in part: BundleFacts.Part = app) -> Bool {
            part.entitlements[key]?.isGranting == true
        }
        func usage(_ key: String) -> Bool {
            !(info[key]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        let restrictedKeys = entitlements.keys.filter { Entitlements.isRestricted($0) && granted($0) }.sorted()
        func authorized(_ key: String) -> Bool {
            guard hasTeam, let profile = facts.profile, let value = entitlements[key] else { return false }
            return profile.authorizes(key, value)
        }

        // Signature.
        var signature: [DoctorReport.Check] = []
        switch app.kind {
        case .unsigned:
            signature.append(.init(status: .error, title: "signature", detail: "the app is not signed.",
                                   fix: "bundle it with cef bundle, which always signs."))
        case .adHoc:
            signature.append(.init(
                status: .info, title: "signature",
                detail: "ad hoc. Runs on this Mac; Gatekeeper blocks it elsewhere, and restricted " +
                    "entitlements (keychain groups, iCloud Keychain passkeys) are unavailable.",
                fix: "sign with an Apple Development or Developer ID identity (--sign)."))
        case .other:
            signature.append(.init(
                status: .warning, title: "signature",
                detail: "\(app.authority ?? "a certificate") without an Apple team. macOS treats it like " +
                    "ad hoc for keychain groups and Gatekeeper.",
                fix: "sign with an Apple Development or Developer ID identity."))
        case .development:
            signature.append(.init(status: .ok, title: "signature",
                                   detail: "\(app.authority ?? "Apple Development"), for this team's devices."))
        case .developerID:
            signature.append(.init(status: .ok, title: "signature",
                                   detail: "\(app.authority ?? "Developer ID Application"), for distribution."))
        case .appStore:
            signature.append(.init(status: .warning, title: "signature",
                                   detail: "\(app.authority ?? "Apple Distribution"): App Store signing, which " +
                                       "requires the App Sandbox; CefSwift does not support it."))
        }
        if let verifyError = facts.verifyError {
            signature.append(.init(status: .error, title: "codesign --verify", detail: verifyError,
                                   fix: "bundle again; do not modify the bundle after signing."))
        } else {
            signature.append(.init(status: .ok, title: "codesign --verify", detail: "valid, nested code included."))
        }
        let disableLibraryValidation = "com.apple.security.cs.disable-library-validation"
        if runtime, team == nil, !granted(disableLibraryValidation) {
            signature.append(.init(
                status: .error, title: "library validation",
                detail: "the app has the hardened runtime and a signature without a team, so library validation " +
                    "refuses to load the framework.",
                fix: "bundle again with cef bundle (it adds \(disableLibraryValidation) to such builds), or sign " +
                    "with an Apple team identity."))
        }
        signature.append(runtime
            ? .init(status: .ok, title: "hardened runtime", detail: "on.")
            : .init(status: app.kind == .developerID ? .error : .info, title: "hardened runtime",
                    detail: app.kind == .developerID ? "off; notarization requires it." :
                        "off. Entitlements such as camera access are not enforced.",
                    fix: app.kind == .developerID ? "bundle with --hardened-runtime." : nil))
        if app.kind == .developerID {
            signature.append(app.hasSecureTimestamp
                ? .init(status: .ok, title: "secure timestamp", detail: "present.")
                : .init(status: .error, title: "secure timestamp", detail: "missing; notarization requires it.",
                        fix: "bundle with --timestamp (needs a network connection)."))
            if granted("com.apple.security.get-task-allow") {
                signature.append(.init(status: .error, title: "get-task-allow",
                                       detail: "set; notarization rejects apps that allow debugging.",
                                       fix: "remove com.apple.security.get-task-allow from the entitlements."))
            }
        }

        // Nested code: library validation needs one team throughout.
        var nested: [DoctorReport.Check] = []
        for helper in HelperKind.allCases {
            guard let part = facts.helpers[helper] else {
                nested.append(.init(status: .error, title: helper.rawValue, detail: "the helper app is missing.",
                                    fix: "bundle again with cef bundle."))
                continue
            }
            var problems: [String] = []
            var status = DoctorReport.Status.ok
            if part.teamIdentifier != team || part.kind != app.kind {
                problems.append("signed \(part.kind.displayName)\(part.teamIdentifier.map { " (team \($0))" } ?? ""), " +
                                "unlike the app")
                status = .error
            }
            if runtime, !part.isHardenedRuntime {
                problems.append("no hardened runtime")
                status = max(status, .warning)
            }
            if runtime, [.renderer, .gpu].contains(helper), !granted("com.apple.security.cs.allow-jit", in: part) {
                problems.append("missing com.apple.security.cs.allow-jit, which V8 and the shader compilers need " +
                                "under the hardened runtime")
                status = .error
            }
            if part.isHardenedRuntime, part.teamIdentifier == nil, !granted(disableLibraryValidation, in: part) {
                problems.append("library validation refuses the framework: the signature has no team to match " +
                                "and \(disableLibraryValidation) is missing")
                status = .error
            }
            if let key = part.entitlements.keys.sorted().first(where: { Entitlements.isRestricted($0) && granted($0, in: part) }) {
                problems.append("has the restricted entitlement \(key) without a provisioning profile of its own")
                status = .error
            }
            let keys = part.entitlements.filter { $0.value.isGranting }.keys.sorted()
            let detail = (problems.isEmpty ? "" : problems.joined(separator: "; ") + ". ") +
                "Entitlements: " + (keys.isEmpty ? "none" : keys.joined(separator: ", ")) + "."
            nested.append(.init(status: status, title: part.name, detail: detail,
                                fix: status == .error ? "bundle again with cef bundle, which signs every part alike." : nil))
        }
        let mismatched = facts.libraries.filter { !$0.isSigned || $0.teamIdentifier != team || $0.kind != app.kind }
        if mismatched.isEmpty {
            nested.append(.init(status: .ok, title: "framework and libraries",
                                detail: "\(facts.libraries.count) item(s), all signed like the app."))
        } else {
            let names = mismatched.map { "\($0.name) (\($0.isSigned ? $0.kind.displayName : "unsigned"))" }
            nested.append(.init(
                status: runtime || hasTeam ? .error : .warning, title: "framework and libraries",
                detail: "signed differently from the app: \(names.joined(separator: ", ")). Library " +
                    "validation refuses to load them" + (runtime ? "" : " once the hardened runtime is on") + ".",
                fix: "bundle again with cef bundle, which signs each library with the app's identity."))
        }
        let contents = "app libraries: " + (facts.appLibraries.isEmpty ? "none" : facts.appLibraries.joined(separator: ", ")) +
            "; resource bundles: " + (facts.resourceBundles.isEmpty ? "none" : facts.resourceBundles.joined(separator: ", "))
        if facts.linkageProblems.isEmpty {
            nested.append(.init(
                status: .ok, title: "linking",
                detail: "\(facts.architectures.joined(separator: ", ")) throughout; every library loads from the " +
                    "bundle or macOS. \(contents)."))
        } else {
            nested.append(.init(
                status: .error, title: "linking",
                detail: facts.linkageProblems.joined(separator: "; ") + ". It may run on this Mac and fail on " +
                    "others. \(contents).",
                fix: "bundle again with cef bundle, which copies the product's libraries and resource bundles " +
                    "into the app and removes run paths into the build directory."))
        }

        // Provisioning profile.
        var profileChecks: [DoctorReport.Check] = []
        if let error = facts.profileError {
            profileChecks.append(.init(status: .error, title: "embedded.provisionprofile", detail: error))
        } else if let profile = facts.profile {
            let identity = SigningIdentity(name: app.authority ?? "", kind: app.kind, teamIdentifier: team)
            let problems = profile.problems(
                bundleIdentifier: bundleID, identity: identity, certificateSHA1: nil,
                entitlements: entitlements, now: now)
            profileChecks.append(.init(
                status: problems.contains { $0.isError } ? .error : .ok, title: "embedded.provisionprofile",
                detail: "'\(profile.name)', \(profile.kind.rawValue), team \(profile.teamIdentifiers.joined(separator: ", ")), " +
                    "App ID \(profile.applicationIdentifier ?? "?")."))
            for problem in problems {
                profileChecks.append(.init(status: problem.isError ? .error : .warning, title: "profile",
                                           detail: problem.message))
            }
        } else if !restrictedKeys.isEmpty {
            profileChecks.append(.init(
                status: .error, title: "embedded.provisionprofile",
                detail: "missing, but the app has restricted entitlements (\(restrictedKeys.joined(separator: ", "))). " +
                    "macOS (AMFI) kills the app at launch.",
                fix: "set provisioningProfile in cefapp.json, or remove those entitlements."))
        } else {
            profileChecks.append(.init(status: .info, title: "embedded.provisionprofile",
                                       detail: "none; only needed for restricted entitlements."))
        }
        if !restrictedKeys.isEmpty, !app.kind.hasAppleTeam {
            profileChecks.append(.init(
                status: .error, title: "restricted entitlements",
                detail: "\(restrictedKeys.joined(separator: ", ")) on a \(app.kind.displayName) signature; " +
                    "macOS (AMFI) kills the app at launch.",
                fix: "sign with an Apple team identity and a profile, or remove them."))
        }

        // Distribution.
        var distribution: [DoctorReport.Check] = []
        if let accepted = facts.gatekeeperAccepted {
            let output = facts.gatekeeperOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "; ")
            distribution.append(.init(
                status: accepted ? .ok : (app.kind == .developerID ? .warning : .info), title: "Gatekeeper",
                detail: (accepted ? "accepted" : "rejected") + (output.isEmpty ? "." : " (\(output))."),
                fix: accepted || app.kind != .developerID ? nil : "notarize: swift package cef notarize <App.app>."))
        } else {
            distribution.append(.init(status: .info, title: "Gatekeeper", detail: "spctl could not assess the app here" +
                (facts.gatekeeperOutput.isEmpty ? "." : " (\(facts.gatekeeperOutput))."),
                fix: "run spctl --assess --type execute -vv <App.app> in Terminal."))
        }
        if let stapled = facts.isStapled {
            distribution.append(.init(
                status: stapled ? .ok : (app.kind == .developerID ? .warning : .info), title: "notarization ticket",
                detail: stapled ? "stapled." : "not stapled; the first launch needs a network connection to check it.",
                fix: stapled || app.kind != .developerID ? nil : "xcrun stapler staple <App.app> after notarizing."))
        }
        if facts.isQuarantined {
            let blocked = facts.gatekeeperAccepted != true
            distribution.append(.init(
                status: blocked ? .error : .ok, title: "quarantine",
                detail: blocked ? "the bundle has com.apple.quarantine and Gatekeeper rejects it, so it does not open."
                    : "the bundle has com.apple.quarantine; Gatekeeper accepts it.",
                fix: blocked ? "notarize, or for a local test: xattr -dr com.apple.quarantine <App.app>." : nil))
        } else {
            distribution.append(.init(status: .ok, title: "quarantine", detail: "not quarantined."))
        }

        // Features.
        var features: [DoctorReport.Check] = []
        let keychainPolicy = hasTeam
            ? "keychain (.automatic: team signature; \"Chromium Safe Storage\" in the login keychain)"
            : "mock keychain (.automatic: no team signature; cookies and passwords are not encrypted with a keychain key)"
        features.append(.init(status: hasTeam ? .ok : .info, title: "safe storage", detail: keychainPolicy))

        func feature(_ name: String, usageKeys: [String], entitlement: String?, what: String) {
            let hasUsage = usageKeys.allSatisfy(usage)
            let hasEntitlement = entitlement.map { granted($0) } ?? true
            if hasUsage && (hasEntitlement || !runtime) {
                features.append(.init(status: .ok, title: name, detail: "available: \(what)."))
            } else if !hasUsage && !(entitlement.map { granted($0) } ?? false) {
                features.append(.init(status: .info, title: name,
                                      detail: "not configured; pages cannot use \(what).",
                                      fix: "add \"\(name)\" to capabilities."))
            } else {
                var missing: [String] = usageKeys.filter { !usage($0) }.map { "\($0) in Info.plist" }
                if runtime, let entitlement, !granted(entitlement) { missing.append("the \(entitlement) entitlement") }
                features.append(.init(status: .warning, title: name,
                                      detail: "requests fail: missing \(missing.joined(separator: " and ")).",
                                      fix: "add \"\(name)\" to capabilities with a usage description."))
            }
        }
        feature("camera", usageKeys: ["NSCameraUsageDescription"], entitlement: "com.apple.security.device.camera",
                what: "the camera")
        feature("microphone", usageKeys: ["NSMicrophoneUsageDescription"],
                entitlement: "com.apple.security.device.audio-input", what: "the microphone")
        feature("location", usageKeys: ["NSLocationUsageDescription"],
                entitlement: "com.apple.security.personal-information.location", what: "the Geolocation API")
        feature("bluetooth", usageKeys: ["NSBluetoothAlwaysUsageDescription"],
                entitlement: "com.apple.security.device.bluetooth", what: "Web Bluetooth and phones as passkeys")
        feature("localNetwork", usageKeys: ["NSLocalNetworkUsageDescription"], entitlement: nil,
                what: "local network devices")
        if runtime {
            features.append(granted("com.apple.security.device.usb")
                ? .init(status: .ok, title: "usb", detail: "available: WebUSB.")
                : .init(status: .info, title: "usb", detail: "not configured; WebUSB finds no devices under the hardened runtime.",
                        fix: "add \"usb\" to capabilities."))
        }
        let schemes = (info["CFBundleURLTypes"]?.arrayValue ?? [])
            .flatMap { $0.dictionaryValue?["CFBundleURLSchemes"]?.strings ?? [] }
        features.append(schemes.contains("http") && schemes.contains("https")
            ? .init(status: .ok, title: "defaultBrowser", detail: "declares http and https; it can be chosen as the default browser.")
            : .init(status: .info, title: "defaultBrowser", detail: "does not declare http and https URL types.",
                    fix: "add \"defaultBrowser\" to capabilities."))

        // Protected media: Widevine runs in the base helper.
        if let helper = facts.helpers[.base] {
            let validates = helper.isHardenedRuntime && !granted(disableLibraryValidation, in: helper)
            if validates, helper.teamIdentifier != nil {
                features.append(.init(
                    status: .info, title: "protectedMedia",
                    detail: "Widevine cannot load: \(helper.name) has the hardened runtime and library validation, " +
                        "which refuses the CDM because Google's team signs it. Clear Key works.",
                    fix: "add \"protectedMedia\" to capabilities if pages need Widevine."))
            } else {
                features.append(.init(
                    status: .ok, title: "protectedMedia",
                    detail: "Widevine can load in \(helper.name) once Chromium has downloaded it " +
                        "(CefConfiguration.protectedMedia = .automatic; CefRuntime.widevine reports it)."))
            }
            features.append(.init(
                status: .info, title: "protectedMedia: Verified Media Path",
                detail: "unverified. Stock CEF gives the Widevine CDM no signed host binary to verify, so " +
                    "licence servers see an unverified software (L3) client: services that require VMP, such as " +
                    "Netflix, refuse Widevine playback here. CefSystemBrowser plays them with WebKit and FairPlay.",
                fix: nil))
        }

        // Passkeys, as Chromium decides at run time.
        var authenticators = ["security keys (USB/NFC)"]
        let hybrid = usage("NSBluetoothAlwaysUsageDescription") && (!runtime || granted("com.apple.security.device.bluetooth"))
        if hybrid { authenticators.append("phones (hybrid)") }
        // Chromium checks for its compiled-in group exactly; see
        // Capability.cefWebAuthnKeychainGroup.
        let group = Capability.cefWebAuthnKeychainGroup
        let groups = entitlements["keychain-access-groups"]?.strings ?? []
        let touchID = hasTeam && groups.contains(group) && authorized("keychain-access-groups")
        if touchID { authenticators.append("Touch ID (Chromium profile)") }
        let iCloud = hasTeam && granted(Capability.publicKeyCredentialEntitlement)
            && authorized(Capability.publicKeyCredentialEntitlement)
        if iCloud { authenticators.append("iCloud Keychain") }

        features.append(.init(status: .ok, title: "passkeys: security keys", detail: "available."))
        features.append(hybrid
            ? .init(status: .ok, title: "passkeys: phones (hybrid)", detail: "available (needs Bluetooth on).")
            : .init(status: .info, title: "passkeys: phones (hybrid)",
                    detail: "unavailable: needs NSBluetoothAlwaysUsageDescription" + (runtime ? " and com.apple.security.device.bluetooth." : "."),
                    fix: "add \"passkeys\" or \"bluetooth\" to capabilities."))
        features.append(touchID
            ? .init(status: .ok, title: "passkeys: Touch ID", detail: "available (keychain group \(group)).")
            : .init(status: .info, title: "passkeys: Touch ID",
                    detail: "unavailable: CEF 156 looks for the keychain group \"\(group)\", which has no team " +
                        "prefix, so no provisioning profile can authorize it. Use CefPasskeyMode.app with " +
                        "CefKeychainPasskeyStore for passkeys verified with Touch ID."))
        features.append(iCloud
            ? .init(status: .ok, title: "passkeys: iCloud Keychain", detail: "available.")
            : .init(status: .info, title: "passkeys: iCloud Keychain",
                    detail: "unavailable: needs \(Capability.publicKeyCredentialEntitlement), which Apple grants to " +
                        "web browsers, in a provisioning profile, and an Apple team signature.",
                    fix: "request the entitlement from Apple, then add \"passkeys\" to capabilities and set provisioningProfile."))

        let libraryNames = Set(facts.libraries.map(\.name))
        features.append(libraryNames.contains("libcef_sandbox.dylib") && libraryNames.contains("libcefswift_helper_startup.dylib")
            ? .init(status: .ok, title: "Chromium sandbox",
                    detail: "the helpers can seal themselves (libcef_sandbox.dylib, libcefswift_helper_startup.dylib); " +
                        "CefConfiguration.isSandboxEnabled decides at run time.")
            : .init(status: .warning, title: "Chromium sandbox",
                    detail: "the bundle lacks libcef_sandbox.dylib or libcefswift_helper_startup.dylib, so sandboxed " +
                        "helpers cannot start.",
                    fix: "bundle with cef bundle, or set CefConfiguration.isSandboxEnabled = false."))

        return DoctorReport(
            app: app.name, bundleIdentifier: bundleID,
            signature: app.kind.displayName + (runtime ? ", hardened runtime" : ""),
            teamIdentifier: hasTeam ? team : nil,
            keychainPolicy: hasTeam ? "keychain" : "mock keychain",
            passkeyAuthenticators: authenticators,
            sections: [
                .init(name: "Signature", checks: signature),
                .init(name: "Nested code", checks: nested),
                .init(name: "Provisioning profile", checks: profileChecks),
                .init(name: "Distribution", checks: distribution),
                .init(name: "Features", checks: features),
            ] + (facts.footprint.map { [.init(name: "Footprint", checks: footprintChecks($0))] } ?? []))
    }

    /// Sizes, and the locale packs against the app's localizations.
    static func footprintChecks(_ footprint: BundleFacts.Footprint) -> [DoctorReport.Check] {
        let mib = FrameworkTrim.formatted
        var checks: [DoctorReport.Check] = [
            .init(status: .info, title: "size", detail: "\(mib(footprint.appBytes)) (logical): framework binary " +
                  "\(mib(footprint.frameworkBinaryBytes)), framework resources \(mib(footprint.frameworkResourcesBytes)), " +
                  "helpers \(mib(footprint.helperBytes))."),
        ]
        let packs = Set(footprint.localePacks.keys)
        let packBytes = footprint.localePacks.values.reduce(0, +)
        let needed = ChromiumLocales.packsToKeep(
            for: footprint.appLocalizations, developmentLanguage: footprint.developmentLanguage, packs: packs)
        let mapping = (footprint.appLocalizations.isEmpty ? [footprint.developmentLanguage] : footprint.appLocalizations)
            .map { "\($0) → \(ChromiumLocales.pack(for: $0, in: packs) ?? "none")" }
        let extra = packs.subtracting(needed)
        checks.append(.init(
            status: .info, title: "locale packs",
            detail: "\(packs.count) (\(mib(packBytes))): \(packs.sorted().joined(separator: ", ")). App localizations: " +
                mapping.joined(separator: ", ") + ".",
            fix: extra.isEmpty ? nil : "\(extra.count) packs serve no localization of the app; --localizations " +
                "application leaves them out (\(mib(extra.reduce(0) { $0 + (footprint.localePacks[$1] ?? 0) })))."))
        for localization in footprint.appLocalizations where ChromiumLocales.pack(for: localization, in: packs) == nil {
            let fallback = ChromiumLocales.resolve([], developmentLanguage: footprint.developmentLanguage, packs: packs) ?? "en"
            checks.append(.init(
                status: .warning, title: "locale pack for \(localization)",
                detail: "the bundle has no Chromium pack for \(localization); Chromium's interface shows " +
                    "\(ChromiumLocales.chromiumLocale(forPack: fallback)) for it.",
                fix: "add it to cefapp.json \"cef\": {\"localizations\"}, or bundle with --localizations all " +
                    "(Chromium may have no pack for it at all)."))
        }
        checks.append(footprint.softwareGPUBytes.map {
            .init(status: .info, title: "software GPU fallback",
                  detail: "included (SwiftShader, \(mib($0))).",
                  fix: "--software-gpu-fallback exclude leaves it out, and with it WebGL and GPU compositing " +
                      "where the GPU is unavailable.")
        } ?? .init(status: .info, title: "software GPU fallback",
                   detail: "left out: where the GPU is unavailable or blocklisted, pages get no WebGL and " +
                       "Chromium composites on the CPU."))
        return checks
    }

    /// Parses `codesign -d --verbose=4` output (on stderr) into a part.
    static func parseCodesignDisplay(_ output: String, into part: inout BundleFacts.Part) {
        let lines = output.split(separator: "\n").map(String.init)
        if lines.contains(where: { $0.contains("code object is not signed at all") }) {
            part.isSigned = false
            part.kind = .unsigned
            return
        }
        var authorities: [String] = []
        for line in lines {
            if line.hasPrefix("Authority=") { authorities.append(String(line.dropFirst("Authority=".count))) }
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                part.teamIdentifier = value == "not set" ? nil : value
            }
            if line.hasPrefix("Timestamp=") { part.hasSecureTimestamp = true }
            if line.hasPrefix("CodeDirectory "), let range = line.range(of: "flags=") {
                let flags = line[range.upperBound...].prefix { $0 != " " }
                part.isHardenedRuntime = flags.contains("runtime")
                if flags.contains("adhoc") { part.kind = .adHoc }
            }
        }
        if part.kind != .adHoc {
            part.authority = authorities.first
            part.kind = authorities.first.map(SignatureKind.init(certificateName:)) ?? .other
        }
    }
}
