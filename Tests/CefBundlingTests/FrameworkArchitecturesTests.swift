import Foundation
import Testing
@testable import CefBundling

/// Which architectures a bundle holds: parsing them, and the universal
/// framework merged from two architectures' distributions.
@Suite struct FrameworkArchitecturesTests {
    static let frameworkName = "Chromium Embedded Framework"

    @Test func parsesNamesListsAndUniversal() throws {
        #expect(try FrameworkArchitectures.parse(["arm64"], source: "t") == ["arm64"])
        #expect(try FrameworkArchitectures.parse(["universal"], source: "t") == ["arm64", "x86_64"])
        #expect(try FrameworkArchitectures.parse(["x86_64 arm64"], source: "ARCHS") == ["arm64", "x86_64"])
        #expect(try FrameworkArchitectures.parse(["x86_64,arm64,arm64"], source: "t") == ["arm64", "x86_64"])
        #expect(try FrameworkArchitectures.parse(["x86_64"], source: "t") == ["x86_64"])
        let unknown = #expect(throws: BundlingError.self) { try FrameworkArchitectures.parse(["arm64e"], source: "ARCHS") }
        #expect(unknown?.message.contains("ARCHS: unknown architecture \"arm64e\"") == true)
        #expect(throws: BundlingError.self) { try FrameworkArchitectures.parse([], source: "t") }
        #expect(FrameworkArchitectures.platform(for: "x86_64") == "macosx64")
        #expect(FrameworkArchitectures.platform(for: "arm64") == "macosarm64")
    }

    @Test func cefappJSONTakesArchitectures() throws {
        let source = URL(fileURLWithPath: "/tmp/cefapp.json")
        let config = try CefAppConfig.decode(Data(#"{"architectures": ["universal"]}"#.utf8), source: source)
        #expect(config.architectures == ["universal"])
        #expect(throws: BundlingError.self) {
            try CefAppConfig.decode(Data(#"{"architectures": ["ppc"]}"#.utf8), source: source)
        }
    }

    @Test func namesPerArchitectureResources() {
        #expect(FrameworkArchitectures.resourceArchitecture("v8_context_snapshot.arm64.bin") == "arm64")
        #expect(FrameworkArchitectures.resourceArchitecture("webui_code_cache.x86_64.pak") == "x86_64")
        #expect(FrameworkArchitectures.resourceArchitecture("resources.pak") == nil)
        #expect(FrameworkArchitectures.resourceArchitecture("x.arm64.dat") == nil)
    }

    /// One architecture's framework as `Downloader` prepares it: versioned,
    /// with a real Mach-O binary and library, shared and per-architecture
    /// resources.
    private func makeFramework(_ architecture: String, in root: URL, shared: String = "icu") throws -> URL {
        let fm = FileManager.default
        let framework = root.appendingPathComponent("\(architecture)/\(Self.frameworkName).framework")
        let version = framework.appendingPathComponent("Versions/A")
        try fm.createDirectory(at: version.appendingPathComponent("Resources/en.lproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: version.appendingPathComponent("Libraries"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("f.c")
        try Data("int cef_probe(void) { return 1; }\n".utf8).write(to: source)
        for output in [version.appendingPathComponent(Self.frameworkName),
                       version.appendingPathComponent("Libraries/libcef_sandbox.dylib")] {
            try Shell.runChecked("/usr/bin/xcrun", ["clang", "-dynamiclib", "-arch", architecture, source.path,
                                                    "-o", output.path], hint: "clang")
        }
        try Data(architecture.utf8).write(to: version.appendingPathComponent("Resources/v8_context_snapshot.\(architecture).bin"))
        try Data(architecture.utf8).write(to: version.appendingPathComponent("Resources/webui_code_cache.\(architecture).pak"))
        try Data(shared.utf8).write(to: version.appendingPathComponent("Resources/icudtl.dat"))
        try Data("en".utf8).write(to: version.appendingPathComponent("Resources/en.lproj/locale.pak"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        for entry in [Self.frameworkName, "Libraries", "Resources"] {
            try fm.createSymbolicLink(atPath: framework.appendingPathComponent(entry).path,
                                      withDestinationPath: "Versions/Current/\(entry)")
        }
        return framework
    }

    @Test func mergesTwoArchitecturesIntoAUniversalFramework() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let frameworks = ["arm64": try makeFramework("arm64", in: root), "x86_64": try makeFramework("x86_64", in: root)]
        let merged = root.appendingPathComponent("universal/\(Self.frameworkName).framework")
        try FrameworkArchitectures.merge(frameworks, into: merged)

        let version = merged.appendingPathComponent("Versions/A")
        #expect(MachOFile(contentsOf: merged.appendingPathComponent(Self.frameworkName))?.architectures.sorted() == ["arm64", "x86_64"])
        #expect(MachOFile(contentsOf: version.appendingPathComponent("Libraries/libcef_sandbox.dylib"))?.architectures.sorted()
                == ["arm64", "x86_64"])
        let resources = Set(try fm.contentsOfDirectory(atPath: version.appendingPathComponent("Resources").path))
        #expect(resources == ["v8_context_snapshot.arm64.bin", "v8_context_snapshot.x86_64.bin",
                              "webui_code_cache.arm64.pak", "webui_code_cache.x86_64.pak", "icudtl.dat", "en.lproj"])
        #expect(try String(contentsOf: version.appendingPathComponent("Resources/v8_context_snapshot.x86_64.bin"),
                           encoding: .utf8) == "x86_64")
        #expect(try fm.destinationOfSymbolicLink(atPath: merged.appendingPathComponent("Versions/Current").path) == "A")
        #expect(try fm.destinationOfSymbolicLink(atPath: merged.appendingPathComponent("Resources").path)
                == "Versions/Current/Resources")
        #expect(fm.isExecutableFile(atPath: version.appendingPathComponent(Self.frameworkName).path))
    }

    @Test func refusesDistributionsThatDifferBeyondTheirBinaries() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let frameworks = ["arm64": try makeFramework("arm64", in: root),
                          "x86_64": try makeFramework("x86_64", in: root, shared: "other")]
        let error = #expect(throws: BundlingError.self) {
            try FrameworkArchitectures.merge(frameworks, into: root.appendingPathComponent("u/F.framework"))
        }
        #expect(error?.message.contains("icudtl.dat differs between the architectures") == true)
    }

    /// The download cache: a universal framework is merged once and reused,
    /// and each architecture's distribution stays for builds of one.
    @Test func reusesTheCacheAcrossArchitectures() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let downloader = Downloader(cacheRoot: root)
        let manifest = try JSONDecoder().decode(CefManifest.self, from: Data("""
            {"cef": "1.0.0+g0+chromium-1", "chromium": "1", "channel": "stable", "platforms": {
              "macosarm64": {"minimal": {"name": "a.tar.bz2", "sha1": "0", "size": 1}},
              "macosx64": {"minimal": {"name": "x.tar.bz2", "sha1": "0", "size": 1}}}}
            """.utf8))
        // Distributions already prepared, as Downloader leaves them.
        for architecture in ["arm64", "x86_64"] {
            let dist = downloader.distURL(cefVersion: manifest.cef, platform: FrameworkArchitectures.platform(for: architecture),
                                          flavor: "minimal")
            let framework = try makeFramework(architecture, in: root.appendingPathComponent("built"))
            try fm.createDirectory(at: dist.appendingPathComponent("Release"), withIntermediateDirectories: true)
            try fm.moveItem(at: framework, to: downloader.frameworkURL(in: dist))
            try Data().write(to: dist.appendingPathComponent(".ok"))
        }
        let arm64 = try FrameworkArchitectures.framework(for: ["arm64"], manifest: manifest, flavor: "minimal",
                                                          downloader: downloader)
        #expect(arm64.path.contains("_macosarm64_minimal/Release/"))
        let universal = try FrameworkArchitectures.framework(for: ["arm64", "x86_64"], manifest: manifest,
                                                              flavor: "minimal", downloader: downloader)
        #expect(universal.path.contains("_universal_minimal/"))
        let mergedAt = try fm.attributesOfItem(atPath: universal.appendingPathComponent("Versions/A/\(Self.frameworkName)").path)[.modificationDate] as? Date
        let again = try FrameworkArchitectures.framework(for: ["arm64", "x86_64"], manifest: manifest,
                                                          flavor: "minimal", downloader: downloader)
        let againAt = try fm.attributesOfItem(atPath: again.appendingPathComponent("Versions/A/\(Self.frameworkName)").path)[.modificationDate] as? Date
        #expect(again.path == universal.path && againAt == mergedAt)
        #expect(MachOFile(contentsOf: arm64.appendingPathComponent(Self.frameworkName))?.architectures == ["arm64"])
    }
}
