import Foundation
import PackagePlugin

/// The CEF framework that SwiftPM fetched for CefSwift's
/// `ChromiumEmbeddedFramework` binary target: the official framework, both
/// architectures in one XCFramework, in the versioned bundle layout
/// (Scripts/package-cef.py). SwiftPM downloads and verifies it when it
/// resolves the package graph, so the plugin only reads it.
struct FrameworkArtifact {
    static let targetName = "ChromiumEmbeddedFramework"
    static let frameworkName = "Chromium Embedded Framework"

    /// The `.xcframework` directory.
    let xcframework: URL
    /// `Chromium Embedded Framework.framework` inside it.
    let framework: URL
    /// Where SwiftPM got it: a release URL, or a local path.
    let origin: String

    var binary: URL { framework.appendingPathComponent(Self.frameworkName) }

    /// Finds the binary target in `package` or its dependencies.
    static func find(in package: Package) throws -> FrameworkArtifact {
        var queue = [package]
        var seen = Set<String>()
        while !queue.isEmpty {
            let package = queue.removeFirst()
            guard seen.insert(package.id).inserted else { continue }
            if let target = package.targets.lazy.compactMap({ $0 as? BinaryArtifactTarget })
                .first(where: { $0.name == targetName }) {
                let origin: String
                switch target.origin {
                case .local: origin = "local, \(target.artifactURL.path)"
                case .remote(let url): origin = url
                @unknown default: origin = target.artifactURL.path
                }
                return try FrameworkArtifact(xcframework: target.artifactURL, origin: origin)
            }
            queue += package.dependencies.map(\.package)
        }
        throw CefPluginError(
            "No package in the graph of '\(package.displayName)' declares the \(targetName) binary target. " +
            "Run the command from a package that depends on CefSwift.")
    }

    /// Reads the XCFramework's Info.plist and picks its macOS library.
    init(xcframework: URL, origin: String) throws {
        self.xcframework = xcframework
        self.origin = origin
        let info = try Plist.read(xcframework.appendingPathComponent("Info.plist"))
        guard case .array(let libraries)? = info["AvailableLibraries"],
              let library = libraries.compactMap({ value -> [String: PlistValue]? in
                  if case .dictionary(let dictionary) = value { return dictionary } else { return nil }
              }).first(where: { $0["SupportedPlatform"]?.stringValue == "macos" && $0["SupportedPlatformVariant"] == nil }),
              let identifier = library["LibraryIdentifier"]?.stringValue,
              let path = library["LibraryPath"]?.stringValue
        else {
            throw CefPluginError("\(xcframework.path) has no macOS library in its Info.plist. Rebuild it with " +
                                 "Scripts/package-cef.py, or resolve the package again.")
        }
        framework = xcframework.appendingPathComponent(identifier).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: binary.path),
              FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/A/Libraries").path)
        else {
            throw CefPluginError(
                "\(framework.path) is incomplete: it needs \(Self.frameworkName) and Versions/A/Libraries. " +
                "Rebuild it with Scripts/package-cef.py, or run 'swift package reset' and resolve again.")
        }
    }

    /// The architectures of a Mach-O file, as `lipo -archs` prints them.
    static func architectures(of file: URL) -> Set<String> {
        guard let result = try? Shell.run("/usr/bin/xcrun", ["lipo", "-archs", file.path]), result.exitCode == 0
        else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// Whether `executable` loads the framework at launch.
    static func isLinked(by executable: URL) -> Bool {
        guard let result = try? Shell.run("/usr/bin/xcrun", ["otool", "-L", executable.path]), result.exitCode == 0
        else { return false }
        return result.stdout.contains("/\(frameworkName).framework/")
    }
}
