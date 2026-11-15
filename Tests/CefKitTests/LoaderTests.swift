import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Tests of the framework loader. Those that need the framework run only
/// when `CEF_FRAMEWORK_PATH` points at it, and load it in `CefLoaderProbe`,
/// a process of their own: none load it into the test process, nor call
/// `cef_initialize`, which would take it over.
///
/// The framework's initializers make PartitionAlloc the default malloc
/// zone by unregistering the system zone and registering it again. Freed
/// in between, by any thread, a pointer the system zone allocated traps
/// in Chromium's `free`; the test process runs other tests on many
/// threads, and loading the framework there crashed it now and then.
@Suite(.serialized)
struct LoaderTests {
    /// The framework binary named by `CEF_FRAMEWORK_PATH`, which may point at
    /// the binary or at the `.framework` directory.
    static func frameworkBinaryPath() -> String? {
        guard var path = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !path.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            path += "/Chromium Embedded Framework"
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static var frameworkAvailable: Bool { frameworkBinaryPath() != nil }

    /// `CefLoaderProbe`, which SwiftPM builds beside the test bundle.
    static func probeURL() throws -> URL {
        let bundle = Bundle(for: ProbeLocator.self).bundleURL
        let probe = bundle.deletingLastPathComponent().appendingPathComponent("CefLoaderProbe")
        try #require(
            FileManager.default.isExecutableFile(atPath: probe.path),
            "CefLoaderProbe is not built beside \(bundle.path); run swift build --build-tests")
        return probe
    }

    /// Runs the probe; how it ended and what it wrote to standard error.
    static func runProbe(_ mode: String, framework: String) throws
        -> (reason: Process.TerminationReason, status: Int32, errors: String) {
        let process = Process()
        process.executableURL = try probeURL()
        process.arguments = [mode, framework]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test(.enabled(if: LoaderTests.frameworkAvailable, "CEF framework not present; set CEF_FRAMEWORK_PATH to run loader tests."))
    func loadsAndVerifiesRealFramework() throws {
        let path = try #require(Self.frameworkBinaryPath())
        // Loads it, checks its exports, the API hash and version the
        // headers pin, and a string conversion the framework implements.
        let run = try Self.runProbe("check", framework: path)
        #expect(run.reason == .exit && run.status == 0, "\(run.errors)")
        #expect(ccef_is_framework_loaded() == 0)
    }

    /// Why the probe exists: a free inside the window in which the
    /// framework's initializer has unregistered the system zone traps, as
    /// another test's thread did. The probe frees at exactly that point.
    @Test(.enabled(if: LoaderTests.frameworkAvailable, "CEF framework not present; set CEF_FRAMEWORK_PATH to run loader tests."))
    func aFreeWhileTheFrameworkSwapsTheDefaultZoneTraps() throws {
        let path = try #require(Self.frameworkBinaryPath())
        let run = try Self.runProbe("free-during-load", framework: path)
        #expect(run.reason == .uncaughtSignal && run.status == SIGTRAP, "\(run.status): \(run.errors)")
    }

    @Test func loadFailureReportsError() {
        guard ccef_is_framework_loaded() == 0 else { return }
        #expect(ccef_load_framework("/nonexistent/path/to/cef") == 0)
        let message = String(cString: ccef_loader_error())
        #expect(message.contains("dlopen failed"), "got: \(message)")
        #expect(ccef_is_framework_loaded() == 0)
    }

    @Test(.enabled(if: LoaderTests.frameworkAvailable))
    func resolveFrameworkBinaryHonorsExplicitOverride() throws {
        let path = try #require(Self.frameworkBinaryPath())
        let resolved = try CefRuntime.resolveFrameworkBinary(
            override: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
        #expect(resolved.path == path)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"] == nil))
    func resolveFrameworkBinaryFailureIsActionable() {
        #expect(throws: CefError.self) {
            try CefRuntime.resolveFrameworkBinary(override: nil)
        }
        do {
            _ = try CefRuntime.resolveFrameworkBinary(override: nil)
            Issue.record("expected frameworkNotFound")
        } catch {
            #expect("\(error)".contains("CEF_FRAMEWORK_PATH"))
        }
    }
}

private final class ProbeLocator {}
