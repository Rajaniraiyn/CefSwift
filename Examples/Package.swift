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
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
        // Embedding web content in a SwiftUI app.
        .executableTarget(
            name: "Showcase",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
        // End-to-end checks against the real Chromium runtime; CI runs it.
        .executableTarget(
            name: "SelfTest",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"]
        ),
    ]
)
