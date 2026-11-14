import Foundation
import Testing

@testable import CefKit

/// `CefRuntime.Configuration.extensions`: the files Chromium's external
/// extension provider reads, and the `--load-extension` switch.
struct ExtensionConfigurationTests {
    static let storeID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    static let packageID = "hijdjdmlodkldbmopflekahgjddfeagl"

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-ext-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func json(_ url: URL) throws -> [String: String] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
    }

    @Test func writesExternalExtensionFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        CefExternalExtensions.write([
            .webStore(Self.storeID),
            .package(at: URL(fileURLWithPath: "/Applications/App.app/Contents/Resources/x.crx"), id: Self.packageID, version: "2.1"),
            .unpacked(at: URL(fileURLWithPath: "/tmp/unpacked")),
            .webStore("not-an-id"),
        ], rootCache: root)
        let directory = root.appendingPathComponent("External Extensions")
        #expect(try json(directory.appendingPathComponent("\(Self.storeID).json"))
                == ["external_update_url": "https://clients2.google.com/service/update2/crx"])
        #expect(try json(directory.appendingPathComponent("\(Self.packageID).json"))
                == ["external_crx": "/Applications/App.app/Contents/Resources/x.crx", "external_version": "2.1"])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        #expect(files == ["\(Self.storeID).json", "\(Self.packageID).json"].sorted())
    }

    @Test func removesOnlyItsOwnFilesForExtensionsNoLongerConfigured() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("External Extensions")
        CefExternalExtensions.write([.webStore(Self.storeID)], rootCache: root)
        // Another program's file.
        let foreign = directory.appendingPathComponent("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json")
        try Data("{}".utf8).write(to: foreign)
        CefExternalExtensions.write([], rootCache: root)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(Self.storeID).json").path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(CefExternalExtensions.ledgerName).path))
    }

    @Test func identifiers() {
        #expect(CefExternalExtensions.isValidIdentifier(Self.storeID))
        #expect(!CefExternalExtensions.isValidIdentifier("Ddkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(!CefExternalExtensions.isValidIdentifier("ddkjiahejlhfcafbddmgiahcphecmpfz"))
        #expect(!CefExternalExtensions.isValidIdentifier("abc"))
        #expect(CefRuntime.Configuration.Extension.webStore(Self.storeID).id == Self.storeID)
        #expect(CefRuntime.Configuration.Extension.unpacked(at: URL(fileURLWithPath: "/tmp")).id == nil)
    }
}
