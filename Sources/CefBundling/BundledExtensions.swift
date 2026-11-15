import CryptoKit
import Foundation

/// Chrome extensions an app ships in its bundle: copied into
/// `Contents/Resources/Extensions` by both tracks (cefapp.json `extensions`,
/// Xcode's `CEF_EXTENSIONS`), sealed by the app's signature like its other
/// resources, and checked by `cef doctor`. The app installs them with
/// `CefRuntime.Configuration.extensions` (`.package(at:id:version:)` for a
/// `.crx`, `.unpacked(at:)` for a directory). CefSwift ships none itself.
enum BundledExtensions {
    static let directoryName = "Extensions"

    /// What `cef doctor` reads from one bundled extension.
    struct Inspection: Equatable, Sendable {
        var name: String
        /// The extension's identifier, when the package or manifest fixes it.
        var id: String?
        var version: String?
        var problems: [String] = []
        var warnings: [String] = []
    }

    /// `Contents/Resources/Extensions`.
    static func directory(in contents: URL) -> URL {
        contents.appendingPathComponent("Resources").appendingPathComponent(directoryName)
    }

    /// Copies `sources` (`.crx` files and unpacked directories) into the
    /// bundle, replacing what an earlier build put there.
    static func copy(_ sources: [URL], into contents: URL) throws {
        let destination = directory(in: contents)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard !sources.isEmpty else { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var names = Set<String>()
        for source in sources {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw BundlingError("The extension \(source.path) does not exist.")
            }
            guard isDirectory.boolValue || source.pathExtension == "crx" else {
                throw BundlingError("\(source.path) is neither a .crx package nor an unpacked extension directory.")
            }
            guard names.insert(source.lastPathComponent).inserted else {
                throw BundlingError("Two bundled extensions are named \(source.lastPathComponent).")
            }
            try CefEmbedder.copyPreservingLinks(source, to: destination.appendingPathComponent(source.lastPathComponent))
            print("[cef] Extension: \(source.lastPathComponent)")
        }
    }

    /// Every bundled extension, inspected.
    static func inspect(contents: URL) -> [Inspection] {
        let directory = directory(in: contents)
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(inspect)
    }

    static func inspect(_ url: URL) -> Inspection {
        var inspection = Inspection(name: url.lastPathComponent)
        if url.pathExtension == "crx" {
            do {
                let header = try CRX3.read(url)
                inspection.id = header.id
                if let key = header.publicKeys.first, extensionID(publicKey: key) != header.id {
                    inspection.problems.append("its identifier \(header.id) is not that of its first key")
                }
            } catch {
                inspection.problems.append("not a CRX3 package: \(error)")
            }
        } else {
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) as? [String: Any]
            else {
                inspection.problems.append("has no readable manifest.json")
                return inspection
            }
            inspection.version = manifest["version"] as? String
            if manifest["name"] as? String == nil { inspection.problems.append("its manifest has no name") }
            if inspection.version == nil { inspection.problems.append("its manifest has no version") }
            switch manifest["manifest_version"] as? Int {
            case 3: break
            case 2: inspection.warnings.append("Manifest V2, which Chromium 156 no longer runs")
            default: inspection.problems.append("its manifest has no manifest_version")
            }
            if let key = manifest["key"] as? String {
                if let der = Data(base64Encoded: key) {
                    inspection.id = extensionID(publicKey: der)
                } else {
                    inspection.problems.append("its manifest's key is not base64")
                }
            } else {
                inspection.warnings.append(
                    "no \"key\" in its manifest: Chromium derives its identifier from where it is installed, "
                        + "so it changes with the app's location")
            }
        }
        if let code = machOFiles(in: url), !code.isEmpty {
            inspection.warnings.append(
                "contains code (\(code.joined(separator: ", "))): an extension runs none; "
                    + "sign it as the app's or remove it")
        }
        return inspection
    }

    /// Chromium's extension identifier for a public key (DER
    /// SubjectPublicKeyInfo): the first 16 bytes of its SHA-256, each
    /// nibble a letter from `a` to `p`.
    static func extensionID(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { byte in
            String([Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))),
                    Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 15)))])
        }.joined()
    }

    private static func machOFiles(in url: URL) -> [String]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return (try? CefEmbedder.machOFiles(in: url))?.map(\.lastPathComponent)
    }

    /// The doctor's section for them.
    static func checks(_ inspections: [Inspection]) -> [DoctorReport.Check] {
        inspections.map { item in
            let identity = [item.id.map { "id \($0)" }, item.version.map { "version \($0)" }].compactMap { $0 }
                .joined(separator: ", ")
            if !item.problems.isEmpty {
                return DoctorReport.Check(
                    status: .error, title: item.name, detail: item.problems.joined(separator: "; ") + ".",
                    fix: "bundle a CRX3 package from chrome://extensions' Pack extension, or an unpacked directory with a manifest.json")
            }
            if !item.warnings.isEmpty {
                return DoctorReport.Check(
                    status: .warning, title: item.name,
                    detail: (identity.isEmpty ? "" : identity + "; ") + item.warnings.joined(separator: "; ") + ".")
            }
            return DoctorReport.Check(
                status: .ok, title: item.name,
                detail: identity + ". Install it with CefRuntime.Configuration.extensions.")
        }
    }
}

/// The header of a CRX3 package: `Cr24`, version 3, and a
/// `CrxFileHeader` protobuf with the signing keys and the signed
/// `crx_id`.
enum CRX3 {
    struct Header: Equatable {
        var id: String
        var publicKeys: [Data]
    }

    struct Invalid: Error, CustomStringConvertible {
        var description: String
    }

    static func read(_ url: URL) throws -> Header {
        try parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> Header {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] else { throw Invalid(description: "no Cr24 magic") }
        let version = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard version == 3 else { throw Invalid(description: "format version \(version), not 3") }
        let size = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        guard size <= bytes.count - 12 else { throw Invalid(description: "a header longer than the file") }
        let header = Array(bytes[12..<(12 + size)])
        // CrxFileHeader: sha256_with_rsa = 2, sha256_with_ecdsa = 3
        // (AsymmetricKeyProof: public_key = 1), signed_header_data = 10000
        // (SignedData: crx_id = 1).
        let keys = try fields(in: header).filter { $0.number == 2 || $0.number == 3 }
            .compactMap { proof in try fields(in: proof.value).first { $0.number == 1 }.map { Data($0.value) } }
        guard let signed = try fields(in: header).first(where: { $0.number == 10000 }),
              let crxID = try fields(in: signed.value).first(where: { $0.number == 1 }), crxID.value.count == 16
        else { throw Invalid(description: "no signed crx_id") }
        let id = crxID.value.map { byte in
            String([Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))),
                    Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 15)))])
        }.joined()
        return Header(id: id, publicKeys: keys)
    }

    /// The length-delimited fields of a protobuf message, with their numbers.
    static func fields(in message: [UInt8]) throws -> [(number: Int, value: [UInt8])] {
        var index = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < message.count {
                let byte = message[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                guard shift < 64 else { break }
            }
            throw Invalid(description: "a truncated header")
        }
        var result: [(Int, [UInt8])] = []
        while index < message.count {
            let key = try varint()
            switch key & 7 {
            case 0: _ = try varint()
            case 1: index += 8
            case 5: index += 4
            case 2:
                let length = try varint()
                guard length <= UInt64(message.count - index) else { throw Invalid(description: "a truncated header") }
                result.append((Int(key >> 3), Array(message[index..<(index + Int(length))])))
                index += Int(length)
            default: throw Invalid(description: "an unknown field type")
            }
            guard index <= message.count else { throw Invalid(description: "a truncated header") }
        }
        return result
    }
}
