import CefSwiftUI
import SwiftUI

/// A library of small examples, each showing one capability of CefSwift.
///
/// Chromium takes one runtime configuration per process and cannot restart,
/// so every demo runs under this one: the `.chrome` preset, which
/// Chrome-style windows, Chromium's data services and the media router
/// need, with offscreen rendering on for the demos that draw over a page.
///
/// Launch arguments:
///
/// - `-demo <Type>` opens a demo, such as `-demo BridgeDemo`.
/// - `-smoke` (or `GALLERY_SMOKE=1`) opens every demo in turn and quits;
///   see `Support/Smoke.swift`.
@main
struct GalleryApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.chrome
        configuration.isOffscreenRenderingEnabled = true
        configuration.customSchemes = [CefCustomScheme(name: "gallery")]
        // A demo app: a fixed key instead of the keychain, so no keychain
        // prompt ever appears, whatever the app is signed with.
        configuration.safeStorage = .mockKeychain
        // The demos work offline; nothing needs Chromium's components.
        configuration.services.componentUpdates = .disabled
        configuration.services.protectedMedia = .disabled
        configuration.preferences["browser.confirm_to_quit"] = false
        if let directory = Smoke.cacheDirectory {
            configuration.rootCacheDirectory = directory
        }
        return configuration
    }

    @State private var model = GalleryModel()

    init() {
        // Chromium is running by now: serve the sample pages before any
        // demo loads one.
        CefRuntime.shared.registerSchemeHandler(scheme: "gallery", domain: "pages", handler: SamplePages())
        Smoke.prepare()
    }

    var body: some Scene {
        Window("Gallery", id: "gallery") {
            GalleryView(model: model)
                .task {
                    if Smoke.isEnabled { await Smoke.run(model) }
                }
        }
        .defaultSize(width: 1180, height: 760)
    }
}
