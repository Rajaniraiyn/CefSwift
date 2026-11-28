// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v15)],
    dependencies: [
        __CEFSWIFT_PACKAGE__,
    ],
    targets: [
        // A tabbed browser: Chromium's own windows and tabs under a SwiftUI
        // tab rail and toolbar, composed of features (Sources/__NAME__/Features)
        // on a small core (Sources/__NAME__/Core).
        .executableTarget(
            name: "__NAME__",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
                .product(name: "CefChromium", package: "CefSwift"),
            ],
            exclude: ["cefapp.json", "Browser.entitlements"]
        ),
        // The browser's own logic: typed addresses, the tab rail's
        // arithmetic and the Memory Saver policy.
        .testTarget(name: "__NAME__Tests", dependencies: ["__NAME__"]),
    ]
)
