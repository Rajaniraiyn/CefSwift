import Foundation

/// The architectures a bundle holds, and the CEF framework for them.
///
/// CEF publishes one distribution per architecture. A build for one
/// architecture downloads that one; a universal build downloads both and
/// merges their frameworks into a universal one, cached beside them, so
/// switching between the three reuses what is already there. Nothing is
/// fetched for an architecture the build does not target.
enum FrameworkArchitectures {
    /// Every architecture CEF ships for macOS, in the order bundles list them.
    static let all = ["arm64", "x86_64"]

    /// The CEF distribution's platform name for an architecture.
    static func platform(for architecture: String) -> String {
        architecture == "x86_64" ? "macosx64" : "macosarm64"
    }

    /// The architecture this tool runs as, which SwiftPM builds for by default.
    static var host: String { hostCefPlatform == "macosx64" ? "x86_64" : "arm64" }

    /// Parses architecture names: `arm64`, `x86_64`, or `universal` for
    /// both, from a list (cefapp.json's `architectures`) or a string
    /// separated by commas or spaces (`--architectures`, `CEF_ARCHITECTURES`,
    /// `ARCHS`). The result is in the order of ``all``, without repeats.
    static func parse(_ values: [String], source: String) throws -> [String] {
        let names = values.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
        var wanted = Set<String>()
        for name in names {
            switch name {
            case "universal": wanted.formUnion(all)
            case "arm64", "x86_64": wanted.insert(name)
            default:
                throw BundlingError(
                    "\(source): unknown architecture \"\(name)\". Use arm64, x86_64 or universal.")
            }
        }
        guard !wanted.isEmpty else {
            throw BundlingError("\(source) names no architecture. Use arm64, x86_64 or universal.")
        }
        return all.filter(wanted.contains)
    }

    /// `arm64`, `x86_64` or `universal`, for messages.
    static func describe(_ architectures: [String]) -> String {
        architectures == all ? "universal (arm64, x86_64)" : architectures.joined(separator: ", ")
    }

    // MARK: - The framework for a set of architectures

    /// The converted framework for `architectures`, downloading what the
    /// cache lacks: one architecture's distribution, or both and the
    /// universal framework merged from them.
    static func framework(
        for architectures: [String], manifest: CefManifest, flavor: String, downloader: Downloader
    ) throws -> URL {
        let frameworks = try architectures.map { architecture in
            (architecture, downloader.frameworkURL(in: try downloader.ensure(
                manifest: manifest, platform: platform(for: architecture), flavor: flavor)))
        }
        guard frameworks.count > 1 else { return frameworks[0].1 }
        let merged = downloader.distURL(cefVersion: manifest.cef, platform: "universal", flavor: flavor)
        let framework = merged.appendingPathComponent(FrameworkLayout.frameworkName + ".framework")
        if downloader.isPrepared(dist: merged) {
            print("[cef] Universal framework already prepared: \(merged.path)")
            return framework
        }
        let fm = FileManager.default
        let staging = merged.deletingLastPathComponent().appendingPathComponent(".tmp-\(merged.lastPathComponent)")
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: merged)
        print("[cef] Merging the arm64 and x86_64 frameworks into a universal one…")
        try merge(Dictionary(uniqueKeysWithValues: frameworks),
                  into: staging.appendingPathComponent(FrameworkLayout.frameworkName + ".framework"))
        try Data().write(to: staging.appendingPathComponent(".ok"))
        try fm.moveItem(at: staging, to: merged)
        print("[cef] Prepared \(merged.path)")
        return framework
    }

    /// Writes a universal framework at `destination` from the official
    /// frameworks of each architecture, in the versioned layout: each
    /// Mach-O file is `lipo -create` of the official files; a resource CEF
    /// names by architecture comes from its own distribution; every other
    /// file must be the same in each and is copied once.
    static func merge(_ frameworks: [String: URL], into destination: URL) throws {
        let fm = FileManager.default
        let architectures = all.filter { frameworks[$0] != nil }
        guard let first = architectures.first.flatMap({ frameworks[$0] }) else {
            throw BundlingError("No framework to merge.")
        }
        let listings = try architectures.map { try regularFiles(in: frameworks[$0]!.appendingPathComponent("Versions/A")) }
        let every = Set(listings.flatMap { $0 }).sorted()
        let version = destination.appendingPathComponent("Versions/A")
        for relative in every {
            let target = version.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sources = architectures.map { frameworks[$0]!.appendingPathComponent("Versions/A/\(relative)") }
            let present = zip(architectures, sources).filter { fm.fileExists(atPath: $0.1.path) }
            let name = (relative as NSString).lastPathComponent
            if let architecture = resourceArchitecture(name) {
                guard present.map(\.0) == [architecture] else {
                    throw BundlingError("\(relative) ships for \(present.map(\.0)), not only \(architecture); " +
                                        "the CEF layout changed.")
                }
                try fm.copyItem(at: present[0].1, to: target)
                continue
            }
            guard present.count == architectures.count else {
                throw BundlingError("\(relative) ships only for \(present.map(\.0).joined(separator: ", ")); " +
                                    "the CEF layout changed.")
            }
            if MachOFile(contentsOf: sources[0]) != nil {
                try Shell.runChecked("/usr/bin/xcrun", ["lipo", "-create"] + sources.map(\.path) + ["-output", target.path],
                                     hint: "Could not merge \(relative).")
            } else {
                guard sources.dropFirst().allSatisfy({ fm.contentsEqual(atPath: $0.path, andPath: sources[0].path) }) else {
                    throw BundlingError("\(relative) differs between the architectures and is not a Mach-O file; " +
                                        "the CEF layout changed.")
                }
                try fm.copyItem(at: sources[0], to: target)
            }
            if let permissions = try fm.attributesOfItem(atPath: sources[0].path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
        }
        try fm.createSymbolicLink(atPath: destination.appendingPathComponent("Versions/Current").path,
                                  withDestinationPath: "A")
        for entry in try fm.contentsOfDirectory(atPath: first.path) where entry != "Versions" {
            try fm.createSymbolicLink(atPath: destination.appendingPathComponent(entry).path,
                                      withDestinationPath: "Versions/Current/\(entry)")
        }
        try FrameworkLayout.validate(framework: destination)
    }

    /// The regular files under `directory`, relative to it.
    private static func regularFiles(in directory: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let base = directory.standardizedFileURL.path + "/"
        return (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)))?.isRegularFile == true }
            .map { String($0.standardizedFileURL.path.dropFirst(base.count)) }
    }

    /// A resource CEF ships once per architecture, named for it:
    /// `v8_context_snapshot.arm64.bin`, `webui_code_cache.x86_64.pak`.
    static func resourceArchitecture(_ fileName: String) -> String? {
        let parts = fileName.split(separator: ".")
        guard parts.count >= 3, ["bin", "pak"].contains(parts[parts.count - 1]) else { return nil }
        let architecture = String(parts[parts.count - 2])
        return all.contains(architecture) ? architecture : nil
    }
}
