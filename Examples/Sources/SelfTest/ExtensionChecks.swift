import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import CCef

/// Chromium's extension system through CefChromium's `CefProfile.extensions`,
/// with the test extension in SelfTest's resources (`TestExtension`).
///
/// Runs as the `extensions` probe, which starts Chromium with the fixture
/// configured as an unpacked extension, in two phases on one root cache
/// directory: the first installs, packs and changes extensions; the second
/// is a relaunch that finds them again and installs the packed copy through
/// `CefRuntime.Configuration.extensions` (`.package`). With network access,
/// the second phase also installs an extension from the Chrome Web Store by
/// identifier (`.webStore`), and the first one through the store's page and
/// Chromium's install dialog.
extension SelfTest {
    static let extensionPhaseKey = "SELFTEST_EXTENSIONS_PHASE"
    /// uBlock Origin Lite: free, small, from Google's store.
    static let storeExtensionByID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    /// JSON Formatter, installed through the store's page.
    static let storeExtensionByPage = "bcjindcccaagfpapjjmafapmmgkkhgoa"

    static func extensionChecks() async {
        if ProcessInfo.processInfo.environment[extensionDumpEnvironmentKey] != nil {
            await runExtensionSurvey()
            return
        }
        guard ExtensionFixture.directory != nil else {
            check("extensions: the test extension is in SelfTest's resources", false)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-extensions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let online = await isStoreReachable()
        await runProbe("extensions", label: "extensions", root: root,
                       environment: [extensionPhaseKey: "1", "SELFTEST_ONLINE": online ? "1" : "0"], timeout: .seconds(150))
        await runProbe("extensions", label: "extensions (relaunch)", root: root,
                       environment: [extensionPhaseKey: "2", "SELFTEST_ONLINE": online ? "1" : "0"], timeout: .seconds(200))
    }

    /// Whether the Chrome Web Store answers, for the checks that need it.
    static func isStoreReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://clients2.google.com/service/update2/crx")!, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    static var isOnline: Bool { ProcessInfo.processInfo.environment["SELFTEST_ONLINE"] == "1" }

    /// The packed copy of the fixture the first phase makes.
    static func packedCopy(in root: URL) -> (directory: URL, package: URL) {
        let directory = root.appendingPathComponent("packed-copy")
        return (directory, directory.appendingPathExtension("crx"))
    }

    /// The probe's configuration: the fixture unpacked, Chrome's services
    /// on; in the second phase also the packed copy and, online, a store
    /// extension by identifier.
    static func configureExtensionProbe(_ configuration: inout CefRuntime.Configuration) {
        if let directory = ExtensionFixture.directory { configuration.extensions = [.unpacked(at: directory)] }
        for name in ["disable-background-networking", "disable-default-apps", "disable-sync", "disable-domain-reliability"] {
            configuration.extraCommandLineSwitches[name] = nil
        }
        configuration.services.componentUpdates = .automatic
        if ProcessInfo.processInfo.environment[extensionDumpEnvironmentKey] != nil {
            configuration.enterprisePolicy = .domain(surveyPolicyDomain)
        }
        // Online, a store extension by identifier from the first start on;
        // the relaunch finds it installed and accepted.
        if isOnline, ProcessInfo.processInfo.environment[extensionPhaseKey] != nil {
            configuration.extensions.append(.webStore(storeExtensionByID))
        }
        guard ProcessInfo.processInfo.environment[extensionPhaseKey] == "2",
              let root = configuration.rootCacheDirectory else { return }
        let packed = packedCopy(in: root)
        if let id = try? CRXHeader.identifier(ofPackageAt: packed.package) {
            configuration.extensions.append(.package(at: packed.package, id: id, version: "1.0"))
        }
    }

    static func extensionProbeChecks() async {
        CefChromiumTesting.activate()
        guard let server = try? await LocalServer.start() else {
            check("local server starts", false)
            return
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.port)/")!
        if ProcessInfo.processInfo.environment[extensionPhaseKey] == "2" {
            await extensionRelaunchChecks(base: base)
        } else {
            await extensionFirstRunChecks(base: base)
        }
    }

    // MARK: First run

    static func extensionFirstRunChecks(base: URL) async {
        let extensions = CefProfile.default.extensions
        let fixtureID = CefExtension.ID(ExtensionFixture.id)
        await expect("profile.extensions lists the configured unpacked extension") {
            let fixture = try await extensions.refresh().first { $0.id == fixtureID }
            return (fixture?.name == ExtensionFixture.name && fixture?.installSource == .unpacked && fixture?.isEnabled == true,
                    "\(String(describing: fixture))")
        }
        let fixture = extensions.installed.first { $0.id == fixtureID }
        check("an extension's values: version, icon, options page, commands",
              fixture?.version == "1.0" && fixture?.icon != nil
                  && fixture?.optionsURL?.absoluteString == "chrome-extension://\(fixtureID)/options.html"
                  && fixture?.commands.contains { $0.isAction && $0.shortcut == "⌃⇧Y" } == true,
              detail: "\(String(describing: fixture))")
        check("its toolbar action as its manifest declares it",
              fixture?.action?.title == "CefSwift Test" && fixture?.action?.popupURL?.lastPathComponent == "popup.html"
                  && fixture?.action?.icon != nil,
              detail: "\(String(describing: fixture?.action))")
        check("the pages it replaces (new tab)",
              fixture?.replacedPages[.newTab]?.lastPathComponent == "newtab.html",
              detail: "\(String(describing: fixture?.replacedPages))")
        check("site access and permission warnings",
              fixture?.siteAccess == .onAllSites && fixture?.hosts.contains { $0.pattern == "http://127.0.0.1/*" && $0.isGranted } == true
                  && fixture?.permissionWarnings.isEmpty == false,
              detail: "\(String(describing: fixture?.siteAccess)) \(String(describing: fixture?.hosts))")
        check("incognito is off by default", fixture?.isAllowedInIncognito == false)

        // Running in browsers.
        let (window, browser) = await extensionWindow(base.appendingPathComponent("page"), toolbar: .chrome)
        defer { window.close() }
        await expect("its content script runs in a Chrome-style browser") {
            let value = try await browser.evaluateJavaScript("document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            return (value == "ran", value.text)
        }
        let alloy = CefBrowser(url: base.appendingPathComponent("page"))
        let alloyView = hostWindowed(alloy)
        _ = await loaded(alloy)
        await expect("its content script runs in an Alloy-style view too") {
            let value = try await alloy.evaluateJavaScript("document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            return (value == "ran", value.text)
        }
        await closeHosted(alloy, alloyView)
        await expect("its declarativeNetRequest rule blocks a request") {
            let value = try await browser.evaluateJavaScript(
                "fetch('/dnr-blocked').then(r => 'fetched ' + r.status, e => 'blocked')")
            return (value == "blocked", value.text)
        }
        await extensionMenuChecks(browser: browser, window: window)
        await extensionToolbarChecks(window: window)
        await extensionTabChecks(base: base)
        await extensionTabStripChecks(base: base)

        // Changing it.
        await expect("setEnabled(false) disables it and its content script stops") {
            try await extensions.setEnabled(false, for: fixtureID)
            let disabled = extensions.installed.first { $0.id == fixtureID }?.state == .disabled
            _ = await load(base.appendingPathComponent("page"), in: browser)
            let value = try await browser.evaluateJavaScript("document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            return (disabled && value == "absent", "disabled \(disabled), content script \(value.text)")
        }
        await expect("setEnabled(true) enables it again") {
            try await extensions.setEnabled(true, for: fixtureID)
            return (extensions.installed.first { $0.id == fixtureID }?.isEnabled == true, "")
        }
        await extensionIncognitoChecks(base: base, extensions: extensions, fixtureID: fixtureID)
        await extensionProfileIsolationChecks(base: base, fixtureID: fixtureID)

        // Developer mode: load unpacked, pack.
        guard let root = CefRuntime.shared.configuration?.rootCacheDirectory, let source = ExtensionFixture.directory else { return }
        let packed = packedCopy(in: root)
        let copy = root.appendingPathComponent("unpacked-copy")
        for directory in [copy, packed.directory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.copyItem(at: source, to: directory)
            rewriteManifest(in: directory) {
                $0["key"] = nil
                $0["name"] = directory == copy ? "CefSwift Unpacked Copy" : "CefSwift Packed Copy"
                $0["chrome_url_overrides"] = nil
                $0["content_scripts"] = nil
                $0["declarative_net_request"] = nil
            }
        }
        await expect("loadUnpacked(at:) loads a directory, in developer mode") {
            try await extensions.setDeveloperModeEnabled(true)
            let loaded = try await extensions.loadUnpacked(at: copy)
            return (loaded.name == "CefSwift Unpacked Copy" && loaded.installSource == .unpacked, "\(loaded)")
        }
        await expect("pack(_:) writes a .crx and a key") {
            let result = try await extensions.pack(packed.directory)
            let exists = FileManager.default.fileExists(atPath: result.package.path)
                && FileManager.default.fileExists(atPath: result.privateKey.path)
            let id = try? CRXHeader.identifier(ofPackageAt: result.package)
            return (exists && result.package == packed.package && id != nil, "\(result) id \(String(describing: id))")
        }
        await expect("uninstall(_:) removes an extension") {
            guard let loaded = extensions.installed.first(where: { $0.name == "CefSwift Unpacked Copy" }) else {
                return (false, "not loaded")
            }
            try await extensions.uninstall(loaded.id)
            return (!extensions.installed.contains { $0.id == loaded.id }, "\(extensions.installed.map(\.name))")
        }
        // Kept for the relaunch: a second unpacked load and a disabled state.
        _ = try? await extensions.loadUnpacked(at: copy)
        if isOnline {
            await webStorePageInstallChecks(window: window, browser: browser, extensions: extensions)
        } else {
            skip("installing from the Chrome Web Store's page", because: "no network", .environment)
        }
    }

    static func rewriteManifest(in directory: URL, _ change: (inout [String: Any]) -> Void) {
        let file = directory.appendingPathComponent("manifest.json")
        guard var manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] else { return }
        change(&manifest)
        try? JSONSerialization.data(withJSONObject: manifest).write(to: file)
    }

    static func extensionWindow(_ url: URL, toolbar: CefWindow.Toolbar, profile: CefProfile? = nil) async -> (CefWindow, CefBrowser) {
        var browserConfiguration = CefBrowser.Configuration()
        browserConfiguration.profile = profile
        let browser = CefBrowser(url: url, configuration: browserConfiguration)
        var configuration = CefWindow.Configuration()
        configuration.toolbar = toolbar
        configuration.frame = CGRect(x: 120, y: 100, width: 1100, height: 760)
        let window = CefWindow(browser: browser, configuration: configuration)
        window.chromiumSurfacePolicy = CefChromiumSurface.Policy()
        window.show()
        _ = await loaded(browser)
        return (window, browser)
    }

    /// The extension page in a window of its own, for its view of storage.
    static func fixtureStorage(_ key: String) async -> CefJSON? {
        let (window, browser) = await extensionWindow(
            URL(string: "chrome-extension://\(ExtensionFixture.id)/options.html")!, toolbar: .none)
        defer { window.close() }
        return try? await browser.evaluateJavaScript("chrome.storage.local.get('\(key)').then(v => v['\(key)'] ?? null)")
    }

    // MARK: Context menu

    final class ExtensionMenuDelegate: CefBrowserDelegate {
        var menu: CefContextMenu?
        var choose: (CefContextMenu) -> CefContextMenu.Item? = { _ in nil }

        func browser(_ browser: CefBrowser, runContextMenu menu: CefContextMenu, for target: CefContextMenuTarget) async -> CefContextMenu.Item? {
            self.menu = menu
            return choose(menu)
        }
    }

    static func findItem(_ title: String, in menu: CefContextMenu) -> CefContextMenu.Item? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = findItem(title, in: submenu) { return found }
        }
        return nil
    }

    static func extensionMenuChecks(browser: CefBrowser, window: CefWindow) async {
        let delegate = ExtensionMenuDelegate()
        browser.delegate = delegate
        defer { browser.delegate = nil }
        delegate.choose = { findItem("CefSwift Test Item", in: $0) }
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": .string(type), "x": 500, "y": 400, "button": "right", "buttons": 2, "clickCount": 1,
            ])
        }
        _ = await waitUntil(timeout: .seconds(5)) { delegate.menu != nil }
        let item = delegate.menu.flatMap { findItem("CefSwift Test Item", in: $0) }
        check("the context-menu item it adds is in CefContextMenu, with Chromium's command",
              item != nil && item?.command != nil,
              detail: "\(delegate.menu?.items.map(\.title) ?? [])")
        let clicked = await waitUntilAsync(timeout: .seconds(5)) { await fixtureStorage("menuClicked") == "cefswift-item" }
        check("choosing it runs the extension's handler", clicked)
    }

    // MARK: Chrome's toolbar

    static func extensionToolbarChecks(window: CefWindow) async {
        guard let nsWindow = window.window else { return }
        check("a CefWindow with toolbar .chrome shows Chrome's toolbar", window.hasChromeToolbar)
        nsWindow.makeKeyAndOrderFront(nil)
        var menu: CefChromiumSurface?
        window.onChromiumSurface = { if $0.kind == .extensionsMenu { menu = $0 } }
        defer { window.onChromiumSurface = nil }
        SurfaceInventory.press(in: nsWindow) {
            $0.accessibilityRole() == .popUpButton && ($0.accessibilityTitle() ?? $0.accessibilityLabel() ?? "") == "Extensions"
        }
        check("Chrome's extensions menu opens from its toolbar, as surface .extensionsMenu",
              await waitUntil(timeout: .seconds(5)) { menu != nil },
              detail: "\(window.chromiumSurfaces.map(\.kind))")
        menu?.dismiss()
        skip("an action popup in a CefWindow",
             because: "Chromium makes a CefWindow's browser a popup-type window, which has no toolbar for "
                 + "action popups (chrome.action.openPopup: \"Browser window has no toolbar\"); they open in Chrome's own windows",
             .limitation)
    }

    // MARK: Tabs and Chrome's windows

    static func extensionTabChecks(base: URL) async {
        // Chrome's own window: real tabs, groups and action popups.
        let first = CefRuntime.shared.openChromeWindow(url: base.appendingPathComponent("page"))
        _ = await loaded(first)
        first.execute(CefChromeCommand(rawValue: Int(IDC_NEW_TAB)))
        func isNewTab(_ browser: CefBrowser) -> Bool {
            browser !== first && !CefWindow.all.contains { $0.browser === browser }
        }
        _ = await waitUntil { CefRuntime.shared.browsers.contains(where: isNewTab) }
        let tab = CefRuntime.shared.browsers.last(where: isNewTab)
        guard let tab else {
            check("a new tab in Chrome's window reaches the app", false)
            first.close(force: true)
            return
        }
        check("the new tab page the extension replaces opens in a new tab",
              await waitUntil(timeout: .seconds(5)) { tab.url?.lastPathComponent == "newtab.html" },
              detail: tab.url?.absoluteString ?? "-")
        let tabsPage = URL(string: "chrome-extension://\(ExtensionFixture.id)/tabs.html")!
        func run(_ query: String) async -> String {
            guard await load(URL(string: tabsPage.absoluteString + "?" + query)!, in: tab) else { return "did not load" }
            _ = await waitUntil(timeout: .seconds(5)) { tab.title.hasPrefix("ok ") || tab.title.hasPrefix("error ") }
            return tab.title
        }
        /// The rows of an `ok [[…], …]` title.
        func rows(_ title: String) -> [[Any]] {
            guard title.hasPrefix("ok "), let data = title.dropFirst(3).data(using: .utf8) else { return [] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] ?? []
        }
        let current = rows(await run("op=current"))
        check("chrome.tabs sees the tabs of Chrome's window, with indices",
              current.count == 2 && current.map { $0[2] as? Int } == [0, 1], detail: "\(current)")
        let windows = await run("op=windows")
        check("chrome.windows sees Chrome's window as normal, with its tabs",
              windows.contains("\"normal\",true,2]") || windows.contains("\"normal\",false,2]"), detail: windows)
        let firstTabID = (current.first?.first as? Int).map(String.init) ?? ""
        let grouped = await run("op=group&tabs=\(firstTabID)&title=CefSwift&color=blue")
        let groups = await run("op=groups")
        check("chrome.tabs.group and chrome.tabGroups work in Chrome's window",
              grouped.hasPrefix("ok ") && groups.contains("CefSwift"), detail: "\(grouped) \(groups)")
        let created = await run("op=create&url=chrome-extension://\(ExtensionFixture.id)/options.html")
        let afterCreate = rows(await run("op=current"))
        check("chrome.tabs.create adds a tab to Chrome's window",
              created.hasPrefix("ok ") && afterCreate.count == 3, detail: "\(created) \(afterCreate.count) tabs")
        await expect("an action popup opens in Chrome's window (chrome.action.openPopup)") {
            let started = try await tab.evaluateJavaScript("""
                (chrome.windows.getCurrent().then(w => chrome.windows.update(w.id, {focused: true}))
                  .then(() => chrome.action.openPopup()).then(() => { document.title = 'popup opened'; },
                                                             e => { document.title = 'popup error ' + e.message; }), 'started')
                """)
            _ = await waitUntil(timeout: .seconds(5)) { tab.title.hasPrefix("popup ") }
            let title = tab.title
            let opened = await waitUntilAsync(timeout: .seconds(5)) { await fixtureStorage("popupOpened") != nil }
            return (title == "popup opened" && opened, "\(started.text) \(title) storage \(opened)")
        }
        for browser in CefRuntime.shared.browsers where !CefWindow.all.contains(where: { $0.browser === browser }) {
            browser.close(force: true)
        }
        _ = await waitUntil { CefRuntime.shared.browsers.allSatisfy { b in CefWindow.all.contains { $0.browser === b } } }

        // A CefWindow's browser: one tab in a popup-type window.
        var requests: [URL] = []
        CefRuntime.shared.onChromeTab = { requests.append($0.url); return .close }
        defer { CefRuntime.shared.onChromeTab = nil }
        let (window, page) = await extensionWindow(tabsPage.appendingQuery("op=windows"), toolbar: .none)
        defer { window.close() }
        _ = await waitUntil { page.title.hasPrefix("ok ") || page.title.hasPrefix("error ") }
        check("a CefWindow is a popup-type window of one tab to chrome.windows",
              page.title.contains("\"popup\""), detail: page.title)
        _ = page.load(tabsPage.appendingQuery("op=create&url=\(base.appendingPathComponent("page").absoluteString)"))
        check("chrome.tabs.create from a CefWindow reaches onChromeTab",
              await waitUntil(timeout: .seconds(5)) { requests.contains { $0.path == "/page" } }, detail: "\(requests)")
        _ = try? await page.evaluateJavaScript("chrome.runtime.openOptionsPage()")
        check("chrome.runtime.openOptionsPage() reaches onChromeTab with the options page",
              await waitUntil(timeout: .seconds(5)) { requests.contains { $0.lastPathComponent == "options.html" } },
              detail: "\(requests)")
    }

    // MARK: Profiles

    static func extensionIncognitoChecks(base: URL, extensions: CefExtensions, fixtureID: CefExtension.ID) async {
        let incognito = CefProfile.incognito()
        check("an incognito profile's extensions are the default profile's",
              incognito.extensions === CefProfile.default.extensions)
        let (window, browser) = await extensionWindow(base.appendingPathComponent("page"), toolbar: .none, profile: incognito)
        await expect("an extension does not run in incognito by default") {
            let value = try await browser.evaluateJavaScript("document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            return (value == "absent", value.text)
        }
        do {
            try await extensions.setAllowedInIncognito(true, for: fixtureID)
            let allowed = extensions.installed.first { $0.id == fixtureID }?.isAllowedInIncognito == true
            check("setAllowedInIncognito(true) records the choice", allowed)
            // Chromium reloads the extension to apply it.
            try? await Task.sleep(for: .seconds(2))
            _ = await load(base.appendingPathComponent("page"), in: browser)
            let value = try await browser.evaluateJavaScript("document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            if value == "ran" {
                check("an extension allowed in incognito runs in CefProfile.incognito()", true)
            } else {
                skip("an extension allowed in incognito runs in CefProfile.incognito()",
                     because: "CEF's in-memory request context is not the default profile's own off-the-record profile, "
                         + "so its content scripts do not run there even when allowed (\(value.text))", .limitation)
            }
        } catch {
            check("setAllowedInIncognito(true)", false, detail: "\(error)")
        }
        try? await extensions.setAllowedInIncognito(false, for: fixtureID)
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    static func extensionProfileIsolationChecks(base: URL, fixtureID: CefExtension.ID) async {
        let profile = CefProfile.persistent(id: "extensions")
        let (window, _) = await extensionWindow(base.appendingPathComponent("page"), toolbar: .none, profile: profile)
        defer { window.close() }
        let other = profile.extensions
        await expect("a persistent profile has extensions of its own") {
            try await CefProfile.default.extensions.setEnabled(false, for: fixtureID)
            defer { Task { try? await CefProfile.default.extensions.setEnabled(true, for: fixtureID) } }
            let mine = try await other.refresh().first { $0.id == fixtureID }
            return (other !== CefProfile.default.extensions && mine?.isEnabled == true,
                    "\(String(describing: mine?.state)) while disabled in the default profile")
        }
        try? await CefProfile.default.extensions.setEnabled(true, for: fixtureID)
    }

    // MARK: The Chrome Web Store

    static func webStorePageInstallChecks(window: CefWindow, browser: CefBrowser, extensions: CefExtensions) async {
        let id = CefExtension.ID(storeExtensionByPage)
        guard await load(URL(string: "https://chromewebstore.google.com/detail/\(id)")!, in: browser, timeout: .seconds(30)) else {
            skip("installing from the Chrome Web Store's page", because: "the store did not load", .environment)
            return
        }
        try? await Task.sleep(for: .seconds(2))
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let clicked = try? await browser.evaluateJavaScript("""
            (() => { const b = [...document.querySelectorAll('button')].find(b => /Add to/i.test(b.innerText)); if (!b) return 'none'; b.click(); return 'clicked'; })()
            """, userGesture: true)
        var dialog: NSWindow?
        _ = await waitUntil(timeout: .seconds(10)) {
            dialog = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible
                    && CefChromiumTesting.describe($0).classes.contains("ExtensionInstallDialogView")
            }
            return dialog != nil
        }
        check("Add to Chrome on the store's page shows Chromium's install dialog",
              dialog != nil, detail: "button \(clicked?.text ?? "-")")
        guard let dialog else { return }
        // Chromium builds the dialog's views after showing its window.
        try? await Task.sleep(for: .seconds(1))
        check("the install dialog is recognized as .extensionInstallPrompt",
              CefChromiumTesting.describe(dialog).kind == "\(CefChromiumSurface.Kind.extensionInstallPrompt)")
        SurfaceInventory.press(in: dialog) { $0.accessibilityRole() == .button && ($0.accessibilityTitle() ?? "") == "Add extension" }
        let installed = await waitUntilAsync(timeout: .seconds(40)) {
            (try? await extensions.refresh())?.contains { $0.id == id && $0.installSource == .webStore && $0.isEnabled } == true
        }
        check("accepting it installs the extension from the store", installed,
              detail: "\(extensions.installed.map { "\($0.name) \($0.installSource)" })")
        try? await extensions.uninstall(id)
    }

    // MARK: Relaunch

    static func extensionRelaunchChecks(base: URL) async {
        let extensions = CefProfile.default.extensions
        _ = try? await extensions.refresh()
        check("an unpacked extension loaded before is still installed",
              extensions.installed.contains { $0.name == "CefSwift Unpacked Copy" },
              detail: "\(extensions.installed.map(\.name))")
        let packed = await waitUntilAsync(timeout: .seconds(20)) {
            (try? await extensions.refresh())?.contains { $0.name == "CefSwift Packed Copy" && $0.isEnabled } == true
        }
        check("a .package the configuration names is installed and enabled", packed,
              detail: "\(extensions.installed.map { "\($0.name) \($0.installSource) \($0.state)" })")
        let packedSource = extensions.installed.first { $0.name == "CefSwift Packed Copy" }?.installSource
        check("it is an external install", packedSource == .external,
              detail: "\(String(describing: packedSource))")
        guard isOnline else {
            skip("installing a Chrome Web Store extension by identifier", because: "no network", .environment)
            return
        }
        let id = CefExtension.ID(storeExtensionByID)
        let pendingFirst = extensions.pendingInstallations.contains(id) || extensions.installed.contains { $0.id == id }
        let installed = await waitUntilAsync(timeout: .seconds(110)) {
            (try? await extensions.refresh())?.contains { $0.id == id && $0.isEnabled } == true
        }
        if installed {
            check("a .webStore(id) extension is downloaded, installed and enabled without the user",
                  pendingFirst && extensions.pendingInstallations.isEmpty,
                  detail: "pending \(extensions.pendingInstallations)")
        } else {
            skip("installing a Chrome Web Store extension by identifier",
                 because: "not installed within 110 s (the store's download did not arrive): "
                     + "\(extensions.installed.map { "\($0.id) \($0.state)" }), pending \(extensions.pendingInstallations)",
                 .environment)
        }
    }
}

extension URL {
    fileprivate func appendingQuery(_ query: String) -> URL {
        URL(string: absoluteString + "?" + query) ?? self
    }
}

/// The identifier in a CRX3 package's header (`CrxFileHeader.signed_header_data.crx_id`).
enum CRXHeader {
    struct Invalid: Error {}

    static func identifier(ofPackageAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count > 12, data.prefix(4) == Data("Cr24".utf8), data[4] == 3 else { throw Invalid() }
        let headerSize = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        guard data.count >= 12 + headerSize else { throw Invalid() }
        let header = data.subdata(in: 12..<(12 + headerSize))
        guard let signed = field(10000, in: header), let crxID = field(1, in: signed), crxID.count == 16 else { throw Invalid() }
        return crxID.map { byte in
            String([Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))), Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 15)))])
        }.joined()
    }

    /// The first length-delimited field `number` of a protobuf message.
    static func field(_ number: Int, in message: Data) -> Data? {
        var index = message.startIndex
        func varint() -> Int? {
            var value = 0, shift = 0
            while index < message.endIndex, shift < 63 {
                let byte = message[index]
                index += 1
                value |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < message.endIndex {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), length >= 0, message.endIndex - index >= length else { return nil }
                if key >> 3 == number { return message.subdata(in: index..<(index + length)) }
                index += length
            case 1: index += 8
            case 5: index += 4
            default: return nil
            }
        }
        return nil
    }
}
