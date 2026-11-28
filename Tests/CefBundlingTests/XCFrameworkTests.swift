import Foundation
import Testing
@testable import CefBundling

/// The CEF XCFramework of the `ChromiumEmbeddedFramework` binary target:
/// finding its framework, thinning it to the app's architecture, and where
/// the Xcode build phase looks for it.
@Suite struct XCFrameworkTests {
    static let frameworkName = "Chromium Embedded Framework"

    /// An XCFramework laid out as Scripts/package-cef.py makes it, with a
    /// universal framework binary and library when `universal`.
    private func makeXCFramework(universal: Bool) throws -> (root: URL, xcframework: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xcf-\(UUID().uuidString)")
        let xcframework = root.appendingPathComponent(CefXCFramework.name)
        let framework = xcframework.appendingPathComponent("macos-arm64_x86_64/\(Self.frameworkName).framework")
        let version = framework.appendingPathComponent("Versions/A")
        try fm.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: version.appendingPathComponent("Libraries"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("f.c")
        try Data("int cef_probe(void) { return 1; }\n".utf8).write(to: source)
        let archs = universal ? ["-arch", "arm64", "-arch", "x86_64"] : ["-arch", "arm64"]
        for output in [version.appendingPathComponent(Self.frameworkName),
                       version.appendingPathComponent("Libraries/libcef_sandbox.dylib")] {
            try Shell.runChecked("/usr/bin/xcrun", ["clang", "-dynamiclib"] + archs + [source.path, "-o", output.path],
                                 hint: "clang")
        }
        for arch in universal ? ["arm64", "x86_64"] : ["arm64"] {
            try Data(count: 1000).write(to: version.appendingPathComponent("Resources/v8_context_snapshot.\(arch).bin"))
            try Data(count: 300).write(to: version.appendingPathComponent("Resources/webui_code_cache.\(arch).pak"))
        }
        try Data(count: 10).write(to: version.appendingPathComponent("Resources/icudtl.dat"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        for entry in [Self.frameworkName, "Libraries", "Resources"] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(entry).path,
                                      withDestinationPath: "Versions/Current/\(entry)")
        }
        try Plist.write([
            "AvailableLibraries": .array([.dictionary([
                "BinaryPath": .string("\(Self.frameworkName).framework/Versions/A/\(Self.frameworkName)"),
                "LibraryIdentifier": .string("macos-arm64_x86_64"),
                "LibraryPath": .string("\(Self.frameworkName).framework"),
                "SupportedArchitectures": .array([.string("arm64"), .string("x86_64")]),
                "SupportedPlatform": .string("macos"),
            ])]),
            "CFBundlePackageType": .string("XFWK"),
            "XCFrameworkFormatVersion": .string("1.0"),
        ], to: xcframework.appendingPathComponent("Info.plist"))
        return (root, xcframework)
    }

    @Test func findsTheMacOSFramework() throws {
        let (root, xcframework) = try makeXCFramework(universal: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = try CefXCFramework.framework(in: xcframework)
        #expect(framework.lastPathComponent == "\(Self.frameworkName).framework")
        #expect(framework.deletingLastPathComponent().lastPathComponent == "macos-arm64_x86_64")
        try FileManager.default.removeItem(at: xcframework.appendingPathComponent("Info.plist"))
        #expect(throws: (any Error).self) { try CefXCFramework.framework(in: xcframework) }
    }

    @Test func namesPerArchitectureResources() {
        #expect(CefXCFramework.resourceArchitecture("v8_context_snapshot.arm64.bin") == "arm64")
        #expect(CefXCFramework.resourceArchitecture("webui_code_cache.x86_64.pak") == "x86_64")
        #expect(CefXCFramework.resourceArchitecture("resources.pak") == nil)
        #expect(CefXCFramework.resourceArchitecture("icudtl.dat") == nil)
        #expect(CefXCFramework.resourceArchitecture("x.arm64.dat") == nil)
    }

    @Test func thinsAUniversalFrameworkToTheAppsArchitecture() throws {
        let (root, xcframework) = try makeXCFramework(universal: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = try CefXCFramework.framework(in: xcframework)
        let version = framework.appendingPathComponent("Versions/A")
        let binary = version.appendingPathComponent(Self.frameworkName)
        #expect(MachOFile(contentsOf: binary)?.architectures.sorted() == ["arm64", "x86_64"])

        let result = try CefXCFramework.thin(framework, to: ["arm64"])
        #expect(result.thinnedFiles == 2)
        #expect(result.removedBytes > 1300)
        #expect(MachOFile(contentsOf: binary)?.architectures == ["arm64"])
        #expect(MachOFile(contentsOf: version.appendingPathComponent("Libraries/libcef_sandbox.dylib"))?.architectures == ["arm64"])
        let resources = Set(try FileManager.default.contentsOfDirectory(atPath: version.appendingPathComponent("Resources").path))
        #expect(resources == ["v8_context_snapshot.arm64.bin", "webui_code_cache.arm64.pak", "icudtl.dat"])
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))

        // Thinning again, or a framework of one architecture, changes nothing.
        #expect(try CefXCFramework.thin(framework, to: ["arm64"]) == .init())
    }

    @Test func leavesAFrameworkWithoutTheAppsArchitecture() throws {
        let (root, xcframework) = try makeXCFramework(universal: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = try CefXCFramework.framework(in: xcframework)
        // The x86_64 app is refused later by the architecture check; the
        // arm64 resources are not this method's to remove.
        let result = try CefXCFramework.thin(framework, to: ["x86_64"])
        #expect(result.thinnedFiles == 0)
        #expect(MachOFile(contentsOf: framework.appendingPathComponent(Self.frameworkName))?.architectures == ["arm64"])
    }

    @Test func theXcodePhaseFindsTheResolvedXCFramework() throws {
        let fm = FileManager.default
        let (root, xcframework) = try makeXCFramework(universal: false)
        defer { try? fm.removeItem(at: root) }
        // Xcode's layout: DerivedData/<Project>/Build/Products, beside
        // DerivedData/<Project>/SourcePackages/artifacts.
        let derived = root.appendingPathComponent("DerivedData/App")
        let products = derived.appendingPathComponent("Build/Products")
        let scratch = root.appendingPathComponent("scratch")
        let package = root.appendingPathComponent("CefSwift")
        var environment = [
            "CODESIGNING_FOLDER_PATH": products.appendingPathComponent("Debug/App.app").path,
            "TARGET_TEMP_DIR": root.appendingPathComponent("temp").path,
            "EXECUTABLE_NAME": "App", "ARCHS": "arm64",
            "BUILD_DIR": products.path,
            "CEFSWIFT_PACKAGE_DIR": package.path,
            "CEFSWIFT_SCRATCH_DIR": scratch.path,
        ]
        func found(_ environment: [String: String]) throws -> String? {
            let embed = XcodeEmbed(environment: environment)
            return embed.resolvedXCFramework(build: try embed.build())?.standardizedFileURL.path
        }
        #expect(try found(environment) == nil)

        // The copy SwiftPM resolved for the phase's own build of the helper.
        let inScratch = CefXCFramework.resolvedArtifact(underScratch: scratch)
        try fm.createDirectory(at: inScratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: xcframework, to: inScratch)
        #expect(try found(environment) == inScratch.standardizedFileURL.path)

        // Xcode's own copy comes first.
        let inSourcePackages = CefXCFramework.resolvedArtifact(underScratch: derived.appendingPathComponent("SourcePackages"))
        try fm.createDirectory(at: inSourcePackages.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: xcframework, to: inSourcePackages)
        #expect(try found(environment) == inSourcePackages.standardizedFileURL.path)

        // CEFSWIFT_LOCAL_FRAMEWORK=1: the checkout's, before both.
        let local = CefXCFramework.localArtifact(inPackage: package)
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: xcframework, to: local)
        #expect(try found(environment) == inSourcePackages.standardizedFileURL.path)
        environment["CEFSWIFT_LOCAL_FRAMEWORK"] = "1"
        #expect(try found(environment) == local.standardizedFileURL.path)

        // Another manifest or flavor downloads that distribution instead;
        // CEF_XCFRAMEWORK names one outright.
        #expect(try found(environment.merging(["CEF_FLAVOR": "standard"]) { $1 }) == nil)
        #expect(try found(environment.merging(["CEF_MANIFEST": "/x/CEF_VERSION.json"]) { $1 }) == nil)
        #expect(try found(environment.merging(["CEF_XCFRAMEWORK": "/x/F.xcframework"]) { $1 }) == "/x/F.xcframework")
    }
}
