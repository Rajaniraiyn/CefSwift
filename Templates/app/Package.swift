// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v14)],
    dependencies: [
        __CEFSWIFT_PACKAGE__,
    ],
    targets: [
        .executableTarget(
            name: "__NAME__",
            dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")],
            exclude: ["cefapp.json"],
            // The app's web content, served at app://content/.
            resources: [.copy("Web")]
        ),
    ]
)
