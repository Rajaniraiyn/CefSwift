import SwiftUI
import CefKit
import CefSwiftUI

/// Embedding showcase: web content as ordinary SwiftUI cards in a native dashboard.
///
/// Where `Browser` is "build a browser", `Gallery` is "drop web views into your app":
/// runtime styles per card, muted media, console-message plumbing into native UI, and
/// URLs driven by native controls.
@main
struct GalleryApp: CefSwiftApp {

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.cachePath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rajaniraiyn.cefswift.gallery/Cache", isDirectory: true)
        config.logSeverity = .warning
        config.userAgentProduct = "CefSwiftGallery/1.0"
        // Pluggable chromium switches flow straight through:
        config.extraCommandLineSwitches = [
            "autoplay-policy": "no-user-gesture-required"
        ]
        // Demo profile: never touch the keychain (no "Chromium Safe Storage" prompt).
        config.safeStorage = .mockKeychain
        // Custom scheme serving the Swift ↔ JS bridge demo page (see BridgeCard.swift).
        config.customSchemes = [CefCustomScheme(name: "gallery")]
        return config
    }

    init() {
        // CEF is initialized before SwiftUI constructs the App; register the
        // gallery:// page handler and the bridge functions now.
        BridgeDemo.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            GalleryView()
                .frame(minWidth: 980, minHeight: 700)
        }
    }
}
