import Foundation
import Testing

/// `cef bundle`'s trimming of the CEF framework: which locale packs and
/// software GPU files an app keeps.
@Suite struct FrameworkTrimTests {
    /// A framework with a few packs, their gender variants and the
    /// software GPU files.
    private func makeFramework() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString)/CEF.framework")
        let resources = root.appendingPathComponent("Versions/A/Resources")
        let libraries = root.appendingPathComponent("Versions/A/Libraries")
        try fm.createDirectory(at: libraries, withIntermediateDirectories: true)
        for pack in ["en", "en_GB", "fr", "de", "pt_BR", "pt_PT", "zh_CN", "zh_TW", "ja"] {
            for suffix in ["", "_FEMININE", "_MASCULINE", "_NEUTER"] {
                let directory = resources.appendingPathComponent("\(pack)\(suffix).lproj")
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(count: suffix.isEmpty ? 1000 : 18).write(to: directory.appendingPathComponent("locale.pak"))
            }
        }
        try Data(count: 500).write(to: resources.appendingPathComponent("resources.pak"))
        for name in FrameworkTrim.softwareGPUFiles + ["libcef_sandbox.dylib"] {
            try Data(count: 100).write(to: libraries.appendingPathComponent(name))
        }
        return root
    }

    private func contents(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    @Test func applicationKeepsTheAppsLocalizationsTheDevelopmentLanguageAndEnglish() throws {
        let framework = try makeFramework()
        defer { try? FileManager.default.removeItem(at: framework.deletingLastPathComponent()) }
        let result = try FrameworkTrim.apply(
            FrameworkTrimPolicy(), to: framework, appLocalizations: ["fr", "pt", "zh-Hant"], developmentLanguage: "de")
        #expect(result.locales.kept == ["en", "fr", "de", "pt_BR", "zh_TW"])
        #expect(result.removedLocaleBytes == 4 * (1000 + 3 * 18))
        let resources = contents(framework.appendingPathComponent("Versions/A/Resources"))
        #expect(resources.contains("fr_FEMININE.lproj") && resources.contains("pt_BR.lproj"))
        #expect(!resources.contains("ja.lproj") && !resources.contains("ja_NEUTER.lproj") && !resources.contains("en_GB.lproj"))
        #expect(resources.contains("resources.pak"))
        #expect(contents(framework.appendingPathComponent("Versions/A/Libraries")).count == 4)
    }

    @Test func englishOnlyAppKeepsEnglish() throws {
        let framework = try makeFramework()
        defer { try? FileManager.default.removeItem(at: framework.deletingLastPathComponent()) }
        let result = try FrameworkTrim.apply(FrameworkTrimPolicy(), to: framework, appLocalizations: [], developmentLanguage: "en")
        #expect(result.locales.kept == ["en"])
    }

    @Test func allAndListPolicies() throws {
        let packs: Set<String> = ["en", "fr", "de", "ja"]
        #expect(FrameworkTrim.locales(.all, appLocalizations: ["fr"], developmentLanguage: "en", packs: packs).removed.isEmpty)
        let list = FrameworkTrim.locales(.list(["ja", "xx"]), appLocalizations: ["fr"], developmentLanguage: "en", packs: packs)
        #expect(list.kept == ["en", "ja"])
        #expect(list.mapping == [.init(localization: "ja", pack: "ja"), .init(localization: "xx", pack: nil)])
    }

    @Test func excludingSoftwareGPURemovesSwiftShaderOnly() throws {
        let framework = try makeFramework()
        defer { try? FileManager.default.removeItem(at: framework.deletingLastPathComponent()) }
        var policy = FrameworkTrimPolicy()
        policy.localizations = .all
        policy.includesSoftwareGPU = false
        let result = try FrameworkTrim.apply(policy, to: framework, appLocalizations: [], developmentLanguage: "en")
        #expect(result.removedSoftwareGPUBytes == 300)
        #expect(contents(framework.appendingPathComponent("Versions/A/Libraries")) == ["libcef_sandbox.dylib"])
        #expect(ChromiumLocales.packs(inResources: framework.appendingPathComponent("Versions/A/Resources")).count == 9)
    }

    @Test func cefappJSONOptionsAndCommandLine() throws {
        let json = #"{ "cef": { "localizations": ["fr", "de"], "softwareGPUFallback": "exclude" } }"#
        let config = try CefAppConfig.decode(Data(json.utf8), source: URL(fileURLWithPath: "/src/App/cefapp.json"))
        let policy = try config.trimPolicy(localizationsOption: nil, softwareGPUOption: nil)
        #expect(policy == FrameworkTrimPolicy(localizations: .list(["fr", "de"]), includesSoftwareGPU: false))
        let overridden = try config.trimPolicy(localizationsOption: "all", softwareGPUOption: "include")
        #expect(overridden == FrameworkTrimPolicy(localizations: .all, includesSoftwareGPU: true))
        #expect(try CefAppConfig().trimPolicy(localizationsOption: "en,ja", softwareGPUOption: nil).localizations
                == .list(["en", "ja"]))
        #expect(try CefAppConfig().trimPolicy(localizationsOption: nil, softwareGPUOption: nil) == FrameworkTrimPolicy())
    }

    @Test func rejectsUnknownValues() {
        for json in [#"{ "cef": { "localisations": "all" } }"#, #"{ "cef": { "softwareGPUFallback": "no" } }"#,
                     #"{ "cef": { "localizations": "some" } }"#] {
            #expect(throws: (any Error).self) {
                try CefAppConfig.decode(Data(json.utf8), source: URL(fileURLWithPath: "/src/App/cefapp.json"))
            }
        }
        #expect(throws: (any Error).self) { try FrameworkTrimPolicy.localizations(fromOption: ",") }
    }

    @Test func doctorReportsPacksAndWarnsAboutMissingOnes() {
        var footprint = BundleFacts.Footprint()
        footprint.localePacks = ["en": 1_000_000, "fr": 1_000_000, "ja": 1_000_000]
        footprint.appLocalizations = ["en", "fr", "ko"]
        footprint.softwareGPUBytes = 16_000_000
        let checks = Doctor.footprintChecks(footprint)
        let packs = checks.first { $0.title == "locale packs" }
        #expect(packs?.detail.contains("en → en, fr → fr, ko → none") == true)
        #expect(packs?.fix?.contains("1 packs serve no localization") == true)
        #expect(checks.contains { $0.status == .warning && $0.title == "locale pack for ko" })
        #expect(checks.first { $0.title == "software GPU fallback" }?.detail.hasPrefix("included") == true)
        footprint.softwareGPUBytes = nil
        footprint.appLocalizations = ["en", "fr", "ja"]
        let trimmed = Doctor.footprintChecks(footprint)
        #expect(!trimmed.contains { $0.status == .warning })
        #expect(trimmed.first { $0.title == "software GPU fallback" }?.detail.hasPrefix("left out") == true)
    }

    @Test func resourceBundleLocalizations() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bundles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let flat = root.appendingPathComponent("App_App.bundle")
        let nested = root.appendingPathComponent("App_Kit.bundle/Contents/Resources")
        for directory in [flat.appendingPathComponent("fr.lproj"), flat.appendingPathComponent("Base.lproj"),
                          nested.appendingPathComponent("de.lproj"), nested.appendingPathComponent("fr.lproj")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #expect(FrameworkTrim.resourceLocalizations(
            in: [flat, root.appendingPathComponent("App_Kit.bundle")]) == ["de", "fr"])
    }
}
