import CryptoKit
import Foundation

enum SHA1 {
    static func hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

enum Entitlements {
    /// Whether macOS requires a provisioning profile to authorize the
    /// entitlement. Signing an app with such an entitlement and no profile
    /// that allows it makes AMFI (AppleMobileFileIntegrity) kill the app
    /// at launch.
    static func isRestricted(_ key: String) -> Bool {
        key == "keychain-access-groups"
            || key == "com.apple.application-identifier"
            || key == "application-identifier"
            || key.hasPrefix("com.apple.developer.")
    }

    static func describe(_ value: PlistValue) -> String {
        switch value {
        case .string(let value): return "\"\(value)\""
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return "\(value)"
        case .real(let value): return "\(value)"
        case .array(let values): return "[" + values.map(describe).joined(separator: ", ") + "]"
        case .dictionary: return "{…}"
        case .date, .data: return "…"
        }
    }

    /// Expands Xcode-style variables in every string of `entitlements`:
    /// `$(TeamIdentifierPrefix)` and `$(AppIdentifierPrefix)` become
    /// `<team ID>.`, `$(TeamIdentifier)` and `$(DEVELOPMENT_TEAM)` the team
    /// ID, `$(CFBundleIdentifier)` and `$(PRODUCT_BUNDLE_IDENTIFIER)` the
    /// bundle identifier. `${NAME}` works too.
    static func expand(
        _ entitlements: PlistDictionary, teamIdentifier: String?, bundleIdentifier: String, source: String
    ) throws -> PlistDictionary {
        var expanded: PlistDictionary = [:]
        for (key, value) in entitlements {
            expanded[key] = try value.mapStrings { string in
                try expand(string, teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier,
                           context: "\(key) in \(source)")
            }
        }
        return expanded
    }

    static func expand(
        _ string: String, teamIdentifier: String?, bundleIdentifier: String, context: String
    ) throws -> String {
        var result = ""
        var rest = Substring(string)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            let afterDollar = rest.index(after: dollar)
            guard afterDollar < rest.endIndex, rest[afterDollar] == "(" || rest[afterDollar] == "{" else {
                result.append("$")
                rest = rest[afterDollar...]
                continue
            }
            let closer: Character = rest[afterDollar] == "(" ? ")" : "}"
            guard let close = rest[afterDollar...].firstIndex(of: closer) else {
                throw BundlingError("Unterminated variable in \(context): \(string)")
            }
            let name = String(rest[rest.index(after: afterDollar)..<close])
            switch name {
            case "TeamIdentifierPrefix", "AppIdentifierPrefix", "TeamIdentifier", "DEVELOPMENT_TEAM":
                guard let teamIdentifier else {
                    throw BundlingError(
                        "$(\(name)) in \(context) needs a team identifier, but the bundle is not signed " +
                        "with an Apple team identity. Sign with an Apple Development or Developer ID " +
                        "identity (--sign or cefapp.json signingIdentity), or set teamIdentifier.")
                }
                result += name.hasSuffix("Prefix") ? "\(teamIdentifier)." : teamIdentifier
            case "CFBundleIdentifier", "PRODUCT_BUNDLE_IDENTIFIER":
                result += bundleIdentifier
            default:
                throw BundlingError(
                    "Unknown variable $(\(name)) in \(context). Known variables: $(TeamIdentifierPrefix), " +
                    "$(AppIdentifierPrefix), $(TeamIdentifier), $(CFBundleIdentifier).")
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }
}

/// What `cef bundle` writes into the bundle's Info.plists and signs into
/// its parts, derived from `cefapp.json` and the signing identity.
struct DistributionPlan: Sendable {
    /// Keys added to the app's Info.plist, over the plugin's own.
    var appInfoPlist: PlistDictionary = [:]
    var appEntitlements: PlistDictionary = [:]
    var helperEntitlements: [HelperKind: PlistDictionary] = [:]
    var hardenedRuntime: Bool = false
    var secureTimestamp: Bool = false
    /// What the user should know: features left out, and why.
    var warnings: [String] = []
}

/// The distribution settings `cef bundle` works from: `cefapp.json` with
/// the command line's options applied.
struct DistributionSettings: Sendable {
    var bundleIdentifier: String
    var identity: SigningIdentity
    var capabilities: [String] = []
    var usageDescriptions: [String: String] = [:]
    /// Info.plist dictionaries to merge, in order: `cefapp.json`'s
    /// `infoPlist`, then each `--info-plist` file.
    var infoPlistOverlays: [(source: String, plist: PlistDictionary)] = []
    /// The app's entitlements file, if any.
    var appEntitlementsFile: (source: String, plist: PlistDictionary)?
    var helperEntitlementFiles: [HelperKind: (source: String, plist: PlistDictionary)] = [:]
    var profile: ProvisioningProfile?
    /// The signing certificate's SHA-1, to check against the profile.
    var certificateSHA1: String?
    /// nil: on for Apple team identities, off otherwise.
    var hardenedRuntime: Bool?
    /// nil: on for Developer ID and App Store signing.
    var secureTimestamp: Bool?
    /// Whether whoever signs the app also embeds and checks its
    /// provisioning profile, as Xcode does: restricted entitlements in the
    /// app's entitlements are then its business.
    var signerManagesProfile = false
    /// Keys the app's Info.plist has already, such as the usage
    /// descriptions an Xcode target sets with `INFOPLIST_KEY_…`.
    var existingInfoPlistKeys: Set<String> = []

    /// Info.plist keys the plugin sets from other settings; overriding them
    /// breaks the bundle.
    static let reservedInfoPlistKeys: [String: String] = [
        "CFBundleExecutable": "the product name (--name)",
        "CFBundleIdentifier": "bundleIdentifier (--bundle-id)",
        "CFBundlePackageType": "the bundle type, always APPL",
        "CFBundleShortVersionString": "version (--version)",
        "CFBundleVersion": "build (--build)",
        "LSMinimumSystemVersion": "minimumSystemVersion",
    ]

    static let appSandbox = "com.apple.security.app-sandbox"

    func plan() throws -> DistributionPlan {
        var plan = DistributionPlan()
        let team = identity.teamIdentifier
        let canUseRestricted = identity.kind.hasAppleTeam && team != nil && (profile != nil || signerManagesProfile)
        plan.hardenedRuntime = hardenedRuntime ?? identity.kind.hasAppleTeam
        plan.secureTimestamp = secureTimestamp ?? (identity.kind == .developerID || identity.kind == .appStore)

        // 1. Capabilities.
        var appEntitlements: PlistDictionary = [:]
        var helperEntitlements: [HelperKind: PlistDictionary] = [:]
        var usageKeysSatisfiedByInfoPlist = existingInfoPlistKeys
        for overlay in infoPlistOverlays {
            usageKeysSatisfiedByInfoPlist.formUnion(overlay.plist.keys)
        }
        for capability in try Capability.resolve(capabilities) {
            if !capability.usageDescriptionKeys.isEmpty {
                let text = usageDescriptions[capability.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, !text.isEmpty {
                    for key in capability.usageDescriptionKeys { plan.appInfoPlist[key] = .string(text) }
                } else if !capability.usageDescriptionIsOptional,
                          !capability.usageDescriptionKeys.allSatisfy(usageKeysSatisfiedByInfoPlist.contains) {
                    let implied = capabilities.contains(capability.name) ? "" : " (included by another capability)"
                    throw BundlingError(
                        "The capability '\(capability.name)'\(implied) needs a usage description: the sentence " +
                        "macOS shows when it asks the user to allow \(capability.summary). Add it to cefapp.json:\n" +
                        "  \"usageDescriptions\": { \"\(capability.name)\": \"<why your app needs it>\" }\n" +
                        "or set \(capability.usageDescriptionKeys.joined(separator: " and ")) in \"infoPlist\".")
                }
            }
            plan.appInfoPlist = Plist.merge(plan.appInfoPlist, capability.infoPlist)
            appEntitlements = Plist.merge(appEntitlements, capability.entitlements)
            for (helper, entitlements) in capability.helperEntitlements {
                helperEntitlements[helper] = Plist.merge(helperEntitlements[helper] ?? [:], entitlements)
            }
            if !capability.restrictedEntitlements.isEmpty {
                let keys = capability.restrictedEntitlements.keys.sorted().joined(separator: ", ")
                if canUseRestricted, let team {
                    let expanded = try Entitlements.expand(
                        capability.restrictedEntitlements, teamIdentifier: team,
                        bundleIdentifier: bundleIdentifier, source: "capability '\(capability.name)'")
                    for (key, value) in expanded.sorted(by: { $0.key < $1.key }) {
                        if signerManagesProfile || profile?.authorizes(key, value) == true {
                            appEntitlements = Plist.merge(appEntitlements, [key: value])
                        } else {
                            plan.warnings.append(
                                "capability '\(capability.name)': the provisioning profile does not authorize " +
                                "\(key) = \(Entitlements.describe(value)), so it is left out. " +
                                "\(capability.restrictedEffect).")
                        }
                    }
                } else {
                    let reason: String
                    if !identity.kind.hasAppleTeam {
                        reason = "the bundle is signed \(identity.kind.displayName), and only an Apple team " +
                            "signature with a provisioning profile can carry them"
                    } else if team == nil {
                        reason = "the signing identity's team identifier is unknown (set teamIdentifier)"
                    } else {
                        reason = "no provisioning profile is embedded (set provisioningProfile)"
                    }
                    plan.warnings.append(
                        "capability '\(capability.name)': \(keys) left out because \(reason). " +
                        "\(capability.restrictedEffect).")
                }
            }
        }

        // 2. The app's own entitlements file.
        if let file = appEntitlementsFile {
            // Name a restricted entitlement on an ad hoc signature before a
            // variable in it fails to expand.
            if !identity.kind.hasAppleTeam,
               let key = file.plist.keys.sorted().first(where: { Entitlements.isRestricted($0) && file.plist[$0]?.isGranting == true }) {
                throw BundlingError(
                    "\(file.source) has the restricted entitlement \(key), which needs a provisioning " +
                    "profile and an Apple team signature, but the bundle is signed " +
                    "\(identity.kind.displayName). macOS (AMFI) would kill the app at launch. Sign with " +
                    "an Apple Development or Developer ID identity and set provisioningProfile, or remove " +
                    "\(key) for local builds.")
            }
            let expanded = try Entitlements.expand(
                file.plist, teamIdentifier: team, bundleIdentifier: bundleIdentifier, source: file.source)
            for (key, value) in expanded.sorted(by: { $0.key < $1.key })
            where Entitlements.isRestricted(key) && value.isGranting && !signerManagesProfile {
                if !identity.kind.hasAppleTeam {
                    throw BundlingError(
                        "\(file.source) has the restricted entitlement \(key), which needs a provisioning " +
                        "profile and an Apple team signature, but the bundle is signed " +
                        "\(identity.kind.displayName). macOS (AMFI) would kill the app at launch. Sign with " +
                        "an Apple Development or Developer ID identity and set provisioningProfile, or remove " +
                        "\(key) for local builds.")
                }
                guard let profile else {
                    throw BundlingError(
                        "\(file.source) has the restricted entitlement \(key), which a provisioning profile " +
                        "must authorize; without one macOS (AMFI) kills the app at launch. Set " +
                        "provisioningProfile in cefapp.json or pass --provisioning-profile.")
                }
                if !profile.authorizes(key, value) {
                    throw BundlingError(
                        "\(file.source): the provisioning profile '\(profile.name)' does not authorize " +
                        "\(key) = \(Entitlements.describe(value)); macOS (AMFI) would kill the app at " +
                        "launch. Enable the capability for the App ID and download the profile again.")
                }
            }
            appEntitlements = Plist.merge(appEntitlements, expanded)
        }

        // 3. What a provisioning profile adds, as Xcode does.
        if let profile, canUseRestricted, let team, !signerManagesProfile {
            if let appID = profile.applicationIdentifier {
                let wanted = "\(team).\(bundleIdentifier)"
                appEntitlements["com.apple.application-identifier"] =
                    .string(ProvisioningProfile.matches(wanted, anyOf: [appID]) ? wanted : appID)
            }
            if profile.entitlements["com.apple.developer.team-identifier"] != nil {
                appEntitlements["com.apple.developer.team-identifier"] = .string(team)
            }
        } else if profile != nil {
            plan.warnings.append(
                "provisioningProfile is set, but the bundle is signed \(identity.kind.displayName); " +
                "so it is not embedded: a profile authorizes nothing without an Apple team signature.")
        }

        // 4. Development signing can be debugged; distribution signing
        // must not be (notarization rejects get-task-allow).
        let getTaskAllow = "com.apple.security.get-task-allow"
        if identity.kind == .development, appEntitlements[getTaskAllow] == nil {
            appEntitlements[getTaskAllow] = .bool(true)
        }
        if identity.kind == .developerID || identity.kind == .appStore, appEntitlements[getTaskAllow]?.isGranting == true {
            throw BundlingError(
                "\(getTaskAllow) is set, but the bundle is signed \(identity.kind.displayName). Notarization " +
                "and the App Store reject apps that allow debugging; remove it from the entitlements.")
        }

        if appEntitlements[Self.appSandbox]?.isGranting == true {
            throw BundlingError(
                "The App Sandbox is on (\(Self.appSandbox) in \(appEntitlementsFile?.source ?? "the entitlements")), " +
                "and Chromium cannot run in it: the App Sandbox refuses the Mach service Chromium's browser process " +
                "registers at launch, and the app stops with \"bootstrap_check_in " +
                "<bundle ID>.MachPortRendezvousServer.<pid>: Permission denied (1100)\". Remove the entitlement " +
                "(in Xcode: remove App Sandbox in Signing & Capabilities, ENABLE_APP_SANDBOX = NO). Chromium's " +
                "own sandbox still confines the helpers (docs/sandbox.md); see docs/bundling.md#app-sandbox.")
        }

        // Library validation accepts a library only from the process's own
        // team (or Apple). A signature without a team matches nothing, so
        // under the hardened runtime such a build turns it off. A team
        // signature needs to only for Google's Widevine CDM, which the
        // protectedMedia capability turns it off for, in the base helper.
        let disableLibraryValidation = "com.apple.security.cs.disable-library-validation"
        let teamless = plan.hardenedRuntime && !identity.kind.hasAppleTeam
        if teamless {
            appEntitlements[disableLibraryValidation] = appEntitlements[disableLibraryValidation] ?? .bool(true)
            plan.warnings.append(
                "the hardened runtime with \(identity.kind.displayName) signing: library validation cannot " +
                "match a signature without a team, so \(disableLibraryValidation) is added to the app and " +
                "helpers. Team-signed builds need it only in the base helper, for Widevine (capability protectedMedia).")
        }

        // 5. Helpers: built-in templates, what capabilities add, then the
        // overrides.
        for helper in HelperKind.allCases {
            var entitlements = Plist.merge(helper.baseEntitlements, helperEntitlements[helper] ?? [:])
            if teamless { entitlements[disableLibraryValidation] = appEntitlements[disableLibraryValidation] }
            // A debugger can attach to the helpers when it can to the app,
            // as in Xcode's Debug builds, which give the app get-task-allow.
            if identity.kind == .development || appEntitlements[getTaskAllow]?.isGranting == true {
                entitlements[getTaskAllow] = appEntitlements[getTaskAllow]
            }
            if let override = helperEntitlementFiles[helper] {
                let expanded = try Entitlements.expand(
                    override.plist, teamIdentifier: team, bundleIdentifier: bundleIdentifier,
                    source: override.source)
                if let key = expanded.keys.sorted().first(where: { Entitlements.isRestricted($0) && expanded[$0]?.isGranting == true }) {
                    throw BundlingError(
                        "\(override.source) gives the \(helper.rawValue) helper the restricted entitlement " +
                        "\(key). Helpers have no provisioning profile of their own, so macOS (AMFI) would " +
                        "kill them; keep restricted entitlements in the app's entitlements.")
                }
                entitlements = Plist.merge(entitlements, expanded)
            }
            plan.helperEntitlements[helper] = entitlements.filter { $0.value.isGranting || $0.key == getTaskAllow }
        }
        plan.appEntitlements = appEntitlements

        // 6. Info.plist overlays.
        for overlay in infoPlistOverlays {
            for key in overlay.plist.keys.sorted() {
                if let owner = Self.reservedInfoPlistKeys[key] {
                    throw BundlingError(
                        "\(overlay.source) sets \(key), which cef bundle derives from \(owner). Set that " +
                        "instead and remove \(key).")
                }
            }
            plan.appInfoPlist = Plist.merge(plan.appInfoPlist, overlay.plist)
        }
        if !plan.hardenedRuntime, identity.kind == .developerID {
            plan.warnings.append(
                "the hardened runtime is off; notarization requires it for Developer ID apps.")
        }
        return plan
    }
}
