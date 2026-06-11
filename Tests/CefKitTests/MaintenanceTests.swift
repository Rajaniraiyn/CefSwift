import Foundation
import Testing

/// Cheap maintenance guards over the C bridge's X-macro symbol table.
///
/// These parse source files from the repository checkout (located relative to
/// `#filePath`) and are skipped when the sources are not available — e.g. when
/// tests run from an installed artifact rather than a checkout — mirroring the
/// skip-if-missing pattern of `LoaderTests`.
struct MaintenanceTests {
    /// Repository root: walk up from this file until a `Package.swift` appears.
    static let repoRoot: URL? = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }()

    /// Locates a file by name under `Sources/CCef` (its exact placement within
    /// the target is owned by the CCef layout, so search rather than hardcode).
    static func ccefFile(named name: String) -> URL? {
        guard let root = repoRoot else { return nil }
        let ccef = root.appendingPathComponent("Sources/CCef")
        guard
            let enumerator = FileManager.default.enumerator(
                at: ccef, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            // The vendored CEF tree must not shadow CefSwift-authored files.
            if !url.path.contains("/include/include/") { return url }
        }
        return nil
    }

    static var sourcesAvailable: Bool {
        ccefFile(named: "ccef_symbols.h") != nil && ccefFile(named: "ccef_loader.c") != nil
    }

    /// Extracts symbol names from the X-macro list: the 1st field of
    /// `CCEF_SYM_VOID(name, ...)` and the 2nd field of `CCEF_SYM(type, name, ...)`.
    static func parseSymbolNames(from text: String) -> [String] {
        var names: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("CCEF_SYM_VOID(") {
                let rest = line.dropFirst("CCEF_SYM_VOID(".count)
                if let end = rest.firstIndex(where: { $0 == "," || $0 == ")" }) {
                    let name = rest[..<end].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { names.append(name) }
                }
            } else if line.hasPrefix("CCEF_SYM(") {
                let rest = line.dropFirst("CCEF_SYM(".count)
                let fields = rest.split(separator: ",", omittingEmptySubsequences: false)
                if fields.count >= 2 {
                    let name = fields[1].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { names.append(name) }
                }
            }
        }
        return names
    }

    @Test(
        .enabled(
            if: MaintenanceTests.sourcesAvailable,
            "Sources/CCef not found relative to the test file; requires a repo checkout."))
    func symbolTableIsNonEmptyUniqueAndWellFormed() throws {
        let url = try #require(Self.ccefFile(named: "ccef_symbols.h"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let names = Self.parseSymbolNames(from: text)

        #expect(!names.isEmpty, "X-macro list in ccef_symbols.h parsed to zero symbols")

        // Unique at minimum — a duplicate entry would mean a duplicate
        // trampoline definition and a C compile error nobody wants to debug.
        var seen = Set<String>()
        let duplicates = names.filter { !seen.insert($0).inserted }
        #expect(duplicates.isEmpty, "duplicate X-macro entries: \(duplicates)")

        // Every bound name must look like a CEF C API global.
        let malformed = names.filter { !$0.hasPrefix("cef_") }
        #expect(malformed.isEmpty, "non-cef_* names in symbol table: \(malformed)")
    }

    @Test(
        .enabled(
            if: MaintenanceTests.sourcesAvailable,
            "Sources/CCef not found relative to the test file; requires a repo checkout."))
    func loaderIncludesTheSymbolTable() throws {
        // Drift guard: the loader must generate its pointer table, dlsym pass,
        // and trampolines from the same X-macro file the audit tools parse.
        let loaderURL = try #require(Self.ccefFile(named: "ccef_loader.c"))
        let loader = try String(contentsOf: loaderURL, encoding: .utf8)
        let includeCount = loader.components(separatedBy: "#include \"ccef_symbols.h\"").count - 1
        #expect(
            includeCount >= 2,
            "ccef_loader.c should expand ccef_symbols.h multiple times (table + resolve + trampolines); found \(includeCount) include(s)")
    }
}
