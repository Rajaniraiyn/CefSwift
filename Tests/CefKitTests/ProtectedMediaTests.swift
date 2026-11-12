import CCef
import Foundation
import Testing

@testable import CefKit

@Suite struct ProtectedMediaTests {
    @Test func presetsChooseWhetherChromiumFetchesWidevine() {
        #expect(CefConfiguration.default.protectedMedia == .automatic)
        #expect(CefConfiguration.browser.protectedMedia == .automatic)
        #expect(CefConfiguration.embedded.protectedMedia == .disabled)
        // The switch follows protectedMedia rather than the preset's list.
        #expect(CefConfiguration.embedded.extraCommandLineSwitches["disable-component-update"] == nil)
    }

    @Test func componentStatesMapToWidevineStates() {
        #expect(CefRuntime.widevineState(state: CEF_COMPONENT_STATE_NEW, version: "0.0.0.0") == .notInstalled)
        #expect(CefRuntime.widevineState(state: CEF_COMPONENT_STATE_DOWNLOADING, version: "") == .installing)
        #expect(CefRuntime.widevineState(state: CEF_COMPONENT_STATE_UPDATE_ERROR, version: "") == .failed)
        #expect(CefRuntime.widevineState(state: CEF_COMPONENT_STATE_UPDATED, version: "4.10.3112.0")
                == .installed(version: "4.10.3112.0"))
        // An installed CDM stays usable while Chromium checks for a newer one.
        #expect(CefRuntime.widevineState(state: CEF_COMPONENT_STATE_CHECKING, version: "4.10.3112.0").isInstalled)
    }

    @Test func preinstalledCDMIsCopiedIntoTheProfileOnce() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-protected-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("Licensed/WidevineCdm")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("_platform_specific/mac_arm64"), withIntermediateDirectories: true)
        try Data(#"{"name": "WidevineCdm", "version": "1.2.3.4"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        try Data("stand-in".utf8).write(to: source.appendingPathComponent("_platform_specific/mac_arm64/lib"))

        let root = scratch.appendingPathComponent("Root")
        let policy = CefProtectedMedia.preinstalled(widevineDirectory: source)
        policy.installPreinstalledCDM(rootCache: root)
        let installed = root.appendingPathComponent("WidevineCdm/1.2.3.4/_platform_specific/mac_arm64/lib")
        #expect(FileManager.default.fileExists(atPath: installed.path))

        // A version already there (perhaps updated by Chromium) is kept.
        try Data("updated".utf8).write(to: installed)
        policy.installPreinstalledCDM(rootCache: root)
        #expect(try String(contentsOf: installed, encoding: .utf8) == "updated")
    }

    @Test func directoryWithoutManifestVersionIsIgnored() {
        #expect(CefProtectedMedia.cdmVersion(at: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test func protectedMediaIdentifierPermissionHasAKind() {
        let kinds = CefPermissionKind.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER.rawValue))
        #expect(kinds == .protectedMediaIdentifier)
    }
}
