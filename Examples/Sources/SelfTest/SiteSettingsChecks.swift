import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Site settings, typed preferences and how stored permissions answer a
/// page's request. No check asks for the camera, microphone or location
/// through a page: those use the settings API only.
extension SelfTest {
    /// An HTTPS origin served by a scheme handler, without a network.
    static let capabilityOrigin = URL(string: "https://cefswift.test")!

    static func siteSettingsChecks() async {
        let profile = CefProfile.default
        let settings = profile.siteSettings
        let site = URL(string: "https://settings.cefswift.test/page")!

        // Every supported value of every permission round-trips, and is
        // listed where Chromium keeps the site's own values.
        var failedRoundTrips: [String] = []
        var unlisted: [String] = []
        for permission in CefSitePermission.allCases {
            for setting in permission.supportedSettings {
                settings.set(setting, for: permission, origin: site)
                let read = settings.setting(for: permission, origin: site)
                if read != setting { failedRoundTrips.append("\(permission).\(setting) read \(read)") }
            }
            if !settings.hasOwnSetting(permission, origin: site) { unlisted.append(permission.rawValue) }
        }
        check("siteSettings: every supported setting round-trips", failedRoundTrips.isEmpty,
              detail: failedRoundTrips.joined(separator: ", "))
        check("siteSettings: a site's own values are listed", unlisted.isEmpty, detail: unlisted.joined(separator: ", "))
        settings.reset(origin: site)
        // Values other checks stored for other sites can cover this one
        // through a wildcard pattern; reset removes only the site's own.
        func remaining() -> [CefSiteSettings.Exception] {
            // After a long session Chromium sometimes keeps an exception
            // equal to the default (camera: ask); it changes nothing.
            settings.exceptions().filter {
                $0.applies(to: site) && $0.pattern.contains("settings.cefswift.test")
                    && settings.setting(for: $0.permission, origin: site) != settings.defaultSetting(for: $0.permission)
            }
        }
        let cleared = await waitUntil(timeout: .seconds(3)) { remaining().isEmpty }
        check("siteSettings: reset removes the site's own values", cleared,
              detail: remaining().map { "\($0.permission) \($0.pattern) \($0.setting), reads \(settings.setting(for: $0.permission, origin: site))" }
                .joined(separator: ", "))
        check("siteSettings: defaults apply after a reset",
              settings.setting(for: .notifications, origin: site) == settings.defaultSetting(for: .notifications)
                  && settings.defaultSetting(for: .notifications) == .ask
                  && settings.defaultSetting(for: .popups) == .block
                  && settings.defaultSetting(for: .javaScript) == .allow,
              detail: "\(settings.defaultSetting(for: .notifications)) \(settings.defaultSetting(for: .popups))")
        check("siteSettings: an unsupported value is ignored", {
            settings.set(.ask, for: .images, origin: site)
            return settings.setting(for: .images, origin: site) == .allow
        }())

        // Changes arrive as a stream.
        let changes = settings.changes
        let received = Task { @MainActor () -> CefSiteSettings.Change? in
            for await change in changes where change.permission == .popups { return change }
            return nil
        }
        try? await Task.sleep(for: .milliseconds(50))
        settings.set(.allow, for: .popups, origin: site)
        let change = await withTimeout(.seconds(5)) { await received.value }
        received.cancel()
        check("siteSettings: changes arrive with their permission and site",
              change??.origin == URL(string: "https://settings.cefswift.test"), detail: "\(String(describing: change))")
        settings.reset(origin: site)

        let incognito = CefProfile.incognito()
        incognito.siteSettings.set(.block, for: .sound, origin: site)
        check("siteSettings: an incognito profile keeps its own",
              incognito.siteSettings.setting(for: .sound, origin: site) == .block
                  && settings.setting(for: .sound, origin: site) == .allow)

        await preferenceChecks(profile)
        await storedPermissionChecks()
    }

    static func preferenceChecks(_ profile: CefProfile) async {
        let preferences = profile.preferences
        let boolKeys: [CefPreferences.Key<Bool>] = [
            .savesPasswords, .fillsAddresses, .fillsPaymentCards, .checksSpelling,
            .showsHomeButton, .offersTranslation, .usesSafeBrowsing, .showsSearchSuggestions, .usesHTTPSOnlyMode, .sendsDoNotTrack,
        ]
        let missing = boolKeys.map(\.name).filter { preferences.value(named: $0) == nil }
            + [CefPreferences.Key<Int>.defaultFontSize, .defaultFixedFontSize, .minimumFontSize].map(\.name)
                .filter { preferences.value(named: $0) == nil }
            + [CefPreferences.Key<String>.homePage.name, CefPreferences.Key<[String]>.acceptLanguages.name,
               CefPreferences.Key<[String]>.spellingLanguages.name,
               CefPreferences.Key<CefPreferences.ThirdPartyCookies>.thirdPartyCookies.name]
                .filter { preferences.value(named: $0) == nil }
        check("preferences: every typed profile key names a preference", missing.isEmpty, detail: missing.joined(separator: ", "))
        check("preferences: the application-wide key names one",
              CefRuntime.shared.preferences[.confirmsQuit] != nil)
        check("preferences: typed values read", preferences[.defaultFontSize] != nil
              && preferences[.acceptLanguages]?.isEmpty == false
              && preferences[.thirdPartyCookies] != nil,
              detail: "\(String(describing: preferences[.acceptLanguages]))")
        check("preferences: a normal preference can be set", preferences.canSet(.showsHomeButton)
              && !preferences.canSet(named: "cefswift.no.such.pref"))

        do {
            try preferences.reset(.showsHomeButton)
            check("preferences: a reset preference has its default", preferences.isDefault(.showsHomeButton))
            let values = preferences.observe(.showsHomeButton)
            let collected = Task { @MainActor () -> [Bool?] in
                var seen: [Bool?] = []
                for await value in values {
                    seen.append(value)
                    if seen.count == 2 { break }
                }
                return seen
            }
            try? await Task.sleep(for: .milliseconds(100))
            try preferences.set(true, for: .showsHomeButton)
            let seen = await withTimeout(.seconds(5)) { await collected.value }
            collected.cancel()
            check("preferences: observing yields the value, then each change", seen == [false, true],
                  detail: "\(String(describing: seen))")
            check("preferences: a set preference is not default", !preferences.isDefault(.showsHomeButton))
            try preferences.reset(.showsHomeButton)
            check("preferences: reset restores the default", preferences[.showsHomeButton] == false
                  && preferences.isDefault(.showsHomeButton))
        } catch {
            check("preferences: set and observe", false, detail: "\(error)")
        }
        do {
            try preferences.set(["de", "en-US"], for: .acceptLanguages)
            check("preferences: a comma-separated list round-trips", preferences[.acceptLanguages] == ["de", "en-US"],
                  detail: "\(String(describing: preferences.value(named: "intl.accept_languages")))")
            try preferences.reset(.acceptLanguages)
        } catch {
            check("preferences: a comma-separated list round-trips", false, detail: "\(error)")
        }
        check("preferences: a value of the wrong type throws", {
            do {
                try preferences.setValue("large", named: CefPreferences.Key<Int>.defaultFontSize.name)
                return false
            } catch { return true }
        }())
    }

    /// Web MIDI with system-exclusive messages asks with a prompt, without
    /// a user gesture, and touches no device that needs the user's consent,
    /// so a page can request it here.
    static func storedPermissionChecks() async {
        let settings = CefProfile.default.siteSettings
        let origin = capabilityOrigin
        settings.reset(origin: origin)
        let recorder = PermissionRecorder()
        let browser = CefBrowser(url: origin.appending(path: "permissions.html"))
        browser.delegate = recorder
        let view = hostWindowed(browser)
        func finish() async {
            await closeHosted(browser, view)
            settings.reset(origin: origin)
        }
        guard await loaded(browser, title: "permissions") else {
            check("permissions: page loads", false, detail: browser.title)
            await finish()
            return
        }
        func request() async -> String {
            (try? await browser.evaluateJavaScript(
                "navigator.requestMIDIAccess({sysex: true}).then(() => 'granted', e => e.name)").stringValue) ?? "no answer"
        }

        settings.set(.block, for: .midiSystemExclusive, origin: origin)
        let blocked = await request()
        check("permissions: a stored block answers without asking", blocked != "granted" && recorder.requests.isEmpty,
              detail: "\(blocked), asked \(recorder.requests.count)")

        settings.reset(origin: origin)
        recorder.answer = .alwaysDeny
        let denied = await request()
        check("permissions: the delegate is asked when nothing is stored",
              denied != "granted" && recorder.requests.first?.kinds == .midi,
              detail: "\(denied), \(recorder.requests)")
        check("permissions: alwaysDeny stores a block",
              settings.setting(for: .midiSystemExclusive, origin: origin) == .block)
        let again = await request()
        check("permissions: the stored answer is used next time", again != "granted" && recorder.requests.count == 1,
              detail: "\(again), asked \(recorder.requests.count)")

        settings.reset(origin: origin)
        recorder.answer = .allow
        let granted = await request()
        check("permissions: allow grants", granted == "granted", detail: granted)
        check("permissions: Chromium keeps a prompt's allow for the site",
              settings.setting(for: .midiSystemExclusive, origin: origin) == .allow,
              detail: "\(settings.setting(for: .midiSystemExclusive, origin: origin))")

        // Screen capture is not the camera: a site allowed the camera and
        // microphone is still asked, about screen capture, and the answer
        // is never stored. Every answer here refuses, so nothing is
        // captured and macOS asks nothing.
        settings.set(.allow, for: .camera, origin: origin)
        settings.set(.allow, for: .microphone, origin: origin)
        recorder.requests = []
        recorder.answer = .alwaysDeny
        func capture() async -> String {
            (try? await browser.evaluateJavaScript(
                "navigator.mediaDevices.getDisplayMedia({video: true, audio: true}).then(() => 'granted', e => e.name)",
                userGesture: true).stringValue) ?? "no answer"
        }
        let screen = await capture()
        let asked = recorder.requests.first?.kinds ?? []
        check("permissions: a camera grant does not answer screen capture",
              screen != "granted" && asked.contains(.screenCapture) && asked.isDisjoint(with: [.camera, .microphone]),
              detail: "\(screen), asked \(recorder.requests)")
        let screenAgain = await capture()
        check("permissions: a screen-capture answer is not stored",
              screenAgain != "granted" && recorder.requests.count == 2
                  && settings.setting(for: .camera, origin: origin) == .allow,
              detail: "\(screenAgain), asked \(recorder.requests.count), camera \(settings.setting(for: .camera, origin: origin))")
        await finish()
    }
}

@MainActor
final class PermissionRecorder: CefBrowserDelegate {
    var requests: [CefPermissionRequest] = []
    var answer = CefPermissionDecision.deny

    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        requests.append(request)
        return answer
    }
}

/// Pages for the capability checks, at `https://cefswift.test/…`.
struct CapabilityPages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let path = request.url?.path ?? ""
        let name = path.dropFirst().split(separator: ".").first.map(String.init) ?? "page"
        let body = Self.bodies[path] ?? "<p>\(name)</p>"
        return CefSchemeResponse(mimeType: "text/html", body: Data("<title>\(name)</title>\(body)".utf8))
    }

    static let bodies: [String: String] = [
        "/busy.html": "<p>busy</p><script>window.spin = () => { for (;;) {} };</script>",
        "/print.html": """
            <style>@page { size: A5; } body { font: 14px sans-serif; } h1 { break-before: page; }</style>
            <h1>One</h1><p>first</p><h1>Two</h1><p>second</p><h1>Three</h1><p>third</p>
            """,
        "/plain.html": "<h1>Plain</h1><p>No page rules.</p>",
    ]
}
