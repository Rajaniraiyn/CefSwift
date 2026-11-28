import Foundation

/// An XPC service of CefSwift's that a capability adds to the bundle, in
/// `Contents/XPCServices/<App> <Name>.xpc`:
///
/// - ``media``, for `systemMediaDecoders`: decodes pages' audio with the
///   system's decoders for the app's process
///   (`CefRuntime.Configuration.Services.systemMediaDecoders`). App Sandbox
///   and nothing else: no network, no files outside its container, no
///   devices.
/// - ``fairPlay``, for `fairPlay`: plays a page's FairPlay Streaming audio
///   with AVFoundation (CefProtectedMedia's `CefFairPlay`). App Sandbox
///   with outgoing connections, which AVPlayer needs to fetch the stream's
///   segments.
///
/// Only the app's own processes can connect to an XPC service in its
/// bundle, and Chromium's sandbox keeps renderers from looking one up. The
/// App Sandbox entitlements are not restricted, so any signature carries
/// them, ad hoc included.
struct MediaService: Sendable, Equatable, Hashable {
    /// The SwiftPM product that builds the executable.
    let product: String
    /// The part of the bundle's and executable's name after the app's.
    let name: String
    let bundleIdentifierSuffix: String
    /// The package's source directories the product is built from.
    let sourceDirectories: [String]
    let entitlements: PlistDictionary

    static let media = MediaService(
        product: "cefswift-media", name: "Media", bundleIdentifierSuffix: ".media",
        sourceDirectories: ["Sources/CefMediaService"],
        entitlements: ["com.apple.security.app-sandbox": .bool(true)])

    static let fairPlay = MediaService(
        product: "cefswift-fairplay", name: "FairPlay", bundleIdentifierSuffix: ".fairplay",
        sourceDirectories: ["Sources/CefFairPlayService"],
        entitlements: [
            "com.apple.security.app-sandbox": .bool(true),
            "com.apple.security.network.client": .bool(true),
        ])

    static let all = [media, fairPlay]

    static func named(product: String) -> MediaService? { all.first { $0.product == product } }

    func executableName(for executable: String) -> String { "\(executable) \(name)" }
    func bundleName(for executable: String) -> String { "\(executableName(for: executable)).xpc" }

    func infoPlist(
        executableName: String, bundleIdentifier: String, version: String, build: String, minimumSystemVersion: String
    ) -> PlistDictionary {
        [
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(executableName),
            // CefKit and CefProtectedMedia connect to `<app identifier><suffix>`.
            "CFBundleIdentifier": .string(bundleIdentifier + bundleIdentifierSuffix),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(executableName),
            "CFBundlePackageType": .string("XPC!"),
            "CFBundleShortVersionString": .string(version),
            "CFBundleVersion": .string(build),
            "LSMinimumSystemVersion": .string(minimumSystemVersion),
            // One process for the app, started on the first request and
            // stopped by launchd when idle.
            "XPCService": .dictionary(["ServiceType": .string("Application")]),
        ]
    }

    // A service is its product.
    static func == (lhs: MediaService, rhs: MediaService) -> Bool { lhs.product == rhs.product }
    func hash(into hasher: inout Hasher) { hasher.combine(product) }
}
