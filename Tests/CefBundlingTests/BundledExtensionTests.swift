import Foundation
import Testing
@testable import CefBundling

/// Extensions an app ships: cefapp.json's `extensions`, the copy into the
/// bundle, and what `cef doctor` reads from a `.crx` or a directory.
struct BundledExtensionTests {
    /// SelfTest's fixture key, whose identifier is hijdjdmlodkldbmopflekahgjddfeagl.
    static let key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq7KyL4OV1GMfsK2go+6Dgre6wbUr/i7n5CPO0GP6qDl+yyfkvYU7RPy5nTRpiUaRv2sf6De0brNBfMh9QSBo/yrsY0sbtIgQf1Rz1ZMKba9OgS3mLYo4kW+iJcs41Amtgd7KarTU5F5M17Aaple36LzAi75VNNK1d4JhkAIljAld/0TdwQhEojjowzl4jBDQFXcNf4tF3z9U+NZxd9a96lKIUMBy4Cw0OzfjkhFrc3zDp8ob3/5QOXVDzgAnJFZbGDnEHn1RnG4rd701+iRA0ydPBskXAbL1dhzDaAPKgWexMqDGYkz0Zk3J6uwr4lgG7othCw9/TiPjPCCfuhcSNQIDAQAB"
    static let id = "hijdjdmlodkldbmopflekahgjddfeagl"

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-bundled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func identifierFromKey() {
        #expect(BundledExtensions.extensionID(publicKey: Data(base64Encoded: Self.key)!) == Self.id)
    }

    /// A protobuf length-delimited field.
    static func field(_ number: Int, _ value: [UInt8]) -> [UInt8] {
        func varint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }
        return varint(number << 3 | 2) + varint(value.count) + value
    }

    /// A CRX3 file with `key` and the signed identifier `crxID`.
    static func crx(key: Data, crxID: [UInt8]) -> Data {
        let header = field(2, field(1, [UInt8](key)) + field(2, [1, 2, 3])) + field(10000, field(1, crxID))
        let size = UInt32(header.count)
        let prefix: [UInt8] = Array("Cr24".utf8) + [3, 0, 0, 0] + [UInt8(size & 0xff), UInt8(size >> 8 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 24)]
        return Data(prefix + header + Array("PK".utf8))
    }

    static func idBytes(_ id: String) -> [UInt8] {
        let letters = Array(id.utf8).map { $0 - UInt8(ascii: "a") }
        return stride(from: 0, to: letters.count, by: 2).map { letters[$0] << 4 | letters[$0 + 1] }
    }

    @Test func readsACRX3Header() throws {
        let key = Data(base64Encoded: Self.key)!
        let header = try CRX3.parse(Self.crx(key: key, crxID: Self.idBytes(Self.id)))
        #expect(header.id == Self.id)
        #expect(header.publicKeys == [key])
    }

    @Test func rejectsWhatIsNotACRX3Package() {
        #expect(throws: CRX3.Invalid.self) { try CRX3.parse(Data("PK\u{3}\u{4}".utf8)) }
        var crx2 = [UInt8](Self.crx(key: Data([1]), crxID: Array(repeating: 0, count: 16)))
        crx2[4] = 2
        #expect(throws: CRX3.Invalid.self) { try CRX3.parse(Data(crx2)) }
        let truncated = Self.crx(key: Data([1]), crxID: Array(repeating: 0, count: 16)).prefix(20)
        #expect(throws: CRX3.Invalid.self) { try CRX3.parse(Data(truncated)) }
    }

    @Test func inspectsPackagesAndDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(base64Encoded: Self.key)!
        let good = directory.appendingPathComponent("Good.crx")
        try Self.crx(key: key, crxID: Self.idBytes(Self.id)).write(to: good)
        #expect(BundledExtensions.inspect(good) == .init(name: "Good.crx", id: Self.id))
        let mismatched = directory.appendingPathComponent("Mismatched.crx")
        try Self.crx(key: key, crxID: Array(repeating: 0, count: 16)).write(to: mismatched)
        #expect(BundledExtensions.inspect(mismatched).problems.first?.contains("not that of its first key") == true)

        let unpacked = directory.appendingPathComponent("Unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "U", "version": "2.0", "key": "\#(Self.key)"}"#.utf8)
            .write(to: unpacked.appendingPathComponent("manifest.json"))
        #expect(BundledExtensions.inspect(unpacked) == .init(name: "Unpacked", id: Self.id, version: "2.0"))

        let keyless = directory.appendingPathComponent("Keyless")
        try FileManager.default.createDirectory(at: keyless, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 2, "name": "K", "version": "1"}"#.utf8).write(to: keyless.appendingPathComponent("manifest.json"))
        let inspection = BundledExtensions.inspect(keyless)
        #expect(inspection.problems.isEmpty && inspection.warnings.count == 2)

        let broken = directory.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        #expect(BundledExtensions.inspect(broken).problems == ["has no readable manifest.json"])
        #expect(BundledExtensions.checks([BundledExtensions.inspect(broken)]).first?.status == .error)
        #expect(BundledExtensions.checks([BundledExtensions.inspect(good)]).first?.status == .ok)
    }

    @Test func copiesIntoTheBundleResources() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Ext.crx")
        try Self.crx(key: Data(base64Encoded: Self.key)!, crxID: Self.idBytes(Self.id)).write(to: source)
        let contents = directory.appendingPathComponent("App.app/Contents")
        try BundledExtensions.copy([source], into: contents)
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/Extensions/Ext.crx").path))
        #expect(BundledExtensions.inspect(contents: contents).map(\.id) == [Self.id])
        // A later build without extensions takes them out.
        try BundledExtensions.copy([], into: contents)
        #expect(!FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/Extensions").path))
        #expect(throws: BundlingError.self) {
            try BundledExtensions.copy([directory.appendingPathComponent("missing.crx")], into: contents)
        }
        let text = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        #expect(throws: BundlingError.self) { try BundledExtensions.copy([text], into: contents) }
    }

    @Test func cefappJSONNamesThem() throws {
        let config = try CefAppConfig.decode(
            Data(#"{ "extensions": ["Extensions/Helper.crx", "/abs/Dev"] }"#.utf8),
            source: URL(fileURLWithPath: "/src/App/cefapp.json"))
        #expect(config.extensions.map { $0.map { config.resolve($0).path } } == ["/src/App/Extensions/Helper.crx", "/abs/Dev"])
        #expect(XcodeEmbed.cefSettings.contains { $0.setting == "CEF_EXTENSIONS" && $0.key == "extensions" })
    }
}
