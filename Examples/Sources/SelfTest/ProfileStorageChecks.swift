import AppKit
@_spi(Testing) import CefKit
import CefChromium

/// Where profiles keep their data, and what happens while Chromium loads
/// one: a persistent profile is a directory of its own directly inside the
/// root cache directory, which Chromium loads in the background; browsers
/// created on it meanwhile wait, in every way of hosting one; a profile
/// Chromium cannot load fails instead of becoming an in-memory one.
extension SelfTest {
    static let profilePhaseEnvironmentKey = "CEFSWIFT_SELFTEST_PROFILE_PHASE"

    static var rootCacheDirectory: URL {
        (CefRuntime.shared.configuration ?? CefRuntime.Configuration()).resolvedRootCacheDirectory
    }

    /// A persistent profile Chromium has never seen.
    static func brandNewProfile(_ label: String) -> CefProfile {
        .persistent(id: "selftest-\(label)-\(UUID().uuidString.prefix(8).lowercased())")
    }

    static func configuration(in profile: CefProfile) -> CefBrowser.Configuration {
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        return configuration
    }

    static func inProfile(_ profile: CefProfile, _ url: String) -> CefBrowser {
        CefBrowser(url: URL(string: url)!, configuration: configuration(in: profile))
    }

    static func profileStorageChecks() async {
        await newProfileHostingChecks()
        await loadedProfileChecks()
        await unavailableProfileChecks()
        // Two launches on one root cache directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for phase in ["1", "2"] {
            await runProbe("profilePersistence", label: "profile storage launch \(phase)", root: root,
                           environment: [profilePhaseEnvironmentKey: phase], timeout: .seconds(60))
        }
    }

    // MARK: A new profile, hosted every way

    /// Browsers created the moment a brand-new profile is first used:
    /// Chromium is still creating it, and each waits for it.
    static func newProfileHostingChecks() async {
        let root = rootCacheDirectory
        do {
            let profile = brandNewProfile("windowed")
            let directory = root.appendingPathComponent(ProfileDirectoryNames.directoryName(for: profile.id))
            check("profile storage: a new profile has no directory before its first use",
                  !FileManager.default.fileExists(atPath: directory.path))
            let browser = inProfile(profile, "https://cefswift.test/windowed.html")
            let view = hostWindowed(browser)
            check("profile storage: a windowed browser waits while Chromium creates its profile",
                  browser.state == .pending && !profile.isReady, detail: "\(browser.state)")
            check("profile storage: windowed browser on a new profile loads", await loaded(browser, title: "windowed"))
            check("profile storage: the profile is a directory of its own in the root cache directory",
                  isDirectory(directory), detail: directory.path)
            let second = inProfile(profile, "https://cefswift.test/second.html")
            let secondView = hostWindowed(second)
            check("profile storage: a second browser on the loaded profile is created at once", second.state == .live)
            secondView.removeFromSuperview()
            second.close(force: true)
            view.removeFromSuperview()
            browser.close(force: true)
        }
        do {
            let browser = inProfile(.default, "https://cefswift.test/plain.html")
            let view = hostWindowed(browser)
            check("profile storage: a windowed browser on the default profile is created at once", browser.state == .live)
            view.removeFromSuperview()
            browser.close(force: true)
        }
        do {
            let profile = brandNewProfile("offscreen")
            let browser = inProfile(profile, "https://cefswift.test/offscreen.html")
            let view = hostOffscreen(browser)
            check("profile storage: offscreen browser on a new profile loads", await loaded(browser, title: "offscreen"))
            check("profile storage: offscreen browser's profile is on disk",
                  isDirectory(root.appendingPathComponent(ProfileDirectoryNames.directoryName(for: profile.id))))
            view.removeFromSuperview()
            browser.close(force: true)
        }
        do {
            let profile = brandNewProfile("window")
            let browser = inProfile(profile, "https://cefswift.test/window.html")
            let window = CefWindow(browser: browser)
            check("profile storage: a CefWindow opens while its new profile loads", window.window != nil && !window.isClosed)
            window.show()
            check("profile storage: CefWindow browser on a new profile loads", await loaded(browser, title: "window"))
            await expect("profile storage: its page in a popup shares the new profile") {
                var popups: [CefWindow] = []
                window.onPopup = { popups.append($0) }
                _ = try await browser.evaluateJavaScript("window.open('popup.html', 'p', 'width=300,height=200'); 0", userGesture: true)
                guard await waitUntil(timeout: .seconds(5), { !popups.isEmpty }) else { return (false, "no popup") }
                let popup = popups[0]
                defer { popup.close() }
                guard await loaded(popup.browser, title: "popup") else { return (false, popup.browser.title) }
                return (popup.browser.configuration.profile === profile, "\(popup.browser.configuration.profile?.id ?? "nil")")
            }
            window.close()
            _ = await waitUntil { window.isClosed }
        }
        do {
            let profile = brandNewProfile("chrome")
            let browser = CefRuntime.shared.openChromeWindow(
                url: URL(string: "https://cefswift.test/chrome.html")!, configuration: configuration(in: profile))
            check("profile storage: Chrome's own window on a new profile loads", await loaded(browser, title: "chrome"))
            browser.close(force: true)
            _ = await waitUntil { browser.state == .closed }
        }
        do {
            // Closed while its profile loads: nothing is created later.
            let profile = brandNewProfile("closed")
            let browser = inProfile(profile, "https://cefswift.test/closed.html")
            let window = CefWindow(browser: browser)
            window.close()
            await expect("profile storage: a CefWindow closed while its profile loads closes its browser") {
                try await profile.ready()
                return (await waitUntil { window.isClosed && browser.state == .closed }, "\(browser.state)")
            }
            check("profile storage: … and Chromium never creates it",
                  !CefRuntime.shared.browsers.contains { $0 === browser })
        }
    }

    // MARK: Settings while loading

    static func loadedProfileChecks() async {
        let profile = brandNewProfile("settings")
        _ = profile.preferences.value(named: "intl.accept_languages")
        await expect("profile storage: preferences refuse a change while the profile loads, and say so") {
            do {
                try profile.preferences.setValue(19, named: "webkit.webprefs.default_font_size")
                return (profile.isReady, "accepted before ready")
            } catch {
                return ("\(error)".contains("loading"), "\(error)")
            }
        }
        let origin = URL(string: "https://cefswift.test")!
        profile.siteSettings.set(.block, for: .geolocation, origin: origin)
        await expect("profile storage: ready() waits for a new profile") {
            try await profile.ready()
            return profile.isReady
        }
        check("profile storage: a site setting made while the profile loaded applies once it has", await waitUntil(timeout: .seconds(3)) {
            profile.siteSettings.setting(for: .geolocation, origin: origin) == .block
        })
        await expect("profile storage: preferences work once ready") {
            try profile.preferences.setValue(19, named: "webkit.webprefs.default_font_size")
            return profile.preferences.value(named: "webkit.webprefs.default_font_size")?.intValue == 19
        }
        await expect("profile storage: the default and incognito profiles are ready at once") {
            let incognito = CefProfile.incognito()
            try await CefProfile.default.ready()
            try await incognito.ready()
            return CefProfile.default.isReady && incognito.isReady
        }
    }

    // MARK: Profiles Chromium cannot load

    static func unavailableProfileChecks() async {
        let root = rootCacheDirectory
        do {
            // Something else where the profile's directory goes.
            let profile = brandNewProfile("blocked")
            let path = root.appendingPathComponent(ProfileDirectoryNames.directoryName(for: profile.id))
            FileManager.default.createFile(atPath: path.path, contents: Data("not a profile".utf8))
            let browser = inProfile(profile, "https://cefswift.test/blocked.html")
            let view = hostWindowed(browser)
            await expect("profile storage: a profile whose directory cannot be made fails, loudly") {
                do {
                    try await profile.ready()
                    return (false, "ready")
                } catch CefError.profileUnavailable(let reason) {
                    return (reason.contains(path.path), reason)
                }
            }
            await expect("profile storage: … and its browser closes instead of opening in memory") {
                do {
                    try await browser.ready()
                    return (false, "\(browser.state)")
                } catch CefError.profileUnavailable {
                    return (browser.state == .closed, "\(browser.state)")
                }
            }
            await expect("profile storage: … and its preferences say why they cannot be changed") {
                do {
                    try profile.preferences.setValue(19, named: "webkit.webprefs.default_font_size")
                    return (false, "accepted")
                } catch {
                    return ("\(error)".contains("could not load"), "\(error)")
                }
            }
            await expect("profile storage: … and its requests throw rather than go out without its cookies") {
                do {
                    _ = try await profile.data(from: URL(string: "https://cefswift.test/plain.html")!)
                    return (false, "loaded")
                } catch CefError.profileUnavailable {
                    return (true, "")
                }
            }
            view.removeFromSuperview()
            try? FileManager.default.removeItem(at: path)
        }
        do {
            // Chromium's own rule: a profile directory anywhere but directly
            // in the root cache directory. Chromium logs "Cannot create
            // profile at path" and would give an in-memory profile.
            let profile = brandNewProfile("nested")
            let nested = root.appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profile.id, isDirectory: true)
            CefProfile.testDirectories[profile.id] = nested
            defer { CefProfile.testDirectories[profile.id] = nil }
            let browser = inProfile(profile, "https://cefswift.test/nested.html")
            let view = hostOffscreen(browser)
            await expect("profile storage: a profile Chromium will not make on disk fails, not in memory") {
                do {
                    try await profile.ready()
                    return (false, "ready")
                } catch CefError.profileUnavailable(let reason) {
                    return (reason.contains("in memory"), reason)
                }
            }
            check("profile storage: … and its offscreen browser closes without a page",
                  await waitUntil(timeout: .seconds(5)) { browser.state == .closed } && browser.title.isEmpty
                    && !CefRuntime.shared.browsers.contains { $0 === browser },
                  detail: "\(browser.state) \(browser.title)")
            view.removeFromSuperview()
            try? FileManager.default.removeItem(at: root.appendingPathComponent("Profiles"))
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Two launches

    /// Runs in two launches on one root cache directory: the first stores
    /// data in two persistent profiles, the default one and an incognito
    /// one; the second, a new process, finds each where it belongs.
    static func profilePersistenceProbeChecks() async {
        let phase = ProcessInfo.processInfo.environment[profilePhaseEnvironmentKey] ?? "1"
        let root = rootCacheDirectory
        let alpha = CefProfile.persistent(id: "alpha"), beta = CefProfile.persistent(id: "beta")
        let profiles: [(name: String, profile: CefProfile)] = [("alpha", alpha), ("beta", beta), ("default", .default)]
        func page(_ name: String) -> URL { URL(string: "https://cefswift.test/stored-\(name).html")! }
        let directories = [alpha, beta].map { root.appendingPathComponent(ProfileDirectoryNames.directoryName(for: $0.id)) }

        if phase == "1" {
            check("first launch: no profile directory yet", directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            // Stored from a page in a Chrome-style window, which history
            // records, then read back in the same launch.
            for (name, profile) in profiles {
                let browser = inProfile(profile, page(name).absoluteString)
                let window = CefWindow(browser: browser)
                window.show()
                guard await loaded(browser, title: "stored-\(name)") else {
                    check("first launch: \(name) page loads", false, detail: browser.title)
                    continue
                }
                await expect("first launch: \(name) stores a cookie and local storage") {
                    _ = try await browser.evaluateJavaScript("""
                        document.cookie = 'who=\(name); max-age=86400; path=/; secure';
                        localStorage.setItem('who', '\(name)'); 0
                        """)
                    let cookies = await profile.cookies(for: page(name))
                    return (cookies.contains { $0.name == "who" && $0.value == name }, cookies.map(\.value).joined(separator: ","))
                }
                window.close()
                _ = await waitUntil { window.isClosed }
            }
            await expect("first launch: profiles share nothing") {
                var values: [[String]] = []
            for (name, profile) in profiles {
                values.append(await profile.cookies(for: page(name)).filter { $0.name == "who" }.map(\.value))
            }
                return (values == [["alpha"], ["beta"], ["default"]], "\(values)")
            }
            await expect("first launch: history is kept per profile") {
                let seen = await waitUntilAsync { (try? await alpha.history.search("stored").contains { $0.url == page("alpha") }) == true }
                let elsewhere = try await beta.history.search("stored").map(\.url)
                return (seen && !elsewhere.contains(page("alpha")), "\(seen) \(elsewhere)")
            }
            // Incognito: stores the same way, and leaves nothing.
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            let incognito = CefProfile.incognito()
            let browser = inProfile(incognito, page("incognito").absoluteString)
            let view = hostWindowed(browser)
            if await loaded(browser, title: "stored-incognito") {
                _ = try? await browser.evaluateJavaScript(
                    "document.cookie = 'incognito=1; max-age=86400; path=/; secure'; localStorage.setItem('incognito', '1'); 0")
                check("first launch: incognito sees its own cookie only",
                      await incognito.cookies(for: page("incognito")).map(\.name) == ["incognito"])
            } else {
                check("first launch: incognito page loads", false)
            }
            view.removeFromSuperview()
            browser.close(force: true)
            let added = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).subtracting(before)
            check("first launch: incognito adds nothing to the root cache directory",
                  added.allSatisfy { !$0.hasPrefix("Profile") }, detail: added.sorted().joined(separator: ", "))
            check("first launch: each persistent profile has its directory", directories.allSatisfy(isDirectory))
            check("first launch: nothing goes under a Profiles directory",
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("Profiles").path))
            return
        }

        check("second launch: the profiles' directories are there, with their cookie stores",
              directories.allSatisfy { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Cookies").path) })
        await expect("second launch: the profiles' cookies are read back before any browser") {
            var values: [[String]] = []
            for (name, profile) in profiles {
                values.append(await profile.cookies(for: page(name)).filter { $0.name == "who" }.map(\.value))
            }
            return (values == [["alpha"], ["beta"], ["default"]], "\(values)")
        }
        for (name, profile) in profiles {
            let browser = inProfile(profile, page(name).absoluteString)
            // Offscreen this time.
            let view = hostOffscreen(browser)
            guard await loaded(browser, title: "stored-\(name)") else {
                check("second launch: \(name) page loads", false, detail: browser.title)
                view.removeFromSuperview()
                continue
            }
            await expect("second launch: \(name)'s page finds its cookie and local storage") {
                let found = try await browser.evaluateJavaScript(
                    "[document.cookie, localStorage.getItem('who'), localStorage.getItem('incognito')].join('|')").stringValue ?? ""
                return (found == "who=\(name)|\(name)|", found)
            }
            view.removeFromSuperview()
            browser.close(force: true)
        }
        await expect("second launch: history survives, in its own profile only") {
            var found: [String] = []
            for (name, profile) in profiles {
                let urls = try await profile.history.search("stored").map(\.url)
                found.append(profiles.map(\.name).filter { urls.contains(page($0)) }.joined(separator: "+"))
                _ = name
            }
            return (found == ["alpha", "beta", "default"], found.joined(separator: ", "))
        }
        await expect("second launch: nothing of the incognito profile is left") {
            var names: [String] = []
            for (_, profile) in profiles { names += await profile.cookies(for: page("incognito")).map(\.name) }
            return (!names.contains("incognito"), names.joined(separator: ","))
        }
    }
}

/// The profile directory names CefKit gives persistent profiles, as the
/// checks expect them: `Profile-`, then the identifier percent-encoded.
enum ProfileDirectoryNames {
    static func directoryName(for id: String) -> String {
        var name = "Profile-"
        for byte in id.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"):
                name.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                name += String(format: "%%%02X", byte)
            }
        }
        return name
    }
}
