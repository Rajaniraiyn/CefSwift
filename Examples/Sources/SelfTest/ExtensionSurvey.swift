import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import CCef

/// A survey of what Chromium's extension system does in CEF:
/// `SELFTEST_EXTENSIONS_DUMP=1` runs the `extensionSurvey` probe, which
/// loads the test extension and prints `NOTE` lines of what it finds, for
/// the evidence in docs/design-notes.md. `SELFTEST_EXTENSIONS_STORE=<id>`
/// also opens that extension's Chrome Web Store page (network).
extension SelfTest {
    static let extensionDumpEnvironmentKey = "SELFTEST_EXTENSIONS_DUMP"
    static let extensionStoreEnvironmentKey = "SELFTEST_EXTENSIONS_STORE"

    static func note(_ label: String, _ value: Any) {
        let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
        print("NOTE survey: \(label): \(text.prefix(3000))")
    }

    static func surveyEvaluate(_ browser: CefBrowser, _ label: String, _ script: String) async {
        do {
            let value = try await browser.evaluateJavaScript(script, timeout: .seconds(10))
            note(label, value.text)
        } catch {
            note(label, "error \(error)")
        }
    }

    static func extensionSurveyProbe() async {
        CefChromiumTesting.activate()
        guard let server = try? await LocalServer.start() else { return note("server", "failed") }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.port)/")!
        let id = ExtensionFixture.id
        if ProcessInfo.processInfo.environment[extensionDumpEnvironmentKey] == "2" {
            await surveyChromeWindows(base: base)
            check("extension survey: finished", true)
            return
        }
        if ProcessInfo.processInfo.environment[extensionDumpEnvironmentKey] == "3" {
            await surveyToolbarWindow(base: base)
            check("extension survey: finished", true)
            return
        }
        // A native messaging host that echoes, in the user data directory.
        if let root = CefRuntime.shared.configuration?.resolvedRootCacheDirectory {
            let hosts = root.appendingPathComponent("NativeMessagingHosts")
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            let script = root.appendingPathComponent("echo-host.sh")
            try? Data("#!/bin/sh\nexec /bin/cat\n".utf8).write(to: script)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let manifest = """
                {"name": "dev.cefswift.selftest", "description": "echo", "path": "\(script.path)", "type": "stdio",
                 "allowed_origins": ["chrome-extension://\(id)/"]}
                """
            try? Data(manifest.utf8).write(to: hosts.appendingPathComponent("dev.cefswift.selftest.json"))
        }

        // 1. The extensions WebUI host's APIs.
        let (hostWindow, host) = await surveyWindow(URL(string: "chrome://extensions/strings.m.js")!, toolbar: .chrome)
        await surveyEvaluate(host, "extensions host chrome keys", "Object.keys(chrome).sort().join(',')")
        await surveyEvaluate(host, "developerPrivate functions",
            "chrome.developerPrivate ? Object.keys(chrome.developerPrivate).sort().join(',') : 'none'")
        await surveyEvaluate(host, "management functions",
            "chrome.management ? Object.keys(chrome.management).sort().join(',') : 'none'")
        await surveyEvaluate(host, "getExtensionsInfo", """
            (async () => JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true, includeTerminated: true}))
              .map(e => ({id: e.id, name: e.name, location: e.location, state: e.state, type: e.type, keys: Object.keys(e).sort()}))))()
            """)
        await surveyEvaluate(host, "fixture info", """
            (async () => JSON.stringify(await chrome.developerPrivate.getExtensionInfo('\(id)')))()
            """)
        await surveyEvaluate(host, "profile configuration", "(async () => JSON.stringify(await chrome.developerPrivate.getProfileConfiguration()))()")
        await surveyEvaluate(host, "management.getAll", """
            (async () => JSON.stringify((await chrome.management.getAll()).map(e => [e.id, e.name, e.installType, e.enabled, e.type])))()
            """)
        await surveyEvaluate(host, "extension-icon fetch", """
            (async () => { try { const r = await fetch('chrome://extension-icon/\(id)/128/0'); return r.status + ' ' + r.headers.get('content-type') + ' ' + (await r.arrayBuffer()).byteLength; } catch (e) { return 'fetch error ' + e; } })()
            """)
        await surveyEvaluate(host, "extension-icon img+canvas", """
            new Promise(resolve => { const i = new Image(); i.onload = () => { const c = document.createElement('canvas'); c.width = i.width; c.height = i.height; const g = c.getContext('2d'); g.drawImage(i, 0, 0); try { resolve('loaded ' + i.width + ' ' + c.toDataURL().length); } catch (e) { resolve('tainted ' + e); } }; i.onerror = () => resolve('img error'); i.src = 'chrome://extension-icon/\(id)/128/0'; document.body.appendChild(i); })
            """)
        await surveyEvaluate(host, "chrome.extensionActionPrivate / action",
            "[typeof chrome.action, typeof chrome.extensionActionPrivate, typeof chrome.webstorePrivate, typeof chrome.tabs, typeof chrome.windows].join(',')")

        // 2. Content scripts, by host kind.
        _ = await load(base.appendingPathComponent("page"), in: host)
        try? await Task.sleep(for: .milliseconds(500))
        await surveyEvaluate(host, "content script in CefWindow (.chrome toolbar)", "document.documentElement.dataset.cefswiftFixture ?? 'absent'")
        let plain = await surveyWindow(base.appendingPathComponent("page"), toolbar: .none)
        try? await Task.sleep(for: .milliseconds(500))
        await surveyEvaluate(plain.1, "content script in CefWindow (no toolbar)", "document.documentElement.dataset.cefswiftFixture ?? 'absent'")
        let alloy = CefBrowser(url: base.appendingPathComponent("page"))
        let alloyView = hostWindowed(alloy)
        _ = await loaded(alloy)
        try? await Task.sleep(for: .milliseconds(500))
        await surveyEvaluate(alloy, "content script in Alloy windowed", "document.documentElement.dataset.cefswiftFixture ?? 'absent'")
        await surveyEvaluate(alloy, "Alloy: chrome.runtime", "typeof chrome === 'object' ? Object.keys(chrome).join(',') : 'no chrome'")
        await closeHosted(alloy, alloyView)
        var offscreenConfiguration = CefBrowser.Configuration()
        offscreenConfiguration.rendering = .offscreen()
        let offscreen = CefBrowser(url: base.appendingPathComponent("page"), configuration: offscreenConfiguration)
        let offscreenView = hostOffscreen(offscreen)
        _ = await loaded(offscreen)
        try? await Task.sleep(for: .milliseconds(500))
        await surveyEvaluate(offscreen, "content script in Alloy offscreen", "document.documentElement.dataset.cefswiftFixture ?? 'absent'")
        await closeHosted(offscreen, offscreenView)
        await surveyEvaluate(plain.1, "DNR block", """
            (async () => { try { const r = await fetch('/dnr-blocked'); return 'fetched ' + r.status; } catch (e) { return 'blocked: ' + e; } })()
            """)

        // 3. The extension's own page and its view of tabs and windows.
        var tabRequests: [String] = []
        CefRuntime.shared.onChromeTab = { request in
            tabRequests.append("\(request.url) opener=\(request.opener?.identifier ?? -1) disposition=\(request.disposition)")
            return .close
        }
        let options = await surveyWindow(URL(string: "chrome-extension://\(id)/options.html")!, toolbar: .none)
        note("options page title", options.1.title)
        note("browser identifiers", "host=\(host.identifier) plain=\(plain.1.identifier) options=\(options.1.identifier)")
        await surveyEvaluate(options.1, "tabs.query", """
            (async () => JSON.stringify((await chrome.tabs.query({})).map(t => [t.id, t.windowId, t.url, t.active, t.index])))()
            """)
        await surveyEvaluate(options.1, "windows.getAll", """
            (async () => JSON.stringify((await chrome.windows.getAll({populate: true})).map(w => [w.id, w.type, w.focused, (w.tabs ?? []).length])))()
            """)
        await surveyEvaluate(options.1, "storage after content script", "(async () => JSON.stringify(await chrome.storage.local.get()))()")
        await surveyEvaluate(options.1, "API battery", Self.apiBattery(base: base, plainTabURL: base.appendingPathComponent("page")))
        // Tabs and groups across CefWindows.
        await surveyEvaluate(options.1, "tabs.group two CefWindow tabs", """
            (async () => { try { const tabs = (await chrome.tabs.query({url: 'http://127.0.0.1/*'})); const g = await chrome.tabs.group({tabIds: tabs.map(t => t.id)}); return 'group ' + g + ' ' + JSON.stringify((await chrome.tabs.query({})).map(t => [t.id, t.windowId, t.groupId, t.index])); } catch (e) { return 'error ' + e; } })()
            """)
        await surveyEvaluate(options.1, "tabs.group one tab", """
            (async () => { try { const [t] = await chrome.tabs.query({url: 'http://127.0.0.1/*'}); const g = await chrome.tabs.group({tabIds: [t.id]}); await chrome.tabGroups.update(g, {title: 'CefSwift', color: 'blue'}); return JSON.stringify([g, await chrome.tabGroups.query({}), (await chrome.tabs.get(t.id)).groupId]); } catch (e) { return 'error ' + e; } })()
            """)
        await surveyEvaluate(options.1, "tabs.move to another window", """
            (async () => { try { const tabs = await chrome.tabs.query({url: 'http://127.0.0.1/*'}); const r = await chrome.tabs.move(tabs[0].id, {windowId: tabs[1].windowId, index: -1}); return JSON.stringify(r); } catch (e) { return 'error ' + e; } })()
            """)
        await surveyEvaluate(options.1, "tabs.update url", """
            (async () => { try { const [t] = await chrome.tabs.query({url: 'http://127.0.0.1/*'}); const r = await chrome.tabs.update(t.id, {url: '\(base.appendingPathComponent("page").absoluteString)?updated'}); return JSON.stringify([r.id, r.pendingUrl ?? r.url]); } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(1))
        note("plain browser after tabs.update", plain.1.url?.absoluteString ?? "-")
        await surveyEvaluate(options.1, "action badge (own API)", """
            (async () => JSON.stringify([await chrome.action.getBadgeText({}), await chrome.action.getTitle({}), await chrome.action.getUserSettings()]))()
            """)
        let browsersBefore = CefRuntime.shared.browsers.count
        await surveyEvaluate(options.1, "tabs.create", """
            (async () => { try { const t = await chrome.tabs.create({url: '\(base.appendingPathComponent("page").absoluteString)'}); return JSON.stringify([t.id, t.windowId]); } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(2))
        note("after tabs.create", "browsers \(browsersBefore) -> \(CefRuntime.shared.browsers.count); chrome tabs: \(tabRequests)")
        await surveyEvaluate(options.1, "windows.create", """
            (async () => { try { const w = await chrome.windows.create({url: '\(base.appendingPathComponent("page").absoluteString)'}); return JSON.stringify([w.id, w.type]); } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(2))
        note("after windows.create", "browsers \(CefRuntime.shared.browsers.count); chrome tabs: \(tabRequests)")
        tabRequests = []
        await surveyEvaluate(host, "developerPrivate.showOptions", """
            (async () => { try { await chrome.developerPrivate.showOptions('\(id)'); return 'ok'; } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(2))
        note("after showOptions", "chrome tabs: \(tabRequests)")
        tabRequests = []
        await surveyEvaluate(options.1, "runtime.openOptionsPage", """
            (async () => { try { await chrome.runtime.openOptionsPage(); return 'ok'; } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(2))
        note("after openOptionsPage", "chrome tabs: \(tabRequests)")

        // 4. Chrome's toolbar: the extensions container through accessibility.
        if let nsWindow = hostWindow.window {
            nsWindow.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
            note("toolbar AX", axSummary(nsWindow.contentView, filter: { classes, text in
                !text.isEmpty || !classes.isEmpty
            }))
            await surveyEvaluate(options.1, "action.openPopup per window", """
                (async () => { const out = []; for (const w of await chrome.windows.getAll({populate: true})) { try { await chrome.action.openPopup({windowId: w.id}); out.push(w.id + ' ' + w.tabs[0].url + ' opened'); } catch (e) { out.push(w.id + ' ' + w.tabs[0].url + ' ' + e.message); } } return out.join(' | '); })()
                """)
            try? await Task.sleep(for: .seconds(2))
            for child in nsWindow.childWindows ?? [] {
                note("child after openPopup", "\(NSStringFromClass(type(of: child))) \(child.frame.size) visible=\(child.isVisible) \(CefChromiumTesting.describe(child))")
            }
            note("surfaces after openPopup", hostWindow.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
            await surveyEvaluate(options.1, "storage after openPopup", "(async () => JSON.stringify(await chrome.storage.local.get('popupOpened')))()")
            for surface in hostWindow.chromiumSurfaces { surface.dismiss() }
            try? await Task.sleep(for: .seconds(1))
            let childrenBefore = Set((nsWindow.childWindows ?? []).map(ObjectIdentifier.init))
            SurfaceInventory.press(in: nsWindow) { element in
                let text = [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityHelp()]
                    .compactMap { $0 }.joined(separator: " ")
                return element.accessibilityRole() == .button && text.contains("CefSwift Test")
            }
            try? await Task.sleep(for: .seconds(2))
            for child in nsWindow.childWindows ?? [] where !childrenBefore.contains(ObjectIdentifier(child)) {
                let described = CefChromiumTesting.describe(child)
                note("after pressing action (pinned?)", "\(NSStringFromClass(type(of: child))) \(child.frame.size) \(described)")
            }
            note("surfaces after press", hostWindow.chromiumSurfaces.map { "\($0.kind) \($0.title)" })
            SurfaceInventory.press(in: nsWindow) { element in
                let text = [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityHelp()]
                    .compactMap { $0 }.joined(separator: " ")
                return element.accessibilityRole() == .button && text == "Extensions"
            }
            try? await Task.sleep(for: .seconds(2))
            for child in nsWindow.childWindows ?? [] where !childrenBefore.contains(ObjectIdentifier(child)) {
                note("after pressing Extensions", "\(NSStringFromClass(type(of: child))) \(child.frame.size) \(CefChromiumTesting.describe(child))")
                note("extensions menu AX", axSummary(child.contentView, filter: { _, text in !text.isEmpty }))
            }
            await surveyEvaluate(options.1, "storage after press", "(async () => JSON.stringify(await chrome.storage.local.get()))()")
            for surface in hostWindow.chromiumSurfaces { surface.dismiss() }
        }

        // 5. DevTools: targets and the Extensions domain.
        do {
            let targets = try await host.devTools.send("Target.getTargets")
            note("Target.getTargets", targets["targetInfos"].arrayValue?.map { "\($0["type"].stringValue ?? "") \($0["url"].stringValue ?? "")" } ?? [])
        } catch { note("Target.getTargets", "error \(error)") }
        do {
            let result = try await host.devTools.send("Extensions.triggerAction", ["id": .string(id), "targetId": "x"])
            note("Extensions.triggerAction", result.text)
        } catch { note("Extensions.triggerAction", "error \(error)") }

        // 6. chrome://extensions itself, and extensions in other profiles.
        _ = await load(URL(string: "chrome://extensions")!, in: host)
        note("chrome://extensions title", host.title)
        _ = await load(URL(string: "chrome://extensions-internals")!, in: host)
        await surveyEvaluate(host, "extensions-internals", "document.body.innerText.length + ' chars; fixture: ' + document.body.innerText.includes('\(id)')")
        let persistent = CefProfile.persistent(id: "survey-\(UUID().uuidString.prefix(6))")
        let incognito = CefProfile.incognito()
        for (label, profile) in [("persistent", persistent), ("incognito", incognito)] {
            var configuration = CefBrowser.Configuration()
            configuration.profile = profile
            let browser = CefBrowser(url: label == "incognito" ? base.appendingPathComponent("page") : URL(string: "chrome://extensions/strings.m.js")!, configuration: configuration)
            var windowConfiguration = CefWindow.Configuration()
            windowConfiguration.frame = CGRect(x: 100, y: 100, width: 600, height: 400)
            let window = CefWindow(browser: browser, configuration: windowConfiguration)
            window.show()
            _ = await loaded(browser)
            if label != "incognito" { await surveyEvaluate(browser, "\(label) profile extensions", """
                (async () => { try { return JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true})).map(e => [e.id, e.name, e.incognitoAccess])); } catch (e) { return 'error ' + e; } })()
                """) }
            _ = await load(base.appendingPathComponent("page"), in: browser)
            try? await Task.sleep(for: .milliseconds(500))
            await surveyEvaluate(browser, "\(label) content script", "document.documentElement.dataset.cefswiftFixture ?? 'absent'")
            window.close()
            _ = await waitUntil { window.isClosed }
        }

        // 7. Chrome Web Store, external extensions and policy installs.
        if let storeID = ProcessInfo.processInfo.environment[extensionStoreEnvironmentKey] {
            await surveyWebStore(storeID, in: hostWindow, host)
            _ = await load(URL(string: "chrome://extensions/strings.m.js")!, in: host)
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(5))
                let found = try? await host.evaluateJavaScript("""
                    (async () => (await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true})).length)()
                    """)
                if (found?.doubleValue ?? 0) >= 5 { break }
            }
            await surveyEvaluate(host, "extensions after external/policy", """
                (async () => JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true, includeTerminated: true})).map(e => [e.id, e.name, e.location, e.state, e.mustRemainInstalled, e.userMayModify, e.controlledInfo, JSON.stringify(e.disableReasons).match(/[a-zA-Z]+\\":true/g)])))()
                """)
            await surveyEvaluate(host, "management.setEnabled external", """
                (async () => { try { await chrome.management.setEnabled('\(surveyExternalID)', true); const e = await chrome.developerPrivate.getExtensionInfo('\(surveyExternalID)'); return e.state + ' ' + JSON.stringify(e.disableReasons); } catch (e) { return 'error ' + e; } })()
                """)
        }
        // Developer mode: pack and load unpacked, answering the file dialog.
        if let root = CefRuntime.shared.configuration?.resolvedRootCacheDirectory, let fixture = ExtensionFixture.directory {
            _ = await load(URL(string: "chrome://extensions/strings.m.js")!, in: host)
            let copy = root.appendingPathComponent("unpacked-copy")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: fixture, to: copy)
            if var manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: copy.appendingPathComponent("manifest.json")))) as? [String: Any] {
                manifest["key"] = nil
                manifest["name"] = "CefSwift Test Copy"
                manifest["chrome_url_overrides"] = nil
                try? JSONSerialization.data(withJSONObject: manifest).write(to: copy.appendingPathComponent("manifest.json"))
            }
            await surveyEvaluate(host, "packDirectory", """
                (async () => { try { return JSON.stringify(await chrome.developerPrivate.packDirectory('\(copy.path)', '', 0)); } catch (e) { return 'error ' + e; } })()
                """)
            note("pack output", (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { $0.hasPrefix("unpacked-copy") } ?? [])
            let answering = SurveyFileDialogDelegate(answer: copy)
            host.delegate = answering
            await surveyEvaluate(host, "loadUnpacked without developer mode", """
                (async () => { try { return JSON.stringify(await chrome.developerPrivate.loadUnpacked({failQuietly: false, populateError: true})); } catch (e) { return 'error ' + e; } })()
                """)
            await surveyEvaluate(host, "enable developer mode", """
                (async () => { await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode: true}); return JSON.stringify(await chrome.developerPrivate.getProfileConfiguration()); })()
                """)
            await surveyEvaluate(host, "loadUnpacked", """
                (async () => { try { return JSON.stringify(await chrome.developerPrivate.loadUnpacked({failQuietly: false, populateError: true})); } catch (e) { return 'error ' + e; } })()
                """)
            note("file dialogs asked", answering.asked)
            await surveyEvaluate(host, "extensions after loadUnpacked", """
                (async () => JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true})).map(e => [e.id, e.name, e.location, e.state])))()
                """)
            if let crx = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.first(where: { $0.hasSuffix(".crx") }) {
                await surveyEvaluate(host, "installDroppedFile without drag", """
                    (async () => { try { await chrome.developerPrivate.installDroppedFile(); return 'ok'; } catch (e) { return 'error ' + e; } })()
                    """)
                note("crx", crx)
            }
            host.delegate = nil
            await surveyEvaluate(host, "updateExtensionConfiguration pin + incognito", """
                (async () => { try { await chrome.developerPrivate.updateExtensionConfiguration({extensionId: '\(id)', pinnedToToolbar: true, incognitoAccess: true}); const e = await chrome.developerPrivate.getExtensionInfo('\(id)'); return JSON.stringify([e.pinnedToToolbar, e.incognitoAccess]); } catch (e) { return 'error ' + e; } })()
                """)
            await surveyEvaluate(host, "autoUpdate", "(async () => { try { await chrome.developerPrivate.autoUpdate(); return 'ok'; } catch (e) { return 'error ' + e; } })()")
        }
        if ProcessInfo.processInfo.environment[extensionStoreEnvironmentKey] != nil {
            _ = await load(URL(string: "chrome://policy")!, in: host)
            try? await Task.sleep(for: .seconds(2))
            await surveyEvaluate(host, "chrome://policy", """
                (() => { const t = []; const walk = n => { if (n.shadowRoot) walk(n.shadowRoot); for (const c of n.children ?? []) walk(c); if (n.nodeType === 1 && !n.children.length && n.textContent.trim()) t.push(n.textContent.trim()); }; walk(document.body); return t.filter(x => /Extension|Error|Ignored|platform|cloud|machine|Recommended|Mandatory|sensitive|managed/i.test(x)).slice(0, 40).join(' | '); })()
                """)
        }

        for window in [hostWindow, plain.0, options.0] {
            window.close()
            _ = await waitUntil { window.isClosed }
        }
        CefRuntime.shared.onChromeTab = nil
        check("extension survey: finished", true)
    }

    /// Chrome's own windows (`openChromeWindow`): tabs, groups, the
    /// extensions toolbar and action popups; then the Web Store's button.
    static func surveyChromeWindows(base: URL) async {
        let id = ExtensionFixture.id
        NSApp.activate()
        let first = CefRuntime.shared.openChromeWindow(url: base.appendingPathComponent("page"))
        _ = await loaded(first)
        try? await Task.sleep(for: .seconds(1))
        note("chrome window", NSApp.windows.filter(\.isVisible).map { "\(NSStringFromClass(type(of: $0))) '\($0.title)' key=\($0.isKeyWindow)" })
        // The extension's page in a second tab of that window.
        first.execute(CefChromeCommand(rawValue: Int(IDC_NEW_TAB)))
        try? await Task.sleep(for: .seconds(1))
        _ = try? await first.evaluateJavaScript("1")
        let options = CefRuntime.shared.browsers.last { $0 !== first } ?? first
        _ = options.load(URL(string: "chrome-extension://\(id)/options.html")!)
        _ = await loaded(options)
        note("new tab browser", "\(options.url?.absoluteString ?? "-") same=\(options === first)")
        await surveyEvaluate(options, "chrome window tabs.query", """
            (async () => JSON.stringify((await chrome.tabs.query({})).map(t => [t.id, t.windowId, t.index, t.active, t.groupId, t.url])))()
            """)
        await surveyEvaluate(options, "chrome window windows.getAll", """
            (async () => JSON.stringify((await chrome.windows.getAll({populate: true})).map(w => [w.id, w.type, w.focused, (w.tabs ?? []).length])))()
            """)
        await surveyEvaluate(options, "chrome window tabs.group + tabGroups", """
            (async () => { try { const tabs = await chrome.tabs.query({currentWindow: true}); const g = await chrome.tabs.group({tabIds: [tabs[0].id]}); await chrome.tabGroups.update(g, {title: 'CefSwift', color: 'blue'}); return JSON.stringify([g, await chrome.tabGroups.query({}), (await chrome.tabs.query({})).map(t => [t.id, t.groupId])]); } catch (e) { return 'error ' + e; } })()
            """)
        await surveyEvaluate(options, "chrome window tabs.create", """
            (async () => { try { const t = await chrome.tabs.create({url: '\(base.appendingPathComponent("page").absoluteString)?created', active: false}); return JSON.stringify([t.id, t.windowId, t.index]); } catch (e) { return 'error ' + e; } })()
            """)
        try? await Task.sleep(for: .seconds(1))
        await surveyEvaluate(options, "chrome window action.getUserSettings", "(async () => JSON.stringify(await chrome.action.getUserSettings()))()")
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title.contains("CefSwift") || $0.title.contains("page") }) {
            note("toolbar AX in Chrome window", axSummary(window.contentView, filter: { classes, text in
                classes.contains { $0.contains("Extension") || $0.contains("ToolbarAction") || $0.contains("Toolbar") } || text.contains("CefSwift") || text.contains("Extensions")
            }))
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            await surveyEvaluate(options, "chrome window action.openPopup", """
                (async () => { try { const w = await chrome.windows.getCurrent(); await chrome.windows.update(w.id, {focused: true}); await chrome.action.openPopup({windowId: w.id}); return 'opened'; } catch (e) { return 'error ' + e.message; } })()
                """)
            try? await Task.sleep(for: .seconds(2))
            for new in NSApp.windows where !before.contains(ObjectIdentifier(new)) && new.isVisible {
                note("window after openPopup", "\(NSStringFromClass(type(of: new))) \(new.frame) parent=\(new.parent.map { NSStringFromClass(type(of: $0)) } ?? "-") \(CefChromiumTesting.describe(new))")
            }
            note("browsers after openPopup", CefRuntime.shared.browsers.map { $0.url?.absoluteString ?? "-" })
            for child in window.childWindows ?? [] where child.isVisible { SurfaceInventory.sendEscape(to: child) }
            // The toolbar's action button.
            let before2 = Set(NSApp.windows.map(ObjectIdentifier.init))
            SurfaceInventory.press(in: window) { element in
                let text = [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityHelp()]
                    .compactMap { $0 }.joined(separator: " ")
                return element.accessibilityRole() == .button && text.contains("CefSwift Test")
            }
            try? await Task.sleep(for: .seconds(2))
            for new in NSApp.windows where !before2.contains(ObjectIdentifier(new)) && new.isVisible {
                note("window after pressing action", "\(NSStringFromClass(type(of: new))) \(new.frame) \(CefChromiumTesting.describe(new))")
            }
        }
        await surveyEvaluate(options, "popupOpened", "(async () => JSON.stringify(await chrome.storage.local.get('popupOpened')))()")
        // The Web Store, in a Chrome window, with a gesture.
        if let storeID = ProcessInfo.processInfo.environment[extensionStoreEnvironmentKey] {
            _ = await load(URL(string: "https://chromewebstore.google.com/detail/\(storeID)")!, in: first, timeout: .seconds(30))
            try? await Task.sleep(for: .seconds(3))
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            let clicked = try? await first.evaluateJavaScript("""
                (() => { const b = [...document.querySelectorAll('button')].find(b => /Add to/i.test(b.innerText)); if (!b) return 'none'; b.click(); return 'clicked ' + b.outerHTML.slice(0, 300); })()
                """, userGesture: true)
            note("store click with gesture", clicked?.text ?? "-")
            try? await Task.sleep(for: .seconds(5))
            for new in NSApp.windows where !before.contains(ObjectIdentifier(new)) && new.isVisible {
                note("window after store click", "\(NSStringFromClass(type(of: new))) \(new.frame) \(CefChromiumTesting.describe(new))")
                note("its AX", axSummary(new.contentView, filter: { _, text in !text.isEmpty }))
            }
            if let shot = try? await first.devTools.send("Page.captureScreenshot", ["format": "png"]),
               let data = shot["data"].stringValue.flatMap({ Data(base64Encoded: $0) }) {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-store.png")
                try? data.write(to: path)
                note("store screenshot", path.path)
            }
            await surveyEvaluate(first, "store dialog in page", """
                [...document.querySelectorAll('[role=dialog], [role=alertdialog]')].map(d => d.innerText.slice(0, 300)).join(' || ')
                """)
        }
        for browser in CefRuntime.shared.browsers { browser.close(force: true) }
        try? await Task.sleep(for: .seconds(2))
    }

    /// A `CefWindow` with Chrome's toolbar: what of the toolbar exists, the
    /// action popup, and the Web Store's install dialog.
    static func surveyToolbarWindow(base: URL) async {
        NSApp.activate()
        let (window, browser) = await surveyWindow(base.appendingPathComponent("page"), toolbar: .chrome)
        try? await Task.sleep(for: .seconds(1))
        guard let nsWindow = window.window else { return }
        nsWindow.makeKeyAndOrderFront(nil)
        note("CefWindow key", "\(nsWindow.isKeyWindow) app active \(NSApp.isActive) toolbar \(window.hasChromeToolbar) \(window.chromeToolbarDescription)")
        func pageView(_ view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "RenderWidgetHostViewCocoa" { return view }
            return view.subviews.lazy.compactMap(pageView).first
        }
        if let content = nsWindow.contentView, let page = pageView(content) {
            note("page frame vs content", "\(page.convert(page.bounds, to: nil)) in \(content.bounds)")
        }
        note("CefWindow AX (all)", axSummary(nsWindow.contentView, filter: { classes, text in
            !classes.isEmpty || !text.isEmpty
        }))
        let options = await surveyWindow(URL(string: "chrome-extension://\(ExtensionFixture.id)/options.html")!, toolbar: .none)
        await surveyEvaluate(options.1, "openPopup into the toolbar CefWindow", """
            (async () => { try { const [t] = await chrome.tabs.query({url: 'http://127.0.0.1/*'}); await chrome.windows.update(t.windowId, {focused: true}); await chrome.action.openPopup({windowId: t.windowId}); return 'opened'; } catch (e) { return 'error ' + e.message; } })()
            """)
        try? await Task.sleep(for: .seconds(2))
        for child in nsWindow.childWindows ?? [] where child.isVisible {
            note("child after openPopup", "\(child.frame) \(CefChromiumTesting.describe(child))")
        }
        note("surfaces", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
        for surface in window.chromiumSurfaces { surface.dismiss() }
        // Chrome's extensions menu (the puzzle piece), then the action in it.
        let menuBefore = Set((nsWindow.childWindows ?? []).map(ObjectIdentifier.init))
        SurfaceInventory.press(in: nsWindow) { $0.accessibilityRole() == .popUpButton && ($0.accessibilityTitle() ?? $0.accessibilityLabel() ?? "") == "Extensions" }
        try? await Task.sleep(for: .seconds(2))
        for child in nsWindow.childWindows ?? [] where child.isVisible && !menuBefore.contains(ObjectIdentifier(child)) {
            note("extensions menu", "\(child.frame) \(CefChromiumTesting.describe(child))")
            note("extensions menu AX", axSummary(child.contentView, filter: { _, text in !text.isEmpty }))
            SurfaceInventory.press(in: child) { element in
                element.accessibilityRole() == .button
                    && (element.accessibilityTitle() ?? element.accessibilityLabel() ?? "").hasPrefix("CefSwift Test Extension")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        for child in nsWindow.childWindows ?? [] where child.isVisible {
            note("child after menu item", "\(child.frame) \(CefChromiumTesting.describe(child))")
        }
        note("surfaces after menu item", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)' \($0.presentation)" })
        await surveyEvaluate(options.1, "popupOpened after menu item", "(async () => JSON.stringify(await chrome.storage.local.get('popupOpened')))()")
        for surface in window.chromiumSurfaces { surface.dismiss() }
        for child in nsWindow.childWindows ?? [] where child.isVisible { SurfaceInventory.sendEscape(to: child) }
        options.0.close()
        if let storeID = ProcessInfo.processInfo.environment[extensionStoreEnvironmentKey] {
            _ = await load(URL(string: "https://chromewebstore.google.com/detail/\(storeID)")!, in: browser, timeout: .seconds(30))
            try? await Task.sleep(for: .seconds(3))
            let clicked = try? await browser.evaluateJavaScript("""
                (() => { const b = [...document.querySelectorAll('button')].find(b => /Add to/i.test(b.innerText)); if (!b) return 'none'; b.click(); return 'clicked'; })()
                """, userGesture: true)
            note("store click with gesture in CefWindow", clicked?.text ?? "-")
            try? await Task.sleep(for: .seconds(5))
            note("all windows after store click", NSApp.windows.filter(\.isVisible).map { "\(NSStringFromClass(type(of: $0))) '\($0.title)' parent=\($0.parent.map { NSStringFromClass(type(of: $0)) } ?? "-")" })
            note("browsers after store click", CefRuntime.shared.browsers.map { $0.url?.absoluteString ?? "-" })
            for top in NSApp.windows where top.isVisible && top.parent == nil && NSStringFromClass(type(of: top)) == "NativeWidgetMacNSWindow" {
                note("top-level widget", "\(top.frame) level \(top.level.rawValue) \(CefChromiumTesting.describe(top))")
                note("top-level widget AX", axSummary(top.contentView, filter: { _, text in !text.isEmpty }))
                if CefChromiumTesting.describe(top).classes.contains("ExtensionInstallDialogView") {
                    SurfaceInventory.press(in: top) { $0.accessibilityRole() == .button && ($0.accessibilityTitle() ?? "") == "Add extension" }
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(500))
                        let removable = try? await browser.evaluateJavaScript("[...document.querySelectorAll('button')].some(b => /Remove from/i.test(b.innerText))")
                        if removable?.boolValue == true { break }
                    }
                    try? await Task.sleep(for: .seconds(2))
                    note("windows after install", NSApp.windows.filter(\.isVisible).map { "\(NSStringFromClass(type(of: $0))) \(CefChromiumTesting.describe($0).classes.filter { $0.contains("Extension") || $0.contains("Bubble") })" })
                    await surveyEvaluate(browser, "store buttons after install", """
                        JSON.stringify([...document.querySelectorAll('button')].map(b => b.innerText.trim()).filter(Boolean).slice(0, 8))
                        """)
                }
            }
            for child in nsWindow.childWindows ?? [] where child.isVisible {
                note("child after store click", "\(child.frame) \(CefChromiumTesting.describe(child))")
            }
            note("surfaces after store click", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
            if let dialog = (nsWindow.childWindows ?? []).first(where: { CefChromiumTesting.describe($0).classes.contains("ExtensionInstallDialogView") }) {
                SurfaceInventory.press(in: dialog) { $0.accessibilityRole() == .button && ($0.accessibilityTitle() ?? "") == "Add extension" }
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let removable = try? await browser.evaluateJavaScript("[...document.querySelectorAll('button')].some(b => /Remove from/i.test(b.innerText))")
                    if removable?.boolValue == true { break }
                }
                try? await Task.sleep(for: .seconds(1))
                for child in nsWindow.childWindows ?? [] where child.isVisible {
                    note("child after install", "\(child.frame) \(CefChromiumTesting.describe(child))")
                    note("its AX", axSummary(child.contentView, filter: { _, text in !text.isEmpty }))
                }
                note("surfaces after install", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
                await surveyEvaluate(browser, "store buttons after install", """
                    JSON.stringify([...document.querySelectorAll('button')].map(b => b.innerText.trim()).filter(Boolean).slice(0, 8))
                    """)
            }
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    static func surveyWebStore(_ storeID: String, in window: CefWindow, _ browser: CefBrowser) async {
        let url = URL(string: "https://chromewebstore.google.com/detail/\(storeID)")!
        let loadedStore = await load(url, in: browser, timeout: .seconds(30))
        note("store loaded", "\(loadedStore) \(browser.title)")
        try? await Task.sleep(for: .seconds(3))
        await surveyEvaluate(browser, "store page APIs", """
            JSON.stringify({ua: navigator.userAgent, brands: navigator.userAgentData?.brands, webstorePrivate: typeof chrome?.webstorePrivate,
              wsp: chrome?.webstorePrivate ? Object.keys(chrome.webstorePrivate).sort() : null, management: typeof chrome?.management,
              chromeKeys: typeof chrome === 'object' ? Object.keys(chrome).sort() : null})
            """)
        await surveyEvaluate(browser, "store buttons", """
            JSON.stringify([...document.querySelectorAll('button')].map(b => [b.innerText.trim(), b.disabled]).filter(b => b[0]).slice(0, 20))
            """)
        await surveyEvaluate(browser, "store banners", """
            document.body.innerText.split('\\n').filter(l => /chrome|switch|unsupported|available/i.test(l)).slice(0, 12).join(' | ')
            """)
        let point = try? await browser.evaluateJavaScript("""
            (() => { const b = [...document.querySelectorAll('button')].find(b => /Add to/i.test(b.innerText)); if (!b) return null; b.scrollIntoView(); const r = b.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()
            """)
        guard let x = point?[0].doubleValue, let y = point?[1].doubleValue else { return note("store add button", "none") }
        guard let nsWindow = window.window else { return }
        _ = try? await browser.evaluateJavaScript("""
            (() => { window.__wsLog = []; const w = chrome.webstorePrivate; for (const name of ['beginInstallWithManifest3', 'completeInstall', 'getExtensionStatus', 'install', 'getBrowserLogin', 'getMV2DeprecationStatus']) { const f = w[name]; if (typeof f !== 'function') continue; w[name] = function (...args) { window.__wsLog.push(name + ' ' + JSON.stringify(args).slice(0, 200)); const r = f.apply(this, args); if (r && r.then) r.then(v => window.__wsLog.push(name + ' -> ' + JSON.stringify(v)), e => window.__wsLog.push(name + ' !! ' + e)); return r; }; } return true; })()
            """)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send(
                "Input.dispatchMouseEvent", ["type": .string(type), "x": .number(x), "y": .number(y), "button": "left", "clickCount": 1])
        }
        var dialog: NSWindow?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            dialog = (SurfaceInventory.windows(of: nsWindow).map(\.0) + NSApp.windows)
                .first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 !== nsWindow }
            if dialog != nil { break }
        }
        await surveyEvaluate(browser, "webstorePrivate calls", "JSON.stringify(window.__wsLog)")
        guard let dialog else { return note("store install prompt", "no window appeared") }
        try? await Task.sleep(for: .seconds(1))
        note("store install prompt", "\(NSStringFromClass(type(of: dialog))) parent=\(dialog.parent.map { NSStringFromClass(type(of: $0)) } ?? "none") \(CefChromiumTesting.describe(dialog))")
        note("store install prompt AX", axSummary(dialog.contentView, filter: { _, text in !text.isEmpty }))
        note("surfaces", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
        SurfaceInventory.press(in: dialog) { element in
            element.accessibilityRole() == .button && (element.accessibilityTitle() ?? element.accessibilityLabel() ?? "").hasPrefix("Add ")
        }
        let installedBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            let installed = try? await browser.evaluateJavaScript("""
                [...document.querySelectorAll('button')].some(b => /Remove from/i.test(b.innerText))
                """)
            if installed?.boolValue == true { break }
        }
        await surveyEvaluate(browser, "store buttons after", """
            JSON.stringify([...document.querySelectorAll('button')].map(b => [b.innerText.trim(), b.disabled]).filter(b => b[0]).slice(0, 12))
            """)
        for child in SurfaceInventory.windows(of: nsWindow).map(\.0) where !installedBefore.contains(ObjectIdentifier(child)) && child.isVisible {
            note("after install window", "\(CefChromiumTesting.describe(child))")
        }
        note("surfaces after install", window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })
    }

    /// Calls each extension API once from the extension's own page and
    /// reports what each did.
    static func apiBattery(base: URL, plainTabURL: URL) -> String {
        """
        (async () => {
          const out = {};
          const run = async (name, f) => { try { const v = await f(); out[name] = 'ok ' + JSON.stringify(v)?.slice(0, 120); } catch (e) { out[name] = 'error ' + (e?.message ?? e); } };
          const [tab] = await chrome.tabs.query({url: 'http://127.0.0.1/*'});
          await run('storage', async () => { await chrome.storage.local.set({battery: 1}); return (await chrome.storage.local.get('battery')).battery; });
          await run('storage.sync', async () => { await chrome.storage.sync.set({battery: 1}); return (await chrome.storage.sync.get('battery')).battery; });
          await run('storage.session', async () => { await chrome.storage.session.set({battery: 1}); return 1; });
          await run('cookies', async () => (await chrome.cookies.getAll({})).length);
          await run('cookies.getAllCookieStores', async () => (await chrome.cookies.getAllCookieStores()).map(s => [s.id, s.tabIds.length]));
          await run('downloads.search', async () => (await chrome.downloads.search({})).length);
          await run('bookmarks.getTree', async () => (await chrome.bookmarks.getTree())[0].children.map(c => c.title));
          await run('history.search', async () => (await chrome.history.search({text: ''})).length);
          await run('topSites', async () => (await chrome.topSites.get()).length);
          await run('sessions.getRecentlyClosed', async () => (await chrome.sessions.getRecentlyClosed()).length);
          await run('tabGroups.query', async () => (await chrome.tabGroups.query({})).length);
          await run('scripting.executeScript', async () => (await chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => document.title}))[0].result);
          await run('tabs.sendMessage', async () => chrome.tabs.sendMessage(tab.id, 'hello').catch(e => 'rejected ' + e.message));
          await run('tabs.captureVisibleTab', async () => (await chrome.tabs.captureVisibleTab(tab.windowId)).length);
          await run('tabs.reload', async () => chrome.tabs.reload(tab.id));
          await run('tabs.getZoom', async () => chrome.tabs.getZoom(tab.id));
          await run('tabs.discard', async () => 'skipped');
          await run('windows.getCurrent', async () => { const w = await chrome.windows.getCurrent(); return [w.id, w.type]; });
          await run('windows.update focused', async () => { const w = await chrome.windows.update(tab.windowId, {focused: true}); return [w.id, w.focused]; });
          await run('management.getAll', async () => (await chrome.management.getAll()).length);
          await run('management.getSelf', async () => (await chrome.management.getSelf()).installType);
          await run('alarms', async () => { await chrome.alarms.create('a', {delayInMinutes: 1}); return (await chrome.alarms.getAll()).length; });
          await run('identity.getRedirectURL', async () => chrome.identity.getRedirectURL());
          await run('identity.getProfileUserInfo', async () => chrome.identity.getProfileUserInfo());
          await run('identity.getAuthToken', async () => chrome.identity.getAuthToken({interactive: false}));
          await run('runtime.connectNative', () => new Promise(resolve => { const p = chrome.runtime.connectNative('dev.cefswift.selftest'); p.onMessage.addListener(m => resolve('message ' + JSON.stringify(m))); p.onDisconnect.addListener(() => resolve('disconnected ' + chrome.runtime.lastError?.message)); p.postMessage({echo: 'hi'}); setTimeout(() => resolve('no reply'), 3000); }));
          await run('declarativeNetRequest.getEnabledRulesets', async () => chrome.declarativeNetRequest.getEnabledRulesets());
          await run('declarativeNetRequest.updateDynamicRules', async () => { await chrome.declarativeNetRequest.updateDynamicRules({addRules: [{id: 2, action: {type: 'block'}, condition: {urlFilter: '/dnr-dynamic', resourceTypes: ['xmlhttprequest']}}], removeRuleIds: [2]}); return (await chrome.declarativeNetRequest.getDynamicRules()).length; });
          await run('webRequest.onBeforeRequest', async () => { let seen = 0; const l = () => { seen++; }; chrome.webRequest.onBeforeRequest.addListener(l, {urls: ['http://127.0.0.1/*']}); await chrome.tabs.reload(tab.id); await new Promise(r => setTimeout(r, 800)); chrome.webRequest.onBeforeRequest.removeListener(l); return seen; });
          await run('sidePanel.getOptions', async () => chrome.sidePanel.getOptions({}));
          await run('sidePanel.open', async () => { await chrome.sidePanel.open({tabId: tab.id}); return 'opened'; });
          await run('action.openPopup', async () => { await chrome.action.openPopup(); return 'opened'; });
          await run('offscreen.createDocument', async () => { await chrome.offscreen.createDocument({url: 'panel.html', reasons: ['DOM_PARSER'], justification: 'test'}); return await chrome.offscreen.hasDocument?.(); });
          await run('contextMenus.create', async () => new Promise(r => chrome.contextMenus.create({id: 'battery-' + Date.now(), title: 'x'}, () => r(chrome.runtime.lastError?.message ?? 'created'))));
          await run('commands.getAll', async () => (await chrome.commands.getAll()).map(c => [c.name, c.shortcut]));
          await run('permissions.getAll', async () => (await chrome.permissions.getAll()).origins);
          await run('notifications.getPermissionLevel', async () => new Promise(r => chrome.notifications.getPermissionLevel(r)));
          await run('fontSettings/i18n', async () => chrome.i18n.getUILanguage());
          await run('extension.isAllowedIncognitoAccess', async () => chrome.extension.isAllowedIncognitoAccess());
          return JSON.stringify(out);
        })()
        """
    }

    static func surveyWindow(_ url: URL, toolbar: CefWindow.Toolbar) async -> (CefWindow, CefBrowser) {
        let browser = CefBrowser(url: url)
        var configuration = CefWindow.Configuration()
        configuration.toolbar = toolbar
        configuration.frame = CGRect(x: 120, y: 100, width: 1100, height: 760)
        let window = CefWindow(browser: browser, configuration: configuration)
        window.chromiumSurfacePolicy = CefChromiumSurface.Policy()
        window.show()
        _ = await loaded(browser)
        return (window, browser)
    }

    /// The accessibility elements under `view` that `filter` keeps: their
    /// role, title, label and view classes.
    static func axSummary(_ view: NSView?, filter: ([String], String) -> Bool) -> String {
        var lines: [String] = []
        func visit(_ element: NSObject, depth: Int) {
            guard depth < 24, lines.count < 80, let accessible = element as? NSAccessibilityProtocol else { return }
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            let classes = element.responds(to: selector)
                ? (element.perform(selector, with: "AXDOMClassList")?.takeUnretainedValue() as? [String]) ?? [] : []
            let text = [accessible.accessibilityTitle(), accessible.accessibilityLabel(), accessible.accessibilityHelp(),
                        accessible.accessibilityValue() as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
            if filter(classes, text) {
                lines.append("[\(accessible.accessibilityRole()?.rawValue ?? "-") \(classes.joined(separator: ",")) '\(text)']")
            }
            for child in accessible.accessibilityChildren() ?? [] {
                if let child = child as? NSObject { visit(child, depth: depth + 1) }
            }
        }
        if let view { visit(view, depth: 0) }
        return lines.joined(separator: " ")
    }
}

extension SelfTest {
    static let surveyExternalID = "ddkjiahejlhfcafbddmgiahcphecmpfh"   // uBlock Origin Lite
    static let surveyPolicyID = "eimadpbcbfnmbkopoojfekhnkhdbieeh"     // Dark Reader
    static let surveyForcedID = "fmkadmapgofadopljbjfkapdkoienihi"     // React Developer Tools
    static let surveyPolicyDomain = "dev.rajaniraiyn.cefswift.selftest.extensions"

    static func runExtensionSurvey() async {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-survey-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let external = root.appendingPathComponent("External Extensions")
            try? FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let update = "https://clients2.google.com/service/update2/crx"
            try? Data("{\"external_update_url\": \"\(update)\", \"was_installed_by_default\": true}".utf8)
                .write(to: external.appendingPathComponent("\(surveyExternalID).json"))
            let defaults = UserDefaults(suiteName: surveyPolicyDomain)
            defaults?.set([surveyPolicyID: ["installation_mode": "normal_installed", "update_url": update]], forKey: "ExtensionSettings")
            defaults?.set(["\(surveyForcedID);\(update)"], forKey: "ExtensionInstallForcelist")
            defer {
                UserDefaults.standard.removePersistentDomain(forName: surveyPolicyDomain)
                CFPreferencesAppSynchronize(surveyPolicyDomain as CFString)
                try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(surveyPolicyDomain).plist"))
            }
            await runProbe("extensionSurvey", label: "extension survey", root: root, timeout: .seconds(400))
        }
    }
}

/// Answers file dialogs with one folder, and records them.
@MainActor
final class SurveyFileDialogDelegate: CefBrowserDelegate {
    let answer: URL
    var asked: [String] = []
    init(answer: URL) { self.answer = answer }

    func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]? {
        asked.append("\(dialog.mode)")
        return [answer]
    }
}

/// The unpacked test extension in SelfTest's resources.
enum ExtensionFixture {
    /// Its identifier, fixed by the manifest's `key`.
    static let id = "hijdjdmlodkldbmopflekahgjddfeagl"
    static let name = "CefSwift Test Extension"

    static var directory: URL? { Bundle.module.url(forResource: "TestExtension", withExtension: nil) }
}
