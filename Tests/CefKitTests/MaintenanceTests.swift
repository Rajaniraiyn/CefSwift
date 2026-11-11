import Foundation
import Testing

/// Checks on the generated C bindings, read from the repository checkout.
/// Skipped when the sources are not next to the tests.
struct MaintenanceTests {
    /// The package root: the nearest ancestor of this file with a `Package.swift`.
    static let repoRoot: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }()

    /// A CefSwift file in `Sources/CCef`, ignoring the vendored CEF headers.
    static func ccefFile(named name: String) -> URL? {
        guard let root = repoRoot,
              let enumerator = FileManager.default.enumerator(
                  at: root.appendingPathComponent("Sources/CCef"), includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            if !url.path.contains("/include/include/") { return url }
        }
        return nil
    }

    static var sourcesAvailable: Bool {
        ccefFile(named: "ccef_symbols.h") != nil && ccefFile(named: "ccef_loader.c") != nil
    }

    /// The function names in `ccef_symbols.h`: the second field of each
    /// `CCEF_SYM(return_type, name, (params), (args))` line.
    static func parseSymbolNames(from text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("CCEF_SYM(") else { return nil }
            let fields = line.dropFirst("CCEF_SYM(".count).split(separator: ",", maxSplits: 2)
            guard fields.count >= 2 else { return nil }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    @Test(.enabled(if: MaintenanceTests.sourcesAvailable, "Requires a repository checkout."))
    func generatedSymbolTableIsWellFormed() throws {
        let url = try #require(Self.ccefFile(named: "ccef_symbols.h"))
        let names = Self.parseSymbolNames(from: try String(contentsOf: url, encoding: .utf8))

        #expect(!names.isEmpty, "ccef_symbols.h lists no symbols")

        var seen = Set<String>()
        let duplicates = names.filter { !seen.insert($0).inserted }
        #expect(duplicates.isEmpty, "duplicate symbols: \(duplicates)")

        let malformed = names.filter { !$0.hasPrefix("cef_") }
        #expect(malformed.isEmpty, "symbols not named cef_*: \(malformed)")

        // Functions CefSwift calls by name must be in the table.
        for required in ["cef_initialize", "cef_api_hash", "cef_do_message_loop_work", "cef_shutdown"] {
            #expect(names.contains(required), "\(required) missing from ccef_symbols.h")
        }
    }

    @Test(.enabled(if: MaintenanceTests.sourcesAvailable, "Requires a repository checkout."))
    func loaderExpandsTheSymbolTable() throws {
        let url = try #require(Self.ccefFile(named: "ccef_loader.c"))
        let loader = try String(contentsOf: url, encoding: .utf8)
        #expect(loader.contains("#include \"ccef_symbols.h\""), "ccef_loader.c must include ccef_symbols.h")
    }
}
