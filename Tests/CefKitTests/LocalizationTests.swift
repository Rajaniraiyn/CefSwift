import Foundation
import Testing

@testable import CefKit
import CefBase

/// How localization identifiers map onto Chromium's locale packs, the
/// directory names in CEF 156's `Resources`.
@Suite struct LocalizationTests {
    /// The 55 packs of CEF 156.0.28's framework.
    static let packs: Set<String> = [
        "af", "am", "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "en_GB", "es", "es_419", "et", "fa", "fi",
        "fil", "fr", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "kn", "ko", "lt", "lv", "ml", "mr", "ms", "nb",
        "nl", "pl", "pt_BR", "pt_PT", "ro", "ru", "sk", "sl", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
        "vi", "zh_CN", "zh_TW",
    ]

    @Test(arguments: [
        ("en", "en"), ("en-US", "en"), ("en_US", "en"), ("en-PR", "en"), ("en-GB", "en_GB"), ("en-AU", "en_GB"),
        ("en-IN", "en_GB"), ("en-CA", "en_GB"),
        ("pt", "pt_BR"), ("pt-BR", "pt_BR"), ("pt-PT", "pt_PT"), ("pt_AO", "pt_PT"),
        ("zh-Hans", "zh_CN"), ("zh-Hans-CN", "zh_CN"), ("zh", "zh_CN"), ("zh-SG", "zh_CN"), ("zh_CN", "zh_CN"),
        ("zh-Hant", "zh_TW"), ("zh-Hant-HK", "zh_TW"), ("zh-TW", "zh_TW"), ("zh-HK", "zh_TW"), ("zh-MO", "zh_TW"),
        ("es", "es"), ("es-ES", "es"), ("es-419", "es_419"), ("es-MX", "es_419"), ("es-US", "es_419"),
        ("es_AR", "es_419"),
        ("nb", "nb"), ("no", "nb"), ("nn", "nb"), ("nb-NO", "nb"),
        ("he", "he"), ("iw", "he"), ("he-IL", "he"), ("fil", "fil"), ("tl", "fil"), ("in", "id"), ("id", "id"),
        ("fr", "fr"), ("fr-CA", "fr"), ("fr_CH", "fr"), ("de-AT", "de"), ("sr-Latn", "sr"), ("ja-JP", "ja"),
        ("FR", "fr"), ("en-US@calendar=gregorian", "en"),
    ] as [(String, String)])
    func mapsToPack(identifier: String, pack: String) {
        #expect(ChromiumLocales.pack(for: identifier, in: Self.packs) == pack)
    }

    @Test(arguments: ["Base", "", "gsw", "yue-Hant", "x", "123", "ga", "eu-ES"])
    func hasNoPack(identifier: String) {
        #expect(ChromiumLocales.pack(for: identifier, in: Self.packs) == nil)
    }

    @Test func fallsBackToTheLanguagesOtherPack() {
        #expect(ChromiumLocales.pack(for: "en-AU", in: ["en", "fr"]) == "en")
        #expect(ChromiumLocales.pack(for: "pt", in: ["en", "pt_PT"]) == "pt_PT")
        #expect(ChromiumLocales.pack(for: "es-MX", in: ["en", "es"]) == "es")
        #expect(ChromiumLocales.pack(for: "zh-Hant", in: ["en", "zh_CN"]) == nil)
    }

    @Test func chromiumLocaleNames() {
        #expect(ChromiumLocales.chromiumLocale(forPack: "en") == "en-US")
        #expect(ChromiumLocales.chromiumLocale(forPack: "en_GB") == "en-GB")
        #expect(ChromiumLocales.chromiumLocale(forPack: "es_419") == "es-419")
        #expect(ChromiumLocales.chromiumLocale(forPack: "fr") == "fr")
    }

    @Test func packsFromDirectoryNames() {
        let names = ["fr.lproj", "fr_FEMININE.lproj", "fr_MASCULINE.lproj", "fr_NEUTER.lproj", "en.lproj",
                     "resources.pak", "icudtl.dat", "pt_BR.lproj"]
        #expect(ChromiumLocales.packs(fromDirectoryNames: names) == ["fr", "en", "pt_BR"])
    }

    @Test func resolvesFirstAvailableThenDevelopmentLanguageThenEnglish() {
        #expect(ChromiumLocales.resolve(["ja", "fr"], developmentLanguage: "en", packs: Self.packs) == "ja")
        #expect(ChromiumLocales.resolve(["ja", "fr"], developmentLanguage: "en", packs: ["en", "fr"]) == "fr")
        #expect(ChromiumLocales.resolve(["ja"], developmentLanguage: "de", packs: ["en", "de"]) == "de")
        #expect(ChromiumLocales.resolve(["ja"], developmentLanguage: "ko", packs: ["en", "de"]) == "en")
        #expect(ChromiumLocales.resolve(["xx-YY"], developmentLanguage: nil, packs: ["en"]) == "en")
        #expect(ChromiumLocales.resolve(["ja"], developmentLanguage: nil, packs: ["de"]) == "de")
        #expect(ChromiumLocales.resolve(["ja"], developmentLanguage: nil, packs: []) == nil)
    }

    @Test func packsToKeepAlwaysIncludeEnglishAndTheDevelopmentLanguage() {
        #expect(ChromiumLocales.packsToKeep(for: [], developmentLanguage: "en", packs: Self.packs) == ["en"])
        #expect(ChromiumLocales.packsToKeep(for: ["fr", "pt", "zh-Hans", "gsw"], developmentLanguage: "de",
                                            packs: Self.packs) == ["en", "fr", "pt_BR", "zh_CN", "de"])
        #expect(ChromiumLocales.packsToKeep(for: ["en-GB"], developmentLanguage: "en", packs: Self.packs) == ["en", "en_GB"])
    }

    @Test func policiesChooseTheirIdentifiers() {
        #expect(CefRuntime.Localization.system.identifiers(bundle: .main, preferredLanguages: ["fr-CA", "en"]) == ["fr-CA", "en"])
        #expect(CefRuntime.Localization.fixed("de").identifiers(bundle: .main, preferredLanguages: ["fr"]) == ["de"])
        #expect(CefRuntime.Localization.fixed("xx").resolve(packs: Self.packs, preferredLanguages: [])?.locale == "en-US")
        #expect(CefRuntime.Localization.system.resolve(packs: Self.packs, preferredLanguages: ["pt-BR"])?.locale == "pt-BR")
        #expect(CefRuntime.Localization.system.resolve(packs: ["en", "fr"], preferredLanguages: ["ja"])?.locale == "en-US")
        #expect(CefRuntime.Localization.system.resolve(packs: [], preferredLanguages: ["ja"]) == nil)
    }

    @Test func defaultAcceptLanguagesAreThePreferredOnes() {
        #expect(CefRuntime.Localization.defaultAcceptLanguages(preferredLanguages: ["fr-CA", "en-US", "fr-CA"], locale: "fr")
                == ["fr-CA", "en-US"])
        #expect(CefRuntime.Localization.defaultAcceptLanguages(preferredLanguages: [], locale: "de") == ["de"])
    }

    @Test func settingsCarryTheResolvedLocale() {
        var configuration = CefRuntime.Configuration()
        configuration.acceptLanguages = ["de-CH"]
        let mapped = MappedCefSettings(configuration: configuration, frameworkDirectory: nil, locale: "fr")
        #expect(CefStringUtil.string(from: &mapped.raw.locale) == "fr")
        #expect(CefStringUtil.string(from: &mapped.raw.accept_language_list) == "de-CH")
    }
}
