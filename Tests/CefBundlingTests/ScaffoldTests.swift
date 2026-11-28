import Foundation
import Testing
@testable import CefBundling

/// `cefswift new`: its options, the dependency it writes, and each
/// template generated from this checkout. Building and running what it
/// generates is CI's (the templates job).
struct ScaffoldTests {
    /// The checkout: the nearest ancestor of this file with `Templates/`.
    static let root: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Templates").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }()

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func scaffold(_ arguments: [String], in directory: URL) throws -> Scaffold {
        try Scaffold(arguments: arguments + ["--cefswift-root", Self.root?.path ?? "/nonexistent"],
                     workingDirectory: directory, toolLocation: nil)
    }

    @Test func displayNamesSplitWords() {
        #expect(Scaffold.words("MyBrowser") == "My Browser")
        #expect(Scaffold.words("Web3Shell") == "Web3 Shell")
        #expect(Scaffold.words("my_app") == "my app")
        #expect(Scaffold.words("URLViewer") == "URLViewer")
    }

    @Test(.enabled(if: root != nil, "Needs the repository checkout."))
    func rejectsNamesThatAreNotIdentifiersAndUnknownTemplates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: BundlingError.self) { try scaffold(["My Browser"], in: directory) }
        #expect(throws: BundlingError.self) { try scaffold(["1Browser"], in: directory) }
        #expect(throws: BundlingError.self) { try scaffold(["Browser", "--template", "kiosk"], in: directory) }
        #expect(throws: BundlingError.self) {
            try scaffold(["Browser", "--cefswift-version", "1.0.0", "--cefswift-branch", "main"], in: directory)
        }
    }

    @Test(.enabled(if: root != nil, "Needs the repository checkout."))
    func writesTheDependencyItIsGiven() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = try scaffold(["App", "--cefswift-version", "v0.3.0"], in: directory)
        #expect(version.packageDependency
            == #".package(url: "https://github.com/Rajaniraiyn/CefSwift", .upToNextMinor(from: "0.3.0"))"#)
        let branch = try scaffold(["App", "--cefswift-branch", "main"], in: directory)
        #expect(branch.packageDependency == #".package(url: "https://github.com/Rajaniraiyn/CefSwift", branch: "main")"#)
        let path = try scaffold(["App", "--cefswift-path", "../CefSwift"], in: directory)
        #expect(path.dependency == .path(directory.deletingLastPathComponent().appendingPathComponent("CefSwift").path))
        #expect(path.packageDependency.hasPrefix(#".package(name: "CefSwift", path: ""#))
        #expect(path.output == directory.appendingPathComponent("App").standardizedFileURL)
        #expect(path.bundleIdentifier == "com.example.app")
    }

    @Test(.enabled(if: root != nil, "Needs the repository checkout."), arguments: Scaffold.templates)
    func generatesEachTemplate(_ template: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scaffold = try scaffold(
            ["MyApp", "--template", template, "--cefswift-version", "0.3.0", "--xcode", "--bundle-id", "com.example.my"],
            in: directory)
        let files = try scaffold.run()
        let output = scaffold.output
        for expected in ["Package.swift", ".gitignore", "README.md", "Sources/MyApp/cefapp.json",
                         "MyApp.xcodeproj/project.pbxproj", "CefSwift.xcconfig"] {
            #expect(files.contains(expected), "\(expected) is missing from the \(template) template")
        }
        // No placeholder is left, in contents or paths.
        for file in files {
            #expect(!file.contains("__"), "\(file) keeps a placeholder in its path")
            let text = try String(contentsOf: output.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("__NAME__") && !text.contains("__DISPLAY_NAME__") && !text.contains("__BUNDLE_ID__")
                    && !text.contains("__CEFSWIFT_PACKAGE__"), "\(file) keeps a placeholder")
        }
        let manifest = try String(contentsOf: output.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#"name: "MyApp""#))
        #expect(manifest.contains(#".upToNextMinor(from: "0.3.0")"#))
        let gitignore = try String(contentsOf: output.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(gitignore.contains(".cef/") && gitignore.contains("dist/"))
        let config = try CefAppConfig.load(near: output.appendingPathComponent("Sources/MyApp"), explicit: nil)
        #expect(config?.bundleIdentifier == "com.example.my")
        #expect(config?.displayName == "My App")
        let project = try String(contentsOf: output.appendingPathComponent("MyApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(project.contains("XCRemoteSwiftPackageReference \"CefSwift\""))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.example.my;"))
        #expect(project.contains("path = Sources/MyApp;"))
        #expect(project.components(separatedBy: "{").count == project.components(separatedBy: "}").count)
        // A second run into the same directory refuses to overwrite it.
        #expect(throws: BundlingError.self) { try scaffold.run() }
    }

    @Test(.enabled(if: root != nil, "Needs the repository checkout."))
    func theBrowserTemplateIsTheExamplesCode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scaffold = try scaffold(["Surf", "--display-name", "Surf Browser", "--cefswift-path", "/tmp/CefSwift"],
                                    in: directory)
        try scaffold.run()
        let root = try #require(Self.root)
        let rail = "Core/TabRail/TabRailLogic.swift"
        #expect(try Data(contentsOf: scaffold.output.appendingPathComponent("Sources/Surf/\(rail)"))
            == Data(contentsOf: root.appendingPathComponent("Examples/Sources/Browser/\(rail)")))
        let scene = try String(contentsOf: scaffold.output.appendingPathComponent("Sources/Surf/Core/BrowserScene.swift"),
                               encoding: .utf8)
        #expect(scene.contains(#"configuration.productName = "Surf Browser""#))
        let tests = try String(contentsOf: scaffold.output.appendingPathComponent("Tests/SurfTests/TabRailTests.swift"),
                               encoding: .utf8)
        #expect(tests.contains("@testable import Surf"))
        let project = XcodeProject(scaffold: scaffold, manifest: try JSONDecoder().decode(
            Scaffold.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("Templates/browser/template.json"))))
        #expect(project.text.contains("XCLocalSwiftPackageReference \"CefSwift\""))
        #expect(project.text.contains("tmp/CefSwift;"))
        #expect(project.text.contains("productName = CefChromium;"))
        #expect(project.text.contains("Browser.entitlements,"))
    }

    @Test func relativePaths() {
        #expect(XcodeProject.relative("/a/b/CefSwift", from: "/a/b/App") == "../CefSwift")
        #expect(XcodeProject.relative("/a/b/App/Vendor/CefSwift", from: "/a/b/App") == "Vendor/CefSwift")
        #expect(XcodeProject.relative("/a/b", from: "/a/b") == ".")
    }
}
