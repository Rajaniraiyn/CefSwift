// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CefSwiftExamples",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Browser", targets: ["Browser"]),
        .executable(name: "Gallery", targets: ["Gallery"]),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        // Arc-class mini browser — the flagship example.
        .executableTarget(
            name: "Browser",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
            ],
            exclude: ["cefapp.json"]
        ),
        // Embedding showcase — native SwiftUI dashboard mixing web cards and controls.
        .executableTarget(
            name: "Gallery",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
            ],
            exclude: ["cefapp.json"]
        ),
    ]
)
