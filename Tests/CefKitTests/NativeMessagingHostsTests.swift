import Foundation
import Testing

@testable import CefKit

/// `CefRuntime.Configuration.nativeMessagingHostDirectories`: the links in
/// the root cache directory's `NativeMessagingHosts`.
struct NativeMessagingHostsTests {
    func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-nm-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeManifest(_ name: String, in directory: URL, path: String = "/bin/cat") throws {
        let manifest = #"{"name": "\#(name)", "path": "\#(path)", "type": "stdio", "allowed_origins": []}"#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("\(name).json"))
    }

    func link(_ root: URL, _ name: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("NativeMessagingHosts/\(name).json").path)
    }

    @Test func linksManifestsFirstDirectoryWinning() throws {
        let root = try makeDirectory("root"), chrome = try makeDirectory("chrome"), chromium = try makeDirectory("chromium")
        defer { [root, chrome, chromium].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writeManifest("com.example.vault", in: chrome)
        try writeManifest("com.example.vault", in: chromium)
        try writeManifest("org.example.other", in: chromium)
        try writeManifest("Bad..Name", in: chromium)
        try Data("not a manifest".utf8).write(to: chromium.appendingPathComponent("README.txt"))

        CefNativeMessagingHosts.link([chrome, chromium], rootCache: root)

        #expect(link(root, "com.example.vault") == chrome.appendingPathComponent("com.example.vault.json").resolvingSymlinksInPath().path)
        #expect(link(root, "org.example.other") == chromium.appendingPathComponent("org.example.other.json").resolvingSymlinksInPath().path)
        #expect(link(root, "Bad..Name") == nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("NativeMessagingHosts").path)
        #expect(Set(entries) == ["com.example.vault.json", "org.example.other.json", CefNativeMessagingHosts.ledgerName])
    }

    @Test func keepsTheAppsOwnManifestsAndRemovesStaleLinks() throws {
        let root = try makeDirectory("root"), chrome = try makeDirectory("chrome")
        defer { [root, chrome].forEach { try? FileManager.default.removeItem(at: $0) } }
        let hosts = root.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        try writeManifest("com.example.own", in: hosts, path: "/usr/bin/true")
        try writeManifest("com.example.own", in: chrome)
        try writeManifest("com.example.vault", in: chrome)

        CefNativeMessagingHosts.link([chrome], rootCache: root)
        #expect(link(root, "com.example.own") == nil)
        #expect(try String(contentsOf: hosts.appendingPathComponent("com.example.own.json"), encoding: .utf8).contains("/usr/bin/true"))
        #expect(link(root, "com.example.vault") != nil)

        // The host is uninstalled: its link goes, the app's file stays.
        try FileManager.default.removeItem(at: chrome.appendingPathComponent("com.example.vault.json"))
        CefNativeMessagingHosts.link([chrome], rootCache: root)
        #expect(!FileManager.default.fileExists(atPath: hosts.appendingPathComponent("com.example.vault.json").path))
        #expect(FileManager.default.fileExists(atPath: hosts.appendingPathComponent("com.example.own.json").path))
        #expect(!FileManager.default.fileExists(atPath: hosts.appendingPathComponent(CefNativeMessagingHosts.ledgerName).path))
    }

    @Test func followsAHostThatMovesToAnotherDirectory() throws {
        let root = try makeDirectory("root"), first = try makeDirectory("first"), second = try makeDirectory("second")
        defer { [root, first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writeManifest("com.example.vault", in: second)
        CefNativeMessagingHosts.link([first, second], rootCache: root)
        #expect(link(root, "com.example.vault")?.hasPrefix(second.resolvingSymlinksInPath().path) == true)
        try writeManifest("com.example.vault", in: first)
        CefNativeMessagingHosts.link([first, second], rootCache: root)
        #expect(link(root, "com.example.vault")?.hasPrefix(first.resolvingSymlinksInPath().path) == true)
    }

    @Test func validNames() {
        #expect(CefNativeMessagingHosts.isValidName("com.1password.1password"))
        #expect(CefNativeMessagingHosts.isValidName("com.8bit.bitwarden"))
        #expect(!CefNativeMessagingHosts.isValidName("Com.Example"))
        #expect(!CefNativeMessagingHosts.isValidName(".com.example"))
        #expect(!CefNativeMessagingHosts.isValidName("com.example."))
        #expect(!CefNativeMessagingHosts.isValidName("com..example"))
        #expect(!CefNativeMessagingHosts.isValidName("com-example"))
    }

    @Test func presets() {
        #expect(CefRuntime.Configuration().nativeMessagingHostDirectories.isEmpty)
        #expect(CefRuntime.Configuration.embedded.nativeMessagingHostDirectories.isEmpty)
        let chrome = CefRuntime.Configuration.chrome.nativeMessagingHostDirectories.map(\.path)
        #expect(chrome.contains { $0.hasSuffix("Library/Application Support/Google/Chrome/NativeMessagingHosts") })
        #expect(chrome.contains { $0.hasSuffix("Library/Application Support/Chromium/NativeMessagingHosts") })
        #expect(chrome.contains("/Library/Google/Chrome/NativeMessagingHosts"))
    }
}
