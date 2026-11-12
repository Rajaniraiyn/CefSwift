import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import CCef

/// The language of Chromium's interface (`CefConfiguration.localization`)
/// and the languages pages are offered (`acceptLanguages`).
///
/// Each language case runs in a probe started with `-AppleLanguages`, as
/// macOS starts an app for a user whose first language that is. SelfTest's
/// cefapp.json declares `en`, `fr`, `de`, `pt-BR` and `zh-Hans`, so its
/// bundle keeps only those packs (and `en`).
extension SelfTest {
    static let localizationPolicyKey = "CEFSWIFT_SELFTEST_LOCALIZATION"
    static let localizationExpectationKey = "CEFSWIFT_SELFTEST_LOCALIZATION_EXPECT"

    static func localizationChecks() async {
        await acceptLanguageChecks()
        let cases: [(label: String, policy: String, languages: String, expected: Expectation)] = [
            ("French user, .application", "application", "(fr)",
             Expectation(locale: "fr", newTab: "Nouvel onglet", navigatorLanguage: "fr")),
            ("Brazilian user, .system", "system", "(pt-BR)",
             Expectation(locale: "pt-BR", newTab: "Nova guia", navigatorLanguage: "pt-BR")),
            ("Chinese (Traditional) user, .application: the app has only Simplified", "application", "(zh-Hant, en)",
             Expectation(locale: "en-US", newTab: "New Tab", navigatorLanguage: "zh-Hant")),
            ("Japanese user, .system: no Japanese pack in the bundle", "system", "(ja)",
             Expectation(locale: "en-US", newTab: "New Tab", navigatorLanguage: "ja")),
            (".fixed(\"de-AT\")", "fixed:de-AT", "(en)",
             Expectation(locale: "de", newTab: "Neuer Tab", navigatorLanguage: "en")),
        ]
        let resources = Bundle.main.privateFrameworksURL!
            .appendingPathComponent("Chromium Embedded Framework.framework/Resources")
        let packs = Set(((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasSuffix(".lproj") && !$0.contains("_FEMININE") && !$0.contains("_MASCULINE") && !$0.contains("_NEUTER") }
            .map { String($0.dropLast(".lproj".count)) })
        check("localization: the bundle keeps the packs of the app's localizations, and en",
              packs == ["en", "fr", "de", "pt_BR", "zh_CN"], detail: packs.sorted().joined(separator: " "))
        await runProbe("localization", label: "localization (--lang=ja, no pack)", arguments: ["-AppleLanguages", "(en)"],
                       environment: [localizationPolicyKey: "switch:ja"])
        for item in cases {
            await runProbe("localization", label: "localization (\(item.label))",
                           arguments: ["-AppleLanguages", item.languages],
                           environment: [localizationPolicyKey: item.policy,
                                         localizationExpectationKey: item.expected.encoded])
        }
    }

    struct Expectation: Codable {
        var locale: String
        var newTab: String
        var navigatorLanguage: String
        var encoded: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    }

    /// The default list follows the user's languages; a profile can have
    /// its own.
    static func acceptLanguageChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("localization: Accept-Language", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/accept-language")!
        let preferred = Locale.preferredLanguages

        for (label, profile) in [("default profile", CefProfile.default), ("profile with its own list", {
            let profile = CefProfile.incognito()
            profile.acceptLanguages = ["de-CH", "it"]
            return profile
        }())] {
            var options = CefBrowserOptions()
            options.profile = profile
            let browser = CefBrowser(url: url, options: options)
            let view = CefWindowedBrowserView()
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            view.browser = browser
            defer {
                browser.close(force: true)
                view.removeFromSuperview()
            }
            guard await waitUntil({ browser.title.hasPrefix("accept-language") }) else {
                check("localization (\(label)): page loads", false, detail: browser.title)
                continue
            }
            let languages = (try? await browser.evaluateJavaScript("navigator.languages", as: [String].self)) ?? []
            let expected = profile === CefProfile.default ? preferred : ["de-CH", "it"]
            check("localization (\(label)): navigator.languages", languages.first == expected.first,
                  detail: "\(languages), expected \(expected)")
            let header = String(browser.title.dropFirst("accept-language ".count))
            check("localization (\(label)): Accept-Language", header.hasPrefix(expected[0]),
                  detail: "'\(header)', expected \(expected)")
        }
    }

    // MARK: The probe

    static func configureLocalizationProbe(_ configuration: inout CefConfiguration) {
        let policy = ProcessInfo.processInfo.environment[localizationPolicyKey] ?? "application"
        switch policy {
        case "system": configuration.localization = .system
        case let fixed where fixed.hasPrefix("fixed:"): configuration.localization = .fixed(String(fixed.dropFirst(6)))
        case let lang where lang.hasPrefix("switch:"):
            // Past CefKit's resolution: Chromium is told a locale whose
            // pack the bundle lacks.
            configuration.extraCommandLineSwitches["lang"] = String(lang.dropFirst(7))
        default: configuration.localization = .application
        }
    }

    static func localizationProbeChecks() async {
        if ProcessInfo.processInfo.environment[localizationPolicyKey]?.hasPrefix("switch:") == true {
            let newTab = CefRuntime.shared.localizedString(CefStringID(rawValue: IDS_NEW_TAB_TITLE))
            print("NOTE with --lang naming a missing pack, Chromium starts and shows '\(newTab ?? "nil")'")
            return
        }
        guard let data = ProcessInfo.processInfo.environment[localizationExpectationKey]?.data(using: .utf8),
              let expected = try? JSONDecoder().decode(Expectation.self, from: data)
        else {
            check("expectations given", false)
            return
        }
        check("Chromium's locale is \(expected.locale)", CefRuntime.shared.locale == expected.locale,
              detail: CefRuntime.shared.locale ?? "nil")
        let newTab = CefRuntime.shared.localizedString(CefStringID(rawValue: IDS_NEW_TAB_TITLE))
        check("Chromium's own strings are in that language", newTab == expected.newTab,
              detail: "'\(newTab ?? "nil")'")

        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil({ browser.title == "tab" }) else {
            check("page loads", false, detail: browser.title)
            return
        }
        let language = (try? await browser.evaluateJavaScript("navigator.language").stringValue) ?? nil
        check("navigator.language follows the user's languages",
              language?.lowercased().hasPrefix(expected.navigatorLanguage.lowercased()) == true,
              detail: "'\(language ?? "nil")', expected \(expected.navigatorLanguage)")
    }
}
