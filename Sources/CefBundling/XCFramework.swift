import Foundation

/// The CEF framework as CefSwift's `ChromiumEmbeddedFramework` binary
/// target ships it: the official framework of both architectures in one
/// XCFramework, in the versioned bundle layout (Scripts/package-cef.py).
/// SwiftPM downloads and verifies it when it resolves the package, so
/// bundling reads it from SwiftPM's artifacts instead of downloading the
/// CEF distribution itself.
enum CefXCFramework {
    static let name = "ChromiumEmbeddedFramework.xcframework"
    static let targetName = "ChromiumEmbeddedFramework"

    /// Where SwiftPM keeps a remote binary target's artifact under a
    /// scratch directory (`.build`, or Xcode's `SourcePackages`).
    static func resolvedArtifact(underScratch scratch: URL) -> URL {
        scratch.appendingPathComponent("artifacts/cefswift/\(targetName)/\(name)")
    }

    /// Where `CEFSWIFT_LOCAL_FRAMEWORK=1` points the binary target, in a
    /// CefSwift checkout.
    static func localArtifact(inPackage package: URL) -> URL {
        package.appendingPathComponent(".cef/xcframework/\(name)")
    }

    /// `Chromium Embedded Framework.framework` in `xcframework`: its macOS
    /// library, from its Info.plist.
    static func framework(in xcframework: URL) throws -> URL {
        let info = try Plist.read(xcframework.appendingPathComponent("Info.plist"))
        let library = info["AvailableLibraries"]?.arrayValue?
            .compactMap(\.dictionaryValue)
            .first { $0["SupportedPlatform"]?.stringValue == "macos" && $0["SupportedPlatformVariant"] == nil }
        guard let identifier = library?["LibraryIdentifier"]?.stringValue,
              let path = library?["LibraryPath"]?.stringValue else {
            throw BundlingError(
                "\(xcframework.path) has no macOS library in its Info.plist. Resolve the package again " +
                "('swift package reset'), or rebuild it with Scripts/package-cef.py.")
        }
        let framework = xcframework.appendingPathComponent(identifier).appendingPathComponent(path)
        try FrameworkLayout.validate(framework: framework)
        return framework
    }

    /// A resource CEF ships once per architecture, named for it:
    /// `v8_context_snapshot.arm64.bin`, `webui_code_cache.x86_64.pak`.
    static func resourceArchitecture(_ fileName: String) -> String? {
        let parts = fileName.split(separator: ".")
        guard parts.count >= 3, ["bin", "pak"].contains(parts[parts.count - 1]) else { return nil }
        let architecture = String(parts[parts.count - 2])
        return ["arm64", "x86_64"].contains(architecture) ? architecture : nil
    }

    /// What ``thin(_:to:)`` removed.
    struct Thinning: Sendable, Equatable {
        var thinnedFiles = 0
        var removedBytes: Int64 = 0
    }

    /// Thins `framework`, a copy about to be signed, to `architectures`:
    /// each universal Mach-O file keeps only their slices, and the
    /// resources named for another architecture go. A framework of one
    /// architecture, as CEF's distributions have, is left as it is; one
    /// that lacks an architecture is left for the architecture check to
    /// report.
    @discardableResult
    static func thin(_ framework: URL, to architectures: [String]) throws -> Thinning {
        var result = Thinning()
        guard !architectures.isEmpty else { return result }
        let fm = FileManager.default
        let contents = framework.appendingPathComponent("Versions/A")
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = (fm.enumerator(at: contents, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isRegularFile == true }
        for file in files {
            if let architecture = resourceArchitecture(file.lastPathComponent) {
                guard !architectures.contains(architecture) else { continue }
                result.removedBytes += FrameworkTrim.size(of: file)
                try fm.removeItem(at: file)
                continue
            }
            guard let slices = MachOFile(contentsOf: file)?.architectures, slices.count > 1,
                  architectures.allSatisfy(slices.contains), slices.contains(where: { !architectures.contains($0) })
            else { continue }
            let before = Self.size(of: file)
            let thinned = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).thin")
            try? fm.removeItem(at: thinned)
            let selection = architectures.count == 1
                ? ["-thin", architectures[0]]
                : architectures.flatMap { ["-extract", $0] }
            try Shell.runChecked(
                "/usr/bin/xcrun", ["lipo", file.path] + selection + ["-output", thinned.path],
                hint: "Could not thin \(file.lastPathComponent) to \(architectures.joined(separator: ", ")).")
            let permissions = try fm.attributesOfItem(atPath: file.path)[.posixPermissions]
            try fm.removeItem(at: file)
            try fm.moveItem(at: thinned, to: file)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
            result.thinnedFiles += 1
            result.removedBytes += before - Self.size(of: file)
        }
        return result
    }

    /// A file's size, read afresh: a URL caches its resource values, and
    /// thinning replaces the file behind it.
    private static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
