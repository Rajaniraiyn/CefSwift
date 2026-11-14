import CCef
import CefBase
import Foundation

extension CefRuntime {
    /// Which language Chromium's own interface uses: its menus, dialogs,
    /// error and settings pages, and the strings pages get from it.
    ///
    /// Set it with ``CefRuntime/Configuration/localization``. Chromium reads it once,
    /// at start-up; a change takes effect at the next launch. CefKit resolves
    /// it before Chromium starts, to a locale whose strings the app bundle
    /// contains (`cef bundle` keeps only the packs the app needs; see
    /// `docs/bundling.md`): the first choice that has a pack, else the app's
    /// development language, else English (`en-US`).
    /// ``CefRuntime/locale`` is the result.
    ///
    /// The languages pages are offered (`Accept-Language`,
    /// `navigator.languages`) are separate: ``CefRuntime/Configuration/acceptLanguages``.
    public enum Localization: Sendable, Equatable {
        /// The app's own language: the localization macOS chose for the app
        /// from those it has (`Bundle.main.preferredLocalizations`), which
        /// follows the user's language order and the app's language in System
        /// Settings. An English-only app shows Chromium in English. The
        /// default.
        case application

        /// The user's preferred languages (`Locale.preferredLanguages`), in
        /// order, whatever the app is localized in.
        case system

        /// One language, by identifier: `"de"`, `"pt-BR"`, `"zh-Hant"`.
        case fixed(String)

        /// The identifiers to try, best first.
        func identifiers(bundle: Bundle, preferredLanguages: [String]) -> [String] {
            switch self {
            case .application:
                return Array(bundle.preferredLocalizations.filter { $0 != "Base" }.prefix(1))
            case .system:
                return preferredLanguages
            case .fixed(let identifier):
                return [identifier]
            }
        }

        /// The pack Chromium should load, among `packs`, and its Chromium
        /// locale name; `nil` when there are no packs.
        func resolve(
            packs: Set<String>, bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages
        ) -> (pack: String, locale: String)? {
            guard let pack = ChromiumLocales.resolve(
                identifiers(bundle: bundle, preferredLanguages: preferredLanguages),
                developmentLanguage: bundle.developmentLocalization, packs: packs)
            else { return nil }
            return (pack, ChromiumLocales.chromiumLocale(forPack: pack))
        }

        /// The languages to offer pages when the app names none: the user's
        /// preferred languages, else `locale`.
        static func defaultAcceptLanguages(preferredLanguages: [String] = Locale.preferredLanguages, locale: String?) -> [String] {
            var seen = Set<String>()
            let languages = preferredLanguages.filter { seen.insert($0.lowercased()).inserted }
            return languages.isEmpty ? [locale].compactMap { $0 } : languages
        }
    }
}

extension CefRuntime {
    /// The string Chromium shows for `id`, in ``locale`` and with the app's
    /// ``CefRuntime/Configuration/stringOverrides``; `nil` when Chromium has none
    /// or is not running.
    @_spi(Testing) public func localizedString(_ id: CefRuntime.StringID) -> String? {
        guard isRunning, let bundle = cef_resource_bundle_get_global() else { return nil }
        defer { cefRelease(bundle) }
        let value = CefStringUtil.takingUserFree(bundle.pointee.get_localized_string(bundle, id.rawValue))
        return value?.isEmpty == false ? value : nil
    }
}
