// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CefSwiftExamples",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "CefSwift", path: ".."),
    ],
    targets: [
        // A complete tabbed browser: Chrome-style windows, SwiftUI toolbar.
        .executableTarget(
            name: "Browser",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
                "SystemEngine",
            ],
            exclude: ["cefapp.json", "Browser.entitlements", "Browser-Distribution.entitlements"]
        ),
        // The Browser example's WebKit tabs (SystemBrowser, SystemWebView):
        // pages in the system's WKWebView, which plays H.264/AAC and
        // FairPlay content Chromium in CefSwift does not. Not CEF; shows
        // how an app puts WebKit beside CefKit with its public API.
        .target(
            name: "SystemEngine",
            dependencies: [.product(name: "CefKit", package: "CefSwift")]
        ),
        // Embedding web content in a SwiftUI app.
        .executableTarget(
            name: "Showcase",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
        // One CefWebView on the `.embedded` configuration; the footprint
        // benchmark's lean case (Scripts/measure-footprint.py).
        .executableTarget(
            name: "Minimal",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
        // One page in one host with chosen CefSwift features: the
        // web-compatibility matrix (Scripts/compat-matrix.py).
        .executableTarget(
            name: "Compat",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
        // End-to-end checks against the real Chromium runtime; CI runs it.
        .executableTarget(
            name: "SelfTest",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
                "SystemEngine",
            ],
            exclude: ["cefapp.json"]
        ),
        // Unit tests of the Browser example's own logic.
        .testTarget(name: "BrowserTests", dependencies: ["Browser"]),
    ]
)
