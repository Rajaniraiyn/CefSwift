import Foundation
import Testing

@testable import CCef
@testable import CefKit

@Suite struct CefStringTests {
    @Test func roundTrip() {
        let samples = ["", "hello", "héllo wörld", "日本語テキスト", "emoji 🚀🌍", String(repeating: "x", count: 10_000)]
        for sample in samples {
            var cef = cef_string_t()
            CefStringUtil.set(sample, into: &cef)
            #expect(CefStringUtil.string(from: cef) == sample)
            ccef_string_clear(&cef)
            #expect(cef.str == nil)
            #expect(cef.length == 0)
        }
    }

    @Test func setReplacesPreviousValue() {
        var cef = cef_string_t()
        CefStringUtil.set("first", into: &cef)
        CefStringUtil.set("second value", into: &cef)
        #expect(CefStringUtil.string(from: cef) == "second value")
        CefStringUtil.set(nil, into: &cef)
        #expect(CefStringUtil.string(from: cef) == "")
    }

    @Test func scopedCefString() {
        CefStringUtil.withCefString("scoped") { pointer in
            #expect(CefStringUtil.string(from: pointer) == "scoped")
        }
    }
}

@Suite struct CefRefCountedTests {
    final class Owner {}

    @Test func refCountLifecycle() {
        weak var weakOwner: Owner?
        do {
            let owner = Owner()
            weakOwner = owner
            let object = cefAllocate(cef_client_t.self, owner: owner)
            #expect(object.pointee.base.size == MemoryLayout<cef_client_t>.stride)
            #expect(ccef_object_ref_count(object) == 1)

            let raw = UnsafeMutableRawPointer(object)
            #expect(cefOwner(Owner.self, raw) === owner)

            cefAddRef(raw)
            #expect(ccef_object_ref_count(raw) == 2)
            #expect(object.pointee.base.has_one_ref?(&object.pointee.base) == 0)
            #expect(object.pointee.base.has_at_least_one_ref?(&object.pointee.base) == 1)

            cefRelease(raw)
            #expect(ccef_object_ref_count(raw) == 1)
            #expect(object.pointee.base.has_one_ref?(&object.pointee.base) == 1)

            // Final release frees the struct and drops the Swift retain.
            cefRelease(raw)
        }
        #expect(weakOwner == nil, "owner must be released when the refcount hits zero")
    }
}

@Suite struct CefSettingsMappingTests {
    @Test func configurationMapsToCefSettings() {
        var configuration = CefConfiguration()
        configuration.noSandbox = true
        configuration.externalMessagePump = true
        configuration.logSeverity = .warning
        configuration.persistSessionCookies = true
        configuration.remoteDebuggingPort = 9222
        configuration.locale = "en-US"
        configuration.userAgentProduct = "CefSwiftTest/1.0"
        configuration.rootCachePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("CefSwiftTests-\(UUID().uuidString)")
        configuration.logFile = URL(fileURLWithPath: "/tmp/cefswift-test.log")

        let mapped = MappedCefSettings(
            configuration: configuration,
            frameworkDirectory: URL(fileURLWithPath: "/opt/cef.framework")
        )
        #expect(mapped.raw.size == MemoryLayout<cef_settings_t>.stride)
        #expect(mapped.raw.no_sandbox == 1)
        #expect(mapped.raw.external_message_pump == 1)
        #expect(mapped.raw.multi_threaded_message_loop == 0)
        #expect(mapped.raw.log_severity == LOGSEVERITY_WARNING)
        #expect(mapped.raw.persist_session_cookies == 1)
        #expect(mapped.raw.remote_debugging_port == 9222)
        #expect(CefStringUtil.string(from: mapped.raw.locale) == "en-US")
        #expect(CefStringUtil.string(from: mapped.raw.user_agent_product) == "CefSwiftTest/1.0")
        #expect(CefStringUtil.string(from: mapped.raw.root_cache_path) == configuration.rootCachePath!.path)
        #expect(CefStringUtil.string(from: mapped.raw.cache_path) == configuration.rootCachePath!.path)
        #expect(CefStringUtil.string(from: mapped.raw.framework_dir_path) == "/opt/cef.framework")
        #expect(CefStringUtil.string(from: mapped.raw.log_file) == "/tmp/cefswift-test.log")
        #expect(
            FileManager.default.fileExists(atPath: configuration.rootCachePath!.path),
            "root cache directory should be created"
        )
    }

    @Test func defaultRootCachePathUnderApplicationSupport() {
        let path = MappedCefSettings.defaultRootCachePath().path
        #expect(path.contains("Application Support"), "got: \(path)")
        #expect(path.hasSuffix("/CefSwift"))
    }
}

@Suite struct SafeStoragePolicyTests {
    @Test func explicitPoliciesPassThrough() {
        #expect(CefSafeStoragePolicy.keychain.resolved() == .keychain)
        #expect(CefSafeStoragePolicy.mockKeychain.resolved() == .mockKeychain)
    }

    @Test func automaticResolvesToATerminalPolicy() {
        let resolved = CefSafeStoragePolicy.automatic.resolved()
        #expect(resolved == .keychain || resolved == .mockKeychain)
    }

    @Test func adHocTestBinaryDetectsAsDevBuild() throws {
        // The SwiftPM-built test bundle binary is ad-hoc ("linker-signed") —
        // exactly the dev-build case .automatic targets. (The *host* process
        // running the tests may be Apple's signed test runner, so probe the
        // image containing this test code rather than Bundle.main.)
        var info = Dl_info()
        try #require(dladdr(#dsohandle, &info) != 0)
        let imagePath = String(cString: info.dli_fname)
        let adHoc = CefCodeSigning.isAdHocSigned(executableAt: URL(fileURLWithPath: imagePath))
        #expect(adHoc == true, "expected \(imagePath) to detect as ad-hoc/dev")
    }

    @Test func cachedProcessDetectionMatchesMainExecutable() {
        // The cached value must agree with a fresh inspection of the main
        // executable (nil ⇒ conservative false / real keychain).
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let fresh = CefCodeSigning.isAdHocSigned(executableAt: executable) ?? false
        #expect(CefCodeSigning.processIsAdHocSigned == fresh)
    }

    @Test func appleSignedBinaryDetectsAsProperlySigned() {
        // /bin/ls carries Apple's full certificate chain.
        let adHoc = CefCodeSigning.isAdHocSigned(executableAt: URL(fileURLWithPath: "/bin/ls"))
        #expect(adHoc == false)
    }

    @Test func missingBinaryReportsDetectionFailure() {
        let adHoc = CefCodeSigning.isAdHocSigned(
            executableAt: URL(fileURLWithPath: "/nonexistent/cefswift-no-such-binary"))
        #expect(adHoc == nil)
    }

    @Test func defaultConfigurationUsesAutomatic() {
        #expect(CefConfiguration().safeStorage == .automatic)
    }
}

@Suite struct VersionManifestTests {
    struct Manifest: Decodable {
        struct Flavor: Decodable {
            let name: String
            let sha1: String
            let size: Int
        }
        let cef: String
        let chromium: String
        let channel: String
        let platforms: [String: [String: Flavor]]
    }

    @Test func decodeCEFVersionManifest() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CefKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("CEF_VERSION.json")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        #expect(manifest.cef.hasPrefix("148."), "pinned CEF major should be 148, got \(manifest.cef)")
        #expect(manifest.channel == "stable")
        #expect(manifest.platforms["macosarm64"]?["minimal"] != nil)
    }
}
