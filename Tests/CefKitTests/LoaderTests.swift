import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Tests of the framework loader. Those that need the framework run only
/// when `CEF_FRAMEWORK_PATH` points at it. None call `cef_initialize`, which
/// would take over the test process.
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

    @Test(.enabled(if: LoaderTests.frameworkAvailable, "CEF framework not present; set CEF_FRAMEWORK_PATH to run loader tests."))
    func loadVerifyAndUnloadRealFramework() throws {
        let path = try #require(Self.frameworkBinaryPath())

        #expect(ccef_load_framework(path) == 1, "\(String(cString: ccef_loader_error()))")
        #expect(ccef_is_framework_loaded() == 1)
        #expect(ccef_has_symbol("cef_initialize") == 1)
        #expect(ccef_has_symbol("cef_no_such_function") == 0)

        // cef_api_hash must be the first CEF call in the process.
        let hash = try #require(cef_api_hash(ccef_pinned_api_version(), 0))
        #expect(String(cString: hash) == String(cString: ccef_pinned_api_hash()))
        #expect(cef_api_version() == ccef_pinned_api_version())

        // CefRuntime's own check agrees.
        try CefRuntime.verifyAPIHash()

        // A string conversion implemented by the framework.
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
