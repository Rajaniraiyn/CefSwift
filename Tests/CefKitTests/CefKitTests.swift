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


@Suite struct SafeStoragePolicyTests {
    @Test func explicitPoliciesPassThrough() {
        #expect(CefSafeStoragePolicy.keychain.resolved() == .keychain)
        #expect(CefSafeStoragePolicy.mockKeychain.resolved() == .mockKeychain)
    }

    @Test func automaticResolvesToATerminalPolicy() {
        let resolved = CefSafeStoragePolicy.automatic.resolved()
        #expect(resolved == .keychain || resolved == .mockKeychain)
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
