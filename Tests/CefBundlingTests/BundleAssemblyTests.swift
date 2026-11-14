import Foundation
import Testing
@testable import CefBundling

// What `cef bundle` collects from a SwiftPM build and how it checks the
// assembled app: Mach-O parsing, the libraries and resource bundles of a
// product, run paths into the build directory, and staged replacement.

/// A minimal 64-bit Mach-O image with the load commands bundling reads.
private func machO(
    cpuType: UInt32 = 0x0100_000C, minos: UInt32 = 0x000E_0000, installName: String? = nil,
    libraries: [String] = [], runPaths: [String] = []
) -> Data {
    func word(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    func stringCommand(_ command: UInt32, _ string: String, header: [UInt8]) -> [UInt8] {
        var bytes = Array(string.utf8) + [0]
        while (8 + header.count + bytes.count) % 8 != 0 { bytes.append(0) }
        let size = UInt32(8 + header.count + bytes.count)
        return word(command) + word(size) + header + bytes
    }
    var commands: [[UInt8]] = [word(0x32) + word(24) + word(1) + word(minos) + word(0) + word(0)]
    if let installName {
        commands.append(stringCommand(0xD, installName, header: word(24) + word(0) + word(0) + word(0)))
    }
    for library in libraries {
        commands.append(stringCommand(0xC, library, header: word(24) + word(0) + word(0) + word(0)))
    }
    for path in runPaths {
        commands.append(stringCommand(0x8000_001C, path, header: word(12)))
    }
    let body = commands.flatMap { $0 }
    let header = word(0xFEED_FACF) + word(cpuType) + word(0) + word(installName == nil ? 2 : 6)
        + word(UInt32(commands.count)) + word(UInt32(body.count)) + word(0) + word(0)
    return Data(header + body)
}

/// A universal file holding `slices`.
private func universal(_ slices: [(cpuType: UInt32, data: Data)]) -> Data {
    func big(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    var header = big(0xCAFE_BABE) + big(UInt32(slices.count))
    var offset = 0x1000
    var payload = Data()
    for slice in slices {
        header += big(slice.cpuType) + big(0) + big(UInt32(offset)) + big(UInt32(slice.data.count)) + big(12)
        payload.append(slice.data)
        offset += slice.data.count
    }
    var data = Data(header)
    data.append(Data(count: 0x1000 - data.count))
    data.append(payload)
    return data
}

private let products = URL(fileURLWithPath: "/build/out/Products/Release")
private let executable = products.appendingPathComponent("Hello")

@Suite struct MachOTests {
    @Test func readsTheLoadCommandsOfAThinImage() throws {
        let file = try #require(MachOFile(data: machO(
            minos: 0x000E_0100, libraries: ["@rpath/libGreeter.dylib", "/usr/lib/libSystem.B.dylib"],
            runPaths: ["/usr/lib/swift", "@loader_path"])))
        #expect(file.architectures == ["arm64"])
        let slice = try #require(file.slices.first)
        #expect(slice.minimumSystemVersion == "14.1")
        #expect(slice.loadedLibraries == ["@rpath/libGreeter.dylib", "/usr/lib/libSystem.B.dylib"])
        #expect(slice.runPaths == ["/usr/lib/swift", "@loader_path"])
        #expect(slice.installName == nil)

        let library = try #require(MachOFile(data: machO(installName: "@rpath/libGreeter.dylib")))
        #expect(library.slices.first?.installName == "@rpath/libGreeter.dylib")
    }

    @Test func readsEachSliceOfAUniversalFile() throws {
        let data = universal([
            (0x0100_0007, machO(cpuType: 0x0100_0007)),
            (0x0100_000C, machO(cpuType: 0x0100_000C, minos: 0x000F_0000)),
        ])
        let file = try #require(MachOFile(data: data))
        #expect(file.architectures == ["x86_64", "arm64"])
        #expect(file.slices.last?.minimumSystemVersion == "15.0")
    }

    @Test func readsASystemBinary() throws {
        let file = try #require(MachOFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!file.architectures.isEmpty)
        #expect(file.slices.allSatisfy { $0.loadedLibraries.contains("/usr/lib/libSystem.B.dylib") })
    }

    @Test func rejectsOtherFiles() {
        #expect(MachOFile(data: Data("#!/bin/sh\n".utf8)) == nil)
        #expect(MachOFile(data: Data()) == nil)
        // A Java class file shares the universal magic number.
        #expect(MachOFile(data: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41])) == nil)
    }
}

@Suite struct BuiltProductTests {
    /// A build directory: each path's Mach-O image, or a directory.
    private struct BuildDirectory {
        var images: [String: Data] = [:]
        var directories: Set<String> = []

        func read(_ url: URL) -> MachOFile? { images[url.standardizedFileURL.path].flatMap(MachOFile.init(data:)) }
        func exists(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return images[path] != nil || directories.contains(path)
        }
    }

    private let buildRunPath = "/build/out/Products/Release/PackageFrameworks"

    @Test func collectsLibrariesTransitivelyAndResourceBundles() throws {
        var build = BuildDirectory()
        build.images[executable.path] = machO(
            minos: 0x000E_0000,
            libraries: [
                "@rpath/libGreeter.dylib", "@rpath/Charts.framework/Versions/A/Charts",
                "@rpath/libswift_Concurrency.dylib", "/usr/lib/libSystem.B.dylib",
                "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework",
            ],
            runPaths: ["/usr/lib/swift", "@loader_path", buildRunPath])
        build.images[products.appendingPathComponent("libGreeter.dylib").path] = machO(
            installName: "@rpath/libGreeter.dylib", libraries: ["@rpath/libStrings.dylib"], runPaths: ["@loader_path"])
        build.images["\(buildRunPath)/libStrings.dylib"] = machO(installName: "@rpath/libStrings.dylib")
        build.images["\(buildRunPath)/Charts.framework/Versions/A/Charts"] = machO(
            installName: "@rpath/Charts.framework/Versions/A/Charts", libraries: ["@rpath/libGreeter.dylib"])
        build.directories = [
            products.appendingPathComponent("App_Hello.bundle").path,
            products.appendingPathComponent("Greeter_GreeterKit.bundle").path,
        ]

        let product = try BuiltProduct.collect(
            executable: executable, resourceBundleNames: ["App_Hello.bundle", "Greeter_GreeterKit.bundle"],
            readMachO: build.read, fileExists: build.exists)
        #expect(product.architectures == ["arm64"])
        #expect(product.deploymentTarget == "14.0")
        #expect(product.resourceBundles.map(\.lastPathComponent) == ["App_Hello.bundle", "Greeter_GreeterKit.bundle"])
        // Each once, frameworks as their directory; the Swift runtime and
        // the CEF framework are not copied from the build.
        #expect(product.libraries.map(\.path) == [
            products.appendingPathComponent("libGreeter.dylib").path,
            "\(buildRunPath)/Charts.framework",
            "\(buildRunPath)/libStrings.dylib",
        ])
    }

    @Test func aMissingResourceBundleIsAnError() {
        var build = BuildDirectory()
        build.images[executable.path] = machO()
        #expect(throws: BundlingError.self) {
            try BuiltProduct.collect(
                executable: executable, resourceBundleNames: ["App_Hello.bundle"],
                readMachO: build.read, fileExists: build.exists)
        }
    }

    @Test func aLibraryNotInTheBuildIsAnError() {
        var build = BuildDirectory()
        build.images[executable.path] = machO(libraries: ["@rpath/libMissing.dylib"], runPaths: ["@loader_path"])
        do {
            _ = try BuiltProduct.collect(
                executable: executable, resourceBundleNames: [], readMachO: build.read, fileExists: build.exists)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("@rpath/libMissing.dylib"))
        }
    }

    @Test func buildMachineRunPathsAreTheAbsoluteOnesOutsideMacOS() throws {
        let file = try #require(MachOFile(data: machO(runPaths: [
            "/usr/lib/swift", "@loader_path", buildRunPath,
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx",
            "@executable_path/../Frameworks",
        ])))
        #expect(BuiltProduct.buildMachineRunPaths(of: file) == [
            buildRunPath,
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx",
        ])
    }
}

@Suite struct LinkageTests {
    private let app = URL(fileURLWithPath: "/dist/Hello.app")
    private var main: URL { app.appendingPathComponent("Contents/MacOS/Hello") }
    private var frameworks: URL { app.appendingPathComponent("Contents/Frameworks") }
    private var helper: URL { frameworks.appendingPathComponent("Hello Helper.app/Contents/MacOS/Hello Helper") }
    private let cef = "Chromium Embedded Framework.framework/Chromium Embedded Framework"

    private func problems(_ images: [URL: Data], files: Set<URL> = []) -> [String] {
        let paths = Dictionary(uniqueKeysWithValues: images.map { ($0.key.standardizedFileURL.path, $0.value) })
        let existing = Set(files.map(\.standardizedFileURL.path)).union(paths.keys)
        return Linkage.problems(
            binaries: Array(images.keys).sorted { $0.path < $1.path }, executable: main, app: app,
            readMachO: { paths[$0.standardizedFileURL.path].flatMap(MachOFile.init(data:)) },
            fileExists: { existing.contains($0.standardizedFileURL.path) })
    }

    @Test func aBundledAppHasNoProblems() {
        let found = problems([
            main: machO(
                libraries: ["@rpath/libGreeter.dylib", "@executable_path/../Frameworks/\(cef)",
                            "@rpath/libswiftCore.dylib", "/usr/lib/libSystem.B.dylib"],
                runPaths: ["/usr/lib/swift", "@loader_path", "@executable_path/../Frameworks"]),
            frameworks.appendingPathComponent("libGreeter.dylib"): machO(
                installName: "@rpath/libGreeter.dylib", runPaths: ["@loader_path"]),
            // A helper's @executable_path is its own executable.
            helper: machO(libraries: ["@executable_path/../../../\(cef)"]),
        ], files: [frameworks.appendingPathComponent(cef)])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func findsWhatOnlyWorksOnTheBuildMachine() {
        let found = problems([
            main: machO(
                libraries: ["@rpath/libGreeter.dylib", "/Users/me/lib/libLocal.dylib"],
                runPaths: ["@loader_path", "/build/out/Products/Release"]),
            helper: machO(cpuType: 0x0100_0007),
        ])
        #expect(found.contains { $0.contains("searches /build/out/Products/Release") })
        #expect(found.contains { $0.contains("loads @rpath/libGreeter.dylib, which is not in the bundle") })
        #expect(found.contains { $0.contains("loads /Users/me/lib/libLocal.dylib, outside the bundle") })
        #expect(found.contains { $0.hasPrefix("Contents/Frameworks/Hello Helper.app") && $0.contains("x86_64, not arm64") })
    }
}

@Suite struct StagedDirectoryTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func replacesTheDestinationOnlyWhenTheBuildSucceeds() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Hello.app")

        try StagedDirectory.replace(app) { staged in
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("one".utf8).write(to: staged.appendingPathComponent("version"))
        }
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "one")

        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try StagedDirectory.replace(app) { staged in
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("half".utf8).write(to: staged.appendingPathComponent("version"))
                throw Failure()
            }
        }
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "one")

        try StagedDirectory.replace(app) { staged in
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("two".utf8).write(to: staged.appendingPathComponent("version"))
        }
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "two")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Hello.app"])
    }
}
