// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CefSwift",
    // The built-in sheets' strings are English, in each target's
    // Resources/en.lproj; another language is another .lproj beside it.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CefKit", targets: ["CefKit"]),
        .library(name: "CefSwiftUI", targets: ["CefSwiftUI"]),
        .library(name: "CefPasskeys", targets: ["CefPasskeys"]),
        .library(name: "CefChromium", targets: ["CefChromium"]),
        .plugin(name: "CefPlugin", targets: ["CefPlugin"]),
        // The helper processes' executable and its startup library, which
        // `swift package cef bundle` builds and puts in the app bundle.
        .executable(name: "cefswift-helper", targets: ["CefHelper"]),
        .library(name: "cefswift_helper_startup", type: .dynamic, targets: ["CefHelperStartup"]),
    ],
    targets: [
        // Vendored CEF C API headers + runtime dlopen/dlsym loader.
        .target(
            name: "CCef",
            exclude: [
                "LICENSE.CEF.txt",
                "include/include/base/internal/cef_color_id_macros.inc",
                "include/include/base/internal/README-TRANSFER.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // Reference counting and strings for CEF objects, shared by every
        // process: no Foundation, no AppKit.
        .target(
            name: "CefBase",
            dependencies: ["CCef"]
        ),
        // Renderer-side features (bridges, user scripts, evaluation) on the
        // V8 API, run by the helper processes. No Foundation, no AppKit.
        .target(
            name: "CefRenderer",
            dependencies: ["CCef", "CefBase"]
        ),
        // The helper executable: a few lines calling CefRenderer.
        .executableTarget(
            name: "CefHelper",
            dependencies: ["CefRenderer"]
        ),
        // Seals the sandbox in a helper before the framework's code runs.
        .target(
            name: "CefHelperStartup"
        ),
        // Core Swift wrapper over the CEF C API, and the AppKit views that
        // host a browser (windowed and offscreen).
        .target(
            name: "CefKit",
            dependencies: ["CCef", "CefBase"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Optional: WebAuthn answered by the app, or refused, instead of
        // Chromium. A CefBrowserAttachment over the DevTools protocol.
        .target(
            name: "CefPasskeys",
            dependencies: ["CefKit"],
            resources: [.process("Resources")]
        ),
        // Optional: Chromium's own browser features, bound to Chromium's
        // private WebUI interfaces and AppKit classes of the pinned CEF:
        // bookmarks, history and autocomplete through CefKit's internal
        // service hosts, and Chromium's surfaces (bubbles, find bar, status
        // bubble) in Chrome-style windows, with their SwiftUI glue.
        .target(
            name: "CefChromium",
            dependencies: ["CefKit", "CCef", "CefBase"]
        ),
        // SwiftUI integration: `CefWebView`, `CefSwiftApp` and modifiers,
        // built on CefKit's AppKit host views.
        .target(
            name: "CefSwiftUI",
            dependencies: ["CefKit"]
        ),
        // `swift package cef <download|bundle|info|clean|doctor|notarize>`
        // Also builds the helper products when bundling.
        .plugin(
            name: "CefPlugin",
            capability: .command(
                intent: .custom(
                    verb: "cef",
                    description: "Download the pinned CEF distribution and assemble runnable .app bundles"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Cache CEF distributions in .cef/ and write .app bundles"),
                    .allowNetworkConnections(scope: .all(ports: []), reason: "Download CEF binaries from cef-builds.spotifycdn.com"),
                ]
            ),
        ),
        .testTarget(
            name: "CefKitTests",
            dependencies: ["CefKit", "CefBase", "CefRenderer"]
        ),
        // Compiles the plugin's pure logic (Plugins/CefPlugin/Distribution,
        // linked in as a directory symlink) so it can be unit-tested.
        .testTarget(
            name: "CefPluginTests"
        ),
        // An AppKit consumer: imports CefKit and AppKit only, without
        // `@testable`, to prove hosting a browser needs no SwiftUI.
        .testTarget(
            name: "CefKitAppKitTests",
            dependencies: ["CefKit"]
        ),
        .testTarget(
            name: "CefPasskeysTests",
            dependencies: ["CefPasskeys", "CefKit"]
        ),
        .testTarget(
            name: "CefChromiumTests",
            dependencies: ["CefChromium", "CefKit"]
        ),
    ],
    cLanguageStandard: .c11
)
