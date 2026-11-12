// swift-tools-version: 6.0
import PackageDescription

// The official CEF framework for the version CEF_VERSION.json pins, both
// architectures in one XCFramework, as Scripts/package-cef.py packages it
// and the `cef-<version>` GitHub release hosts it (docs/automation.md).
// Scripts/package-cef.py --write and Scripts/update-cef.py rewrite these.
let cefFramework = (
    url: "https://github.com/Rajaniraiyn/CefSwift/releases/download/cef-156.0.28/ChromiumEmbeddedFramework.xcframework.zip",
    checksum: "426ccfde82b9f26274b97eb561e6c9c049206e7a06bac72398b95c7bbe8e9b45"
)

// CEFSWIFT_LOCAL_FRAMEWORK=1 uses the XCFramework that Scripts/package-cef.py
// builds in .cef/xcframework instead of the release asset, for work on
// CefSwift itself and for a CEF version not yet released. It is an
// environment variable rather than a check for the directory because
// SwiftPM caches the evaluated manifest by its text and environment.
let localCefFramework = ".cef/xcframework/ChromiumEmbeddedFramework.xcframework"
let cefFrameworkTarget: Target =
    ["", "0"].contains(Context.environment["CEFSWIFT_LOCAL_FRAMEWORK"] ?? "")
    ? .binaryTarget(name: "ChromiumEmbeddedFramework", url: cefFramework.url, checksum: cefFramework.checksum)
    : .binaryTarget(name: "ChromiumEmbeddedFramework", path: localCefFramework)

let package = Package(
    name: "CefSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CefKit", targets: ["CefKit"]),
        .library(name: "CefSwiftUI", targets: ["CefSwiftUI"]),
        // The CEF framework. An app's executable target depends on it, so
        // that dyld loads the framework at launch and Xcode embeds it; see
        // docs/bundling.md. Libraries and tests leave it out: CefKit loads
        // the framework at run time when the process has not linked it.
        .library(name: "ChromiumEmbeddedFramework", targets: ["ChromiumEmbeddedFramework"]),
        .plugin(name: "CefPlugin", targets: ["CefPlugin"]),
        // The helper processes' executable and its startup library, which
        // `swift package cef bundle` builds and puts in the app bundle.
        .executable(name: "cefswift-helper", targets: ["CefHelper"]),
        .library(name: "cefswift_helper_startup", type: .dynamic, targets: ["CefHelperStartup"]),
    ],
    targets: [
        cefFrameworkTarget,
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
        // Core Swift wrapper over the CEF C API.
        .target(
            name: "CefKit",
            dependencies: ["CCef", "CefBase"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // First-class SwiftUI integration.
        .target(
            name: "CefSwiftUI",
            dependencies: ["CefKit"]
        ),
        // `swift package cef <bundle|embed|doctor|package|notarize|info>`
        // Builds the helper products and assembles and signs the app.
        .plugin(
            name: "CefPlugin",
            capability: .command(
                intent: .custom(
                    verb: "cef",
                    description: "Assemble and sign CEF app bundles: the framework, five helper apps, entitlements"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Write .app bundles"),
                    .allowNetworkConnections(
                        scope: .all(ports: []),
                        reason: "Reach Apple's timestamp and notary services when signing and notarizing"),
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
        .testTarget(
            name: "CefSwiftUITests",
            dependencies: ["CefSwiftUI"]
        ),
    ],
    cLanguageStandard: .c11
)
