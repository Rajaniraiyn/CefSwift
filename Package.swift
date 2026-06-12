// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CefSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CefKit", targets: ["CefKit"]),
        .library(name: "CefSwiftUI", targets: ["CefSwiftUI"]),
        .executable(name: "cef-helper", targets: ["cef-helper"]),
        .plugin(name: "CefPlugin", targets: ["CefPlugin"]),
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
        // NSApplication subclass conforming to CEF's CrAppControlProtocol.
        .target(
            name: "CCefAppKit",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Core Swift wrapper over the CEF C API.
        .target(
            name: "CefKit",
            dependencies: ["CCef", "CCefAppKit"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // First-class SwiftUI integration.
        .target(
            name: "CefSwiftUI",
            dependencies: ["CefKit"]
        ),
        // Helper-process executable, bundled five times by the CefPlugin.
        .executableTarget(
            name: "cef-helper",
            dependencies: ["CefKit"]
        ),
        // `swift package cef <download|bundle|info|clean>`
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
            )
        ),
        .testTarget(
            name: "CefKitTests",
            dependencies: ["CefKit", "CefSwiftUI"]
        ),
    ],
    cLanguageStandard: .c11
)
