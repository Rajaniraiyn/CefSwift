import Foundation

/// One of the five helper apps in `Contents/Frameworks/`.
enum HelperKind: String, CaseIterable, Codable, Sendable {
    /// `<App> Helper.app`: utility processes, such as the network, audio
    /// and video capture services.
    case base = "helper"
    case alerts
    case gpu
    case plugin
    case renderer

    /// The part of the helper's name in parentheses, if any.
    var nameSuffix: String? {
        switch self {
        case .base: return nil
        case .alerts: return "Alerts"
        case .gpu: return "GPU"
        case .plugin: return "Plugin"
        case .renderer: return "Renderer"
        }
    }

    var bundleIdentifierSuffix: String {
        self == .base ? ".helper" : ".helper.\(rawValue)"
    }

    func appName(for executable: String) -> String {
        nameSuffix.map { "\(executable) Helper (\($0))" } ?? "\(executable) Helper"
    }

    /// The entitlements each helper gets, from CEF's code-signing guide
    /// and Chromium's `chrome/app/helper-{renderer,gpu}-entitlements.plist`:
    /// V8 in renderers and the shader compilers in the GPU process generate
    /// code at run time, which the hardened runtime allows only with
    /// `allow-jit`. The other helpers need nothing.
    var baseEntitlements: PlistDictionary {
        switch self {
        case .renderer, .gpu:
            return ["com.apple.security.cs.allow-jit": .bool(true)]
        case .base, .alerts, .plugin:
            return [:]
        }
    }

    /// Info.plist keys particular to this helper, from Chromium's
    /// `chrome/app/helper-alerts-Info.plist`.
    var infoPlist: PlistDictionary {
        self == .alerts ? ["NSUserNotificationAlertStyle": .string("alert")] : [:]
    }
}

/// A feature the app opts into in `cefapp.json` (`"capabilities"`), which
/// `cef bundle` turns into the Info.plist keys and entitlements it needs.
struct Capability: Sendable {
    let name: String
    /// What the capability is for, for messages and `cef doctor`.
    let summary: String
    /// Other capabilities this one includes.
    var implies: [String] = []
    /// Info.plist keys whose value is the usage description the user
    /// supplies in `usageDescriptions[name]`.
    var usageDescriptionKeys: [String] = []
    /// Whether the usage description may be left out.
    var usageDescriptionIsOptional = false
    /// Fixed Info.plist keys.
    var infoPlist: PlistDictionary = [:]
    /// Hardened-runtime and other unrestricted entitlements of the app.
    var entitlements: PlistDictionary = [:]
    /// Entitlements added to helpers, for features that run in a helper
    /// process.
    var helperEntitlements: [HelperKind: PlistDictionary] = [:]
    /// Entitlements that a provisioning profile has to authorize and that
    /// need a team signature. Applied only when both are present.
    var restrictedEntitlements: PlistDictionary = [:]
    /// What the user loses when the restricted entitlements cannot be
    /// applied.
    var restrictedEffect: String = ""

    /// The keychain access group of Chromium's profile passkey (Touch ID)
    /// authenticator in CEF 156, as compiled into the framework:
    /// `MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING
    /// ".webauthn"` with Chromium's branding, whose team identifier is
    /// empty. It has no team prefix, so no provisioning profile can
    /// authorize it, and the authenticator needs a CEF build with another
    /// team and bundle identifier.
    static let cefWebAuthnKeychainGroup = ".org.chromium.Chromium.webauthn"
    static let disableLibraryValidation = "com.apple.security.cs.disable-library-validation"
    static let publicKeyCredentialEntitlement = "com.apple.developer.web-browser.public-key-credential"

    static let all: [Capability] = [
        Capability(
            name: "camera",
            summary: "camera access for getUserMedia",
            usageDescriptionKeys: ["NSCameraUsageDescription"],
            entitlements: ["com.apple.security.device.camera": .bool(true)],
            helperEntitlements: [.base: ["com.apple.security.device.camera": .bool(true)]]),
        Capability(
            name: "microphone",
            summary: "microphone access for getUserMedia and speech input",
            usageDescriptionKeys: ["NSMicrophoneUsageDescription"],
            entitlements: ["com.apple.security.device.audio-input": .bool(true)],
            helperEntitlements: [.base: ["com.apple.security.device.audio-input": .bool(true)]]),
        Capability(
            name: "location",
            summary: "the Geolocation API, through Core Location",
            usageDescriptionKeys: ["NSLocationUsageDescription"],
            entitlements: ["com.apple.security.personal-information.location": .bool(true)]),
        Capability(
            name: "bluetooth",
            summary: "Web Bluetooth, and phones as passkey authenticators (hybrid, QR code)",
            usageDescriptionKeys: ["NSBluetoothAlwaysUsageDescription"],
            entitlements: ["com.apple.security.device.bluetooth": .bool(true)]),
        Capability(
            name: "usb",
            summary: "WebUSB",
            entitlements: ["com.apple.security.device.usb": .bool(true)]),
        Capability(
            name: "localNetwork",
            summary: "devices on the local network, such as Cast receivers found over Bonjour",
            usageDescriptionKeys: ["NSLocalNetworkUsageDescription"],
            infoPlist: ["NSBonjourServices": .array([.string("_googlecast._tcp")])]),
        Capability(
            name: "appleEvents",
            summary: "sending Apple Events to other apps",
            usageDescriptionKeys: ["NSAppleEventsUsageDescription"],
            entitlements: ["com.apple.security.automation.apple-events": .bool(true)]),
        Capability(
            name: "passkeys",
            summary: "Chromium's passkey authenticators beyond security keys: phones (hybrid, over "
                + "Bluetooth) and iCloud Keychain",
            implies: ["bluetooth"],
            usageDescriptionKeys: ["NSWebBrowserPublicKeyCredentialUsageDescription"],
            usageDescriptionIsOptional: true,
            restrictedEntitlements: [publicKeyCredentialEntitlement: .bool(true)],
            restrictedEffect: "iCloud Keychain passkeys are unavailable; security keys and phones (hybrid) "
                + "still work"),
        Capability(
            name: "protectedMedia",
            summary: "protected (DRM) media with Google's Widevine CDM, which Chromium downloads at run time and "
                + "loads into the base helper",
            // The CDM is signed by Google's team. Under the hardened runtime
            // library validation lets a process load only its own team's
            // libraries (or Apple's), so a team-signed helper refuses it.
            helperEntitlements: [.base: [Capability.disableLibraryValidation: .bool(true)]]),
        Capability(
            name: "defaultBrowser",
            summary: "being chosen as the default web browser",
            infoPlist: [
                "CFBundleURLTypes": .array([.dictionary([
                    "CFBundleURLName": .string("Web site URL"),
                    "CFBundleURLSchemes": .array([.string("http"), .string("https")]),
                ])]),
                "CFBundleDocumentTypes": .array([.dictionary([
                    "CFBundleTypeName": .string("HTML document"),
                    "CFBundleTypeRole": .string("Viewer"),
                    "LSHandlerRank": .string("Default"),
                    "LSItemContentTypes": .array([.string("public.html"), .string("public.xhtml")]),
                ])]),
            ]),
        Capability(
            name: "handoff",
            summary: "continuing web pages on other devices with Handoff",
            infoPlist: ["NSUserActivityTypes": .array([.string("NSUserActivityTypeBrowsingWeb")])]),
    ]

    static func named(_ name: String) -> Capability? {
        all.first { $0.name == name }
    }

    /// The capabilities named, with those they imply, in catalog order.
    static func resolve(_ names: [String]) throws -> [Capability] {
        var wanted = Set<String>()
        func add(_ name: String, requiredBy: String?) throws {
            guard let capability = named(name) else {
                let context = requiredBy.map { " (implied by '\($0)')" } ?? ""
                throw CefPluginError(
                    "Unknown capability '\(name)'\(context) in cefapp.json \"capabilities\". " +
                    "Known capabilities: \(all.map(\.name).joined(separator: ", ")).")
            }
            guard wanted.insert(name).inserted else { return }
            for implied in capability.implies { try add(implied, requiredBy: name) }
        }
        for name in names { try add(name, requiredBy: nil) }
        return all.filter { wanted.contains($0.name) }
    }
}
