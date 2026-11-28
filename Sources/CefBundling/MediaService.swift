import Foundation

/// CefSwift's media service, which the `systemMediaDecoders` capability
/// adds: `Contents/XPCServices/<App> Media.xpc`, an XPC service that
/// decodes pages' audio with the system's decoders for the app's process
/// (`CefRuntime.Configuration.Services.systemMediaDecoders`).
///
/// It runs in the App Sandbox with no other entitlement: no network, no
/// files outside its container, no devices. Only the app's own processes
/// can connect to an XPC service in its bundle, and Chromium's sandbox
/// keeps renderers from looking it up. The App Sandbox entitlement is not
/// restricted, so any signature carries it, ad hoc included.
enum MediaService {
    static let bundleIdentifierSuffix = ".media"

    /// The service runs sandboxed whatever the app's signature.
    static let entitlements: PlistDictionary = ["com.apple.security.app-sandbox": .bool(true)]

    static func executableName(for executable: String) -> String { "\(executable) Media" }
    static func bundleName(for executable: String) -> String { "\(executableName(for: executable)).xpc" }

    static func infoPlist(
        executableName: String, bundleIdentifier: String, version: String, build: String, minimumSystemVersion: String
    ) -> PlistDictionary {
        [
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(executableName),
            // CefKit connects to `<app identifier>.media`.
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
}
