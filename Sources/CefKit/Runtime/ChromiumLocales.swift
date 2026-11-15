import Foundation

// Shared by CefKit, which picks the locale Chromium starts with, and
// CefBundling, which decides which locale packs an app bundle keeps
// (Sources/CefBundling/ChromiumLocales.swift is a link to this file). Both
// map localizations to packs the same way, so the runtime only asks for
// packs the bundle has.

/// Chromium's UI string packs, `<pack>.lproj/locale.pak` in the framework's
/// `Resources`, and how macOS localization identifiers map onto them.
///
/// Pack names are the directory names without `.lproj`: `en`, `en_GB`,
/// `es_419`, `pt_BR`, `zh_TW`. Chromium names the same locales `en-US`,
/// `en-GB`, `es-419`, `pt-BR` and `zh-TW`. Each pack has three grammatical
/// gender variants beside it (`fr_FEMININE.lproj`, …), which go with it.
enum ChromiumLocales {
    /// The pack every bundle keeps, and the last fallback: Chromium's
    /// `en-US`.
    static let fallbackPack = "en"

    /// Suffixes of the gender variants of a pack.
    static let genderSuffixes = ["_FEMININE", "_MASCULINE", "_NEUTER"]

    /// The packs in a framework's `Resources` directory, without gender
    /// variants.
    static func packs(inResources resources: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return packs(fromDirectoryNames: names)
    }

    /// The packs among directory names such as `fr.lproj` and
    /// `fr_FEMININE.lproj`.
    static func packs(fromDirectoryNames names: [String]) -> Set<String> {
        Set(names.compactMap { name -> String? in
            guard name.hasSuffix(".lproj") else { return nil }
            let pack = String(name.dropLast(".lproj".count))
            return genderSuffixes.contains(where: pack.hasSuffix) ? nil : pack
        })
    }

    /// Chromium's name for a pack: `en` is `en-US`; otherwise `_` becomes
    /// `-` (`pt_BR` is `pt-BR`).
    static func chromiumLocale(forPack pack: String) -> String {
        pack == fallbackPack ? "en-US" : pack.replacingOccurrences(of: "_", with: "-")
    }

    /// The pack for one localization or language identifier, such as
    /// `"fr"`, `"fr-CA"`, `"pt"`, `"zh-Hant"`, `"en_AU"` or Chromium's
    /// `"en-US"`, among `packs`; `nil` when none fits.
    ///
    /// The rules follow Chromium's locale matching for its own packs:
    /// - Old and macrolanguage codes: `iw` is `he`, `tl` is `fil`, `in` is
    ///   `id`, `no` and `nn` are `nb`, `mo` is `ro`.
    /// - Chinese: Traditional script, or Taiwan, Hong Kong or Macao, is
    ///   `zh_TW`; anything else is `zh_CN`.
    /// - Portuguese: Brazil or no region is `pt_BR`; other regions
    ///   `pt_PT`.
    /// - Spanish: Latin America and the US (`es-419`, `es-MX`, …) are
    ///   `es_419`; Spain and no region are `es`.
    /// - English: the US and its territories, or no region, are `en`;
    ///   other regions (`en-GB`, `en-AU`, `en-IN`, …) are `en_GB`.
    /// - Otherwise `language_REGION` when that pack exists, then
    ///   `language`.
    ///
    /// Each rule falls back to the language's other pack when the bundle
    /// lacks the preferred one.
    static func pack(for identifier: String, in packs: Set<String>) -> String? {
        candidates(for: identifier).first(where: packs.contains)
    }

    /// The packs that fit `identifier`, best first, whether or not a bundle
    /// has them.
    static func candidates(for identifier: String) -> [String] {
        guard let tag = Tag(identifier) else { return [] }
        let region = tag.region
        switch tag.language {
        case "zh":
            let traditional = tag.script == "Hant"
                || (tag.script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
            return traditional ? ["zh_TW"] : ["zh_CN"]
        case "pt":
            return region == nil || region == "BR" ? ["pt_BR", "pt_PT"] : ["pt_PT", "pt_BR"]
        case "es":
            return region.map(latinAmericanRegions.contains) == true ? ["es_419", "es"] : ["es", "es_419"]
        case "en":
            return region == nil || unitedStatesRegions.contains(region!) ? ["en", "en_GB"] : ["en_GB", "en"]
        default:
            return (region.map { ["\(tag.language)_\($0)"] } ?? []) + [tag.language]
        }
    }

    /// The pack for the first of `identifiers` that has one; else the
    /// development language's; else ``fallbackPack``; else any pack.
    /// `nil` only when `packs` is empty.
    static func resolve(_ identifiers: [String], developmentLanguage: String?, packs: Set<String>) -> String? {
        for identifier in identifiers + [developmentLanguage].compactMap({ $0 }) {
            if let pack = pack(for: identifier, in: packs) { return pack }
        }
        return packs.contains(fallbackPack) ? fallbackPack : packs.sorted().first
    }

    /// The packs an app with `localizations` needs, among `packs`: one for
    /// each localization that has one, the development language's and
    /// ``fallbackPack``.
    static func packsToKeep(for localizations: [String], developmentLanguage: String?, packs: Set<String>) -> Set<String> {
        var kept = Set((localizations + [developmentLanguage].compactMap { $0 }).compactMap { pack(for: $0, in: packs) })
        if packs.contains(fallbackPack) { kept.insert(fallbackPack) }
        return kept
    }

    // MARK: Identifiers

    /// Regions whose Spanish Chromium serves as `es-419`.
    private static let latinAmericanRegions: Set<String> = [
        "419", "AR", "BO", "BR", "BZ", "CL", "CO", "CR", "CU", "DO", "EC", "GT", "HN", "MX", "NI", "PA", "PE",
        "PR", "PY", "SV", "US", "UY", "VE",
    ]

    /// Regions whose English is US English.
    private static let unitedStatesRegions: Set<String> = ["US", "AS", "GU", "MP", "PR", "UM", "VI"]

    private static let languageAliases = [
        "iw": "he", "tl": "fil", "in": "id", "no": "nb", "nn": "nb", "mo": "ro", "ji": "yi", "jw": "jv",
    ]

    /// A language identifier's language, script and region.
    struct Tag: Equatable {
        var language: String
        var script: String?
        var region: String?

        /// Parses `fr`, `fr-CA`, `fr_CA`, `zh-Hant-TW`, `sr-Latn`,
        /// `en-US@calendar=…`; `nil` for `Base` and empty strings.
        init?(_ identifier: String) {
            let core = identifier.split(separator: "@").first.map(String.init) ?? ""
            let parts = core.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let first = parts.first?.lowercased(), (2...3).contains(first.count), first != "base",
                  first.allSatisfy(\.isLetter)
            else { return nil }
            language = Self.aliases[first] ?? first
            for part in parts.dropFirst() {
                if part.count == 4, part.allSatisfy(\.isLetter), script == nil, region == nil {
                    script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
                } else if region == nil,
                          (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                    region = part.uppercased()
                }
            }
        }

        private static var aliases: [String: String] { ChromiumLocales.languageAliases }
    }
}
