import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Loader tests that exercise the real CEF framework when present. They are
/// skipped (via `.enabled(if:)`) when the framework is unavailable, e.g. on
/// clean CI machines. They never call cef_initialize — that would take over
/// the test process.
@Suite(.serialized)
struct LoaderTests {
    /// Resolves a usable framework binary from CEF_FRAMEWORK_PATH or the
    /// local extracted distribution.
    static func frameworkBinaryPath() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append(
            "/tmp/cefswift-ref/cef_binary_148.0.10+g7ee53f5+chromium-148.0.7778.218_macosarm64_minimal/"
                + "Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
        )
        for candidate in candidates {
            var resolved = candidate
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                resolved += "/Chromium Embedded Framework"
            }
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }

    static var frameworkAvailable: Bool { frameworkBinaryPath() != nil }

    @Test(.enabled(if: LoaderTests.frameworkAvailable, "CEF framework not present; set CEF_FRAMEWORK_PATH to run loader tests."))
    func loadVerifyAndUnloadRealFramework() throws {
        let path = try #require(Self.frameworkBinaryPath())

        #expect(ccef_is_framework_loaded() == 0)
        #expect(ccef_load_framework(path) == 1, "\(String(cString: ccef_loader_error()))")
        defer { ccef_unload_framework() }
        #expect(ccef_is_framework_loaded() == 1)

        // First CEF call in the process must be cef_api_hash.
        let hash = try #require(cef_api_hash(CCEF_API_VERSION_VALUE, 0))
        #expect(String(cString: hash) == CCEF_EXPECTED_API_HASH_PLATFORM)

        // The configured API version must be the pinned one.
        #expect(cef_api_version() == CCEF_API_VERSION_VALUE)
        #expect(CCEF_API_VERSION_VALUE == 14800)

        // CefRuntime's own verification should agree.
        try CefRuntime.verifyAPIHash()

        // Framework-backed string conversion round-trip.
        var utf16 = cef_string_t()
        #expect(cef_string_utf8_to_utf16("loader-test", 11, &utf16) == 1)
        #expect(CefStringUtil.string(from: utf16) == "loader-test")
        cef_string_utf16_clear(&utf16)
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
