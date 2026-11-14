import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit

/// Exploratory probe (`CEFSWIFT_SELFTEST_PROBE=tabResearch`,
/// `CEFSWIFT_RESEARCH=<experiment>`): what CEF, AppKit and DevTools report
/// about Chromium's tabs without a WebUI host, which `chrome.tabs` listener
/// takes Chromium down, and what Chromium restores at startup.
extension SelfTest {
    static func tabResearchProbe() async {
        let experiment = ProcessInfo.processInfo.environment["CEFSWIFT_RESEARCH"] ?? "ids"
        func note(_ text: String) { print("NOTE \(text)"); fflush(stdout) }
        func bookmarksHost() async -> (CefBrowser, CefWindow) {
            let host = CefBrowser(url: URL(string: "chrome://bookmarks/")!)
            let window = CefWindow(browser: host)
            _ = await loaded(host)
            return (host, window)
        }
        func run(_ host: CefBrowser, _ label: String, _ script: String) async -> String {
            do {
                let value = try await host.evaluateJavaScript("(async () => { try { \(script) } catch (e) { return 'error ' + e.message } })()")
                note("\(label): \(value)")
                return "\(value)"
            } catch {
                note("\(label): error \(error)")
                return "error"
            }
        }
        switch experiment {
        case "ids":
            let strip = CefProfile.default.tabStrip
            let window = try? await CefChromeWindow.open(url: page("a"))
            _ = try? await window?.openChromiumTab(page("b"))
            _ = await waitUntil { window?.tabs.count == 2 && window?.tabs.allSatisfy { $0.browser != nil } == true }
            for tab in window?.tabs ?? [] {
                guard let browser = tab.browser else { continue }
                let w = try? await browser.devTools.send("Browser.getWindowForTarget")
                let t = try? await browser.devTools.send("Target.getTargetInfo")
                note("tab \(tab.id) window \(window?.id.rawValue ?? -1) cef \(browser.identifier): getWindowForTarget \(w.map { "\($0)" } ?? "-") targetInfo \(t.map { "\($0)" } ?? "-")")
            }
            let (host, hostWindow) = await bookmarksHost()
            _ = await run(host, "apis", "return JSON.stringify({sessions: typeof chrome.sessions, tabGroups: typeof chrome.tabGroups, tabs: typeof chrome.tabs, windows: typeof chrome.windows, send: typeof chrome.send})")
            // tab-strip-internals: its interface, and recently closed entries.
            let internals = CefBrowser(url: URL(string: "chrome://tab-strip-internals/")!)
            let internalsWindow = CefWindow(browser: internals)
            _ = await loaded(internals, timeout: .seconds(5))
            window?.tabs.last?.close()
            try? await Task.sleep(for: .seconds(1))
            let second = try? await CefChromeWindow.open(url: page("w2"))
            _ = try? await second?.openChromiumTab(page("w2b"))
            try? await Task.sleep(for: .seconds(1))
            second?.close()
            try? await Task.sleep(for: .seconds(1))
            _ = await run(internals, "internals", """
                const m = await import('chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js');
                const handler = new m.PageHandlerRemote();
                const router = new m.PageCallbackRouter();
                m.PageHandlerFactory.getRemote().createPageHandler(router.$.bindNewPipeAndPassRemote(), handler.$.bindNewPipeAndPassReceiver());
                const methods = Object.getOwnPropertyNames(Object.getPrototypeOf(handler)).join(',');
                const {data} = await handler.getTabStripData();
                const str = s => s && s.data ? String.fromCharCode(...s.data) : s;
                return methods + ' | keys ' + Object.keys(data).join(',') + ' | restore ' + JSON.stringify(data.tabRestore, (k, v) => typeof v == 'bigint' ? String(v) : (v && v.data && Array.isArray(v.data) ? str(v) : v)).slice(0, 3000) + ' | session ' + JSON.stringify(data.sessionRestore ?? data.session ?? null, (k, v) => typeof v == 'bigint' ? String(v) : v).slice(0, 1500)
                """)
            _ = await run(internals, "internals module exports", "const m = await import('chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js'); return Object.keys(m).join(',')")
            // tab search: what the page serves.
            let search = CefBrowser(url: URL(string: "chrome://tab-search.top-chrome/")!)
            let searchWindow = CefWindow(browser: search)
            _ = await loaded(search, timeout: .seconds(5))
            _ = await run(search, "tab search", "return JSON.stringify({url: location.href, scripts: [...document.scripts].map(s => s.src), send: typeof chrome.send, tabs: typeof chrome.tabs})")
            for path in ["tab_search.mojom-webui.js", "tab_search_api_proxy.js", "tab_search.js"] {
                _ = await run(search, "tab search \(path)", "try { const m = await import('chrome://tab-search.top-chrome/\(path)'); return Object.keys(m).slice(0, 60).join(','); } catch (e) { return 'no: ' + e.message }")
            }
            _ = await run(search, "tab search profile data", """
                const m = await import('chrome://tab-search.top-chrome/tab_search.js');
                const names = Object.keys(m);
                const proxyName = names.find(n => /TabSearchApiProxyImpl/.test(n));
                if (!proxyName) return 'no proxy among ' + names.length;
                const proxy = m[proxyName].getInstance();
                const {profileData} = await proxy.getProfileData();
                return JSON.stringify(profileData, (k, v) => typeof v == 'bigint' ? String(v) : (k == 'faviconUrl' || k == 'favicon' ? undefined : v)).slice(0, 3000);
                """)
            searchWindow.close()
            internalsWindow.close()
            hostWindow.close()
            _ = strip
        case let listener where listener.hasPrefix("listener="):
            // Which chrome.tabs or chrome.windows listener on the WebUI host
            // takes Chromium down, and when.
            let name = String(listener.dropFirst("listener=".count))
            let window = try? await CefChromeWindow.open(url: page("a"))
            let (host, hostWindow) = await bookmarksHost()
            _ = await run(host, "listen \(name)", "\(name).addListener((...a) => { window.__events = (window.__events || 0) + 1; }); return 'ok'")
            _ = try? await window?.openChromiumTab(page("b"))
            try? await Task.sleep(for: .seconds(1))
            if let first = window?.tabs.first { try? await first.move(to: -1) }
            try? await Task.sleep(for: .milliseconds(500))
            note("step: incognito window")
            let incognito = CefProfile.incognito()
            let privateWindow = try? await CefChromeWindow.open(url: page("p"), profile: incognito)
            try? await Task.sleep(for: .seconds(2))
            _ = await run(host, "events after incognito", "return String(window.__events || 0)")
            note("step: disable and enable the extension")
            let extensions = CefProfile.default.extensions
            if let id = (try? await extensions.refresh())?.first?.id {
                try? await extensions.setEnabled(false, for: id)
                try? await Task.sleep(for: .seconds(1))
                try? await extensions.setEnabled(true, for: id)
                try? await Task.sleep(for: .seconds(2))
            } else {
                note("no extension")
            }
            _ = await run(host, "events after extension", "return String(window.__events || 0)")
            note("step: close tab")
            window?.tabs.last?.close()
            try? await Task.sleep(for: .seconds(2))
            privateWindow?.close()
            try? await Task.sleep(for: .seconds(1))
            note("survived \(name)")
            hostWindow.close()
        case "session1", "crash1":
            // First launch: two windows of tabs, then a clean quit or a kill.
            let mode = ProcessInfo.processInfo.environment["CEFSWIFT_RESTORE_PREF"].flatMap(Int.init)
            if let mode {
                try? CefProfile.default.preferences.setValue(.number(Double(mode)), named: "session.restore_on_startup")
            }
            let one = try? await CefChromeWindow.open(url: page("s1a"))
            _ = try? await one?.openChromiumTab(page("s1b"))
            if let b = one?.tabs.last { _ = await waitUntil { b.browser != nil }; b.browser?.load(page("s1b2")) }
            let two = try? await CefChromeWindow.open(url: page("s2a"))
            _ = try? await two?.openChromiumTab(page("s2b"))
            try? await Task.sleep(for: .seconds(3))
            note("first launch: windows \(CefProfile.default.tabStrip.windows.map { $0.tabs.map { $0.url?.absoluteString ?? "-" } })")
            note("pref restore_on_startup \(CefProfile.default.preferences.value(named: "session.restore_on_startup").map { "\($0)" } ?? "-")")
            if experiment == "crash1" {
                note("killing")
                kill(getpid(), SIGKILL)
            }
            if ProcessInfo.processInfo.environment["CEFSWIFT_CLOSE_WINDOWS"] != nil {
                // Each window closed as a window, as Chrome's quit would record them.
                for window in CefProfile.default.tabStrip.windows { window.tabs.first?.browser?.execute(.closeWindow) }
                _ = await waitUntil(timeout: .seconds(5)) { CefRuntime.shared.browsers.isEmpty }
                let closed = await CefProfile.default.tabStrip.refreshRecentlyClosed()
                note("closed at quit: \(closed.map { "\($0.id) \($0.kind) tabs \($0.tabCount) at \($0.closedAt.map { "\($0.timeIntervalSince1970)" } ?? "-")" })")
                return
            }
            if ProcessInfo.processInfo.environment["CEFSWIFT_QUIT_WITH_WINDOWS"] != nil {
                // Quit as an app does, the windows still open.
                note("quitting with windows open")
                return
            }
        case "session2", "crash2":
            // Second launch: what Chromium opened by itself.
            note("at start: browsers \(CefRuntime.shared.browsers.map { $0.url?.absoluteString ?? "-" })")
            var created: [String] = []
            CefRuntime.shared.onBrowserCreated = { created.append($0.url?.absoluteString ?? "-") }
            try? await Task.sleep(for: .seconds(6))
            let strip = CefProfile.default.tabStrip
            await strip.refresh()
            note("after 6 s: created \(created.count), browsers \(CefRuntime.shared.browsers.map { "\($0.url?.absoluteString ?? "-")" })")
            note("strip windows \(strip.windows.map { $0.tabs.map { $0.url?.absoluteString ?? "-" } }) closed \(strip.recentlyClosed.map { "\($0.kind) \($0.title)" })")
            note("pref restore_on_startup \(CefProfile.default.preferences.value(named: "session.restore_on_startup").map { "\($0)" } ?? "-") exit_type \(CefProfile.default.preferences.value(named: "profile.exit_type").map { "\($0)" } ?? "-") exited_cleanly \(CefProfile.default.preferences.value(named: "profile.exited_cleanly").map { "\($0)" } ?? "-")")
            for window in NSApp.windows where window.isVisible {
                let children = (window.childWindows ?? []).map { CefChromiumTesting.describe($0) }
                note("window \(type(of: window)) '\(window.title)' children \(children.map { "\($0.kind ?? "-") '\($0.title)' \($0.classes.prefix(12))" })")
            }
            let closedAtStart = await strip.refreshRecentlyClosed()
            note("closed at start: \(closedAtStart.map { "\($0.id) \($0.kind) tabs \($0.tabCount) at \($0.closedAt.map { "\($0.timeIntervalSince1970)" } ?? "-")" })")
            if experiment == "crash2" {
                // Chromium's own restore, if offered: IDC_RESTORE_TAB on a new window.
                let window = try? await CefChromeWindow.open(url: page("after"))
                try? await Task.sleep(for: .seconds(2))
                let closedAfterOpen = await strip.refreshRecentlyClosed()
                note("closed after a window opened: \(closedAfterOpen.map { "\($0.id) \($0.kind) tabs \($0.tabCount)" })")
                let search = CefBrowser(url: URL(string: "chrome://tab-search.top-chrome/")!)
                let searchWindow = CefWindow(browser: search)
                _ = await loaded(search, timeout: .seconds(5))
                _ = await run(search, "tab search closed", """
                    const m = await import('chrome://tab-search.top-chrome/tab_search.js');
                    const {profileData} = await m.TabSearchApiProxyImpl.getInstance().getProfileData();
                    return JSON.stringify(profileData.recentlyClosedTabs.map(t => [t.tabId, t.title]));
                    """)
                searchWindow.close()
                let closedLater = await strip.refreshRecentlyClosed()
                note("closed after tab search: \(closedLater.map { "\($0.id) \($0.kind) tabs \($0.tabCount)" })")
                for nsWindow in NSApp.windows where nsWindow.isVisible {
                    let children = (nsWindow.childWindows ?? []).map { CefChromiumTesting.describe($0) }
                    note("after open: window '\(nsWindow.title)' children \(children.map { "\($0.kind ?? "-") '\($0.title)' \($0.classes.prefix(16))" })")
                }
                window?.tabs.first?.browser?.execute(.restoreTab)
                try? await Task.sleep(for: .seconds(3))
                await strip.refresh()
                note("after IDC_RESTORE_TAB: \(strip.windows.map { $0.tabs.map { $0.url?.absoluteString ?? "-" } })")
            }
        case "restore":
            // Reopening a given entry: tab search's openRecentlyClosedEntry,
            // and closing a whole window (IDC_CLOSE_WINDOW).
            let strip = CefProfile.default.tabStrip
            func layout() -> String { "\(strip.windows.map { "\($0.id): " + $0.tabs.map { "\($0.url?.query ?? $0.title)" }.joined(separator: ",") })" }
            let one = try? await CefChromeWindow.open(url: URL(string: "chrome://version/?a")!)
            _ = try? await one?.openChromiumTab(URL(string: "chrome://version/?b")!)
            if let b = one?.tabs.last { _ = await waitUntil { b.browser != nil }; b.browser?.load(URL(string: "chrome://version/?b2")!) }
            try? await Task.sleep(for: .seconds(1))
            _ = try? await one?.openChromiumTab(URL(string: "chrome://version/?c")!)
            let two = try? await CefChromeWindow.open(url: URL(string: "chrome://version/?w2a")!)
            _ = try? await two?.openChromiumTab(URL(string: "chrome://version/?w2b")!)
            try? await Task.sleep(for: .seconds(1))
            let bBrowser = one?.tabs.first { $0.url?.query == "b2" }?.browser
            note("before: \(layout())")
            one?.tabs.first { $0.url?.query == "b2" }?.close()
            try? await Task.sleep(for: .seconds(1))
            two?.tabs.first?.browser?.execute(.closeWindow)
            try? await Task.sleep(for: .seconds(2))
            let closed = await strip.refreshRecentlyClosed()
            note("closed: \(closed.map { "\($0.id) \($0.kind) '\($0.title)' tabs \($0.tabCount)" }) layout \(layout())")
            let search = CefBrowser(url: URL(string: "chrome://tab-search.top-chrome/")!)
            let searchWindow = CefWindow(browser: search)
            _ = await loaded(search, timeout: .seconds(5))
            for item in closed where item.kind == .tab || item.kind == .window {
                _ = await run(search, "reopen \(item.kind) \(item.id)", """
                    const m = await import('chrome://tab-search.top-chrome/tab_search.js');
                    m.TabSearchApiProxyImpl.getInstance().openRecentlyClosedEntry(\(item.id), false, false, 0);
                    return 'sent';
                    """)
                try? await Task.sleep(for: .seconds(2))
                await strip.refresh()
                note("after reopening \(item.kind): \(layout()) browsers \(CefRuntime.shared.browsers.map { $0.url?.query ?? "-" }) visible windows \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) '\($0.title)'" })")
            }
            if let restored = strip.windows.flatMap(\.tabs).first(where: { $0.url?.query == "b2" }) {
                note("restored b: same browser \(restored.browser === bBrowser) canGoBack \(restored.browser?.canGoBack ?? false) index \(restored.index) in \(restored.window?.id.rawValue ?? -1)")
            }
            searchWindow.close()
        case "audio":
            // What the NSWindow title says while the active tab plays sound,
            // and what tab search's page router offers.
            let window = try? await CefChromeWindow.open(url: page("sound"))
            _ = await waitUntil { window?.activeTab?.browser != nil && window?.window != nil }
            let browser = window?.activeTab?.browser
            let titles = Box<[String]>([])
            let observation = window?.window?.observe(\.title, options: [.new]) { nsWindow, _ in
                let title = nsWindow.title
                MainActor.assumeIsolated { titles.value.append(title) }
            }
            note("title before: '\(window?.window?.title ?? "-")'")
            _ = try? await browser?.evaluateJavaScript("""
                window.ctx = new AudioContext(); const o = ctx.createOscillator(); const g = ctx.createGain(); g.gain.value = 0.001;
                o.connect(g).connect(ctx.destination); o.start(); 'ok'
                """, userGesture: true)
            try? await Task.sleep(for: .seconds(3))
            await window?.strip.refresh()
            note("title playing: '\(window?.window?.title ?? "-")' audible \(window?.activeTab?.isAudible ?? false) titles \(titles.value)")
            browser?.isAudioMuted = true
            try? await Task.sleep(for: .seconds(1))
            note("title muted: '\(window?.window?.title ?? "-")' titles \(titles.value)")
            browser?.isAudioMuted = false
            _ = try? await browser?.evaluateJavaScript("ctx.close(); 'ok'")
            try? await Task.sleep(for: .seconds(3))
            note("title stopped: '\(window?.window?.title ?? "-")' titles \(titles.value)")
            observation?.invalidate()
            let search = CefBrowser(url: URL(string: "chrome://tab-search.top-chrome/")!)
            let searchWindow = CefWindow(browser: search)
            _ = await loaded(search, timeout: .seconds(5))
            _ = await run(search, "tab search router", """
                const m = await import('chrome://tab-search.top-chrome/tab_search.js');
                const proxy = m.TabSearchApiProxyImpl.getInstance();
                const router = proxy.getCallbackRouter();
                return Object.keys(router).join(',') + ' | handler ' + Object.getOwnPropertyNames(Object.getPrototypeOf(proxy)).join(',');
                """)
            searchWindow.close()
        case "gpu":
            // The GPU process's footprint with one page in a CefWindow, then
            // in a window Chrome draws, at the same size.
            func gpu(_ label: String) async {
                try? await Task.sleep(for: .seconds(6))
                note("gpu \(label): \(helperFootprints())")
                if label.hasPrefix("Chrome window") {
                    note("gpu categories: \(gpuCategories())")
                    CefRuntime.shared.taskManager.refresh()
                    try? await Task.sleep(for: .seconds(1))
                    let tasks = CefRuntime.shared.taskManager.tasks
                    note("tasks: \(tasks.map { "\($0.kind) '\($0.title.prefix(40))' \(($0.memory ?? 0) >> 20)" })")
                }
            }
            let frame = CGRect(x: 60, y: 60, width: 1200, height: 900)
            await gpu("nothing")
            var configuration = CefWindow.Configuration()
            configuration.frame = frame
            let viewsBrowser = CefBrowser(url: page("v"))
            let views = CefWindow(browser: viewsBrowser, configuration: configuration)
            _ = await loaded(viewsBrowser)
            await gpu("CefWindow")
            views.close()
            _ = await waitUntil { viewsBrowser.state == .closed }
            await gpu("closed")
            let chrome = CefRuntime.shared.openChromeWindow(url: page("c"), frame: frame)
            _ = await loaded(chrome)
            await gpu("Chrome window")
            await gpu("Chrome window, 6 s later")
            await gpu("Chrome window, 12 s later")
            let strip = CefProfile.default.tabStrip
            strip.layout = .vertical(width: 200)
            await gpu("Chrome window, vertical tabs")
            strip.layout = .horizontal
            chrome.nativeView?.window?.miniaturize(nil)
            await gpu("Chrome window minimized")
            chrome.nativeView?.window?.deminiaturize(nil)
            await gpu("Chrome window again")
            chrome.close(force: true)
            _ = await waitUntil { chrome.state == .closed }
            await gpu("closed")
        default:
            note("unknown experiment \(experiment)")
        }
        for open in CefRuntime.shared.browsers { open.close(force: true) }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }
}

/// Each helper process's physical footprint, by kind, in MiB.
@MainActor
func helperFootprints() -> String {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,ppid=,args="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    let me = getpid()
    var parts: [String] = []
    var total = 0.0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]), ppid == me || pid == me else { continue }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { continue }
        let mib = Double(info.ri_phys_footprint) / 1_048_576
        total += mib
        let args = String(fields[2])
        let kind = pid == me ? "browser" : (args.range(of: "--type=[a-z-]+", options: .regularExpression).map { String(args[$0].dropFirst(7)) } ?? "?")
        let sub = args.range(of: "--utility-sub-type=[a-zA-Z.]+", options: .regularExpression).map { ":" + String(args[$0].split(separator: ".").last ?? "") } ?? ""
        parts.append("\(kind)\(sub) \(String(format: "%.1f", mib))")
    }
    return String(format: "total %.1f; ", total) + parts.sorted().joined(separator: ", ")
}

/// The GPU process's footprint by category, from `footprint`.
@MainActor
func gpuCategories() -> String {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,ppid=,args="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    let me = getpid()
    let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true) }
    guard let row = rows.first(where: { $0.count > 2 && Int32($0[1]) == me && $0.contains("--type=gpu-process") }) else { return "no gpu" }
    let tool = Process()
    tool.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
    tool.arguments = ["-p", String(row[0])]
    let out = Pipe()
    tool.standardOutput = out
    try? tool.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    tool.waitUntilExit()
    return text.split(separator: "\n").filter { $0.contains("MB") || $0.contains("KB") }.prefix(14)
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
