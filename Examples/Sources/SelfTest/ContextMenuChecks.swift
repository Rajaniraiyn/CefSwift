import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Context menus, opened with a right click the DevTools protocol sends,
/// on each kind of target, in each way a browser can be hosted.
///
/// `SELFTEST_MENU_DUMP=<folder>` also writes, per hosting mode, the menu
/// Chromium built and the menu shown, item by item, and what choosing
/// each item did.
extension SelfTest {
    /// Answers ``CefBrowserDelegate/browser(_:runContextMenu:for:)`` without
    /// showing anything, recording each menu and choosing what `choose`
    /// picks.
    final class MenuRecorder: CefBrowserDelegate, CefProfileDelegate {
        var menus: [(menu: CefContextMenu, target: CefContextMenuTarget)] = []
        var choose: (CefContextMenu) -> CefContextMenu.Item? = { _ in nil }
        /// Runs before the choice is returned.
        var beforeChoosing: (@MainActor () async -> Void)?
        var windowOpens: [CefWindowOpenRequest] = []
        var downloads: [String] = []
        /// Shows the stock menu instead of choosing.
        var usesStockMenu = false

        func browser(_ browser: CefBrowser, runContextMenu menu: CefContextMenu, for target: CefContextMenuTarget) async -> CefContextMenu.Item? {
            menus.append((menu, target))
            if usesStockMenu { return await CefContextMenuPresenter.present(menu, for: target, in: browser) }
            await beforeChoosing?()
            return choose(menu)
        }

        func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
            windowOpens.append(request)
            return .deny
        }

        func profile(_ profile: CefProfile, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
            downloads.append(download.suggestedFilename)
            return .cancel
        }
    }

    /// One thing to right-click on the menu page.
    struct MenuTarget {
        var name: String
        /// Script run first, such as one selecting text.
        var prepare = ""
        /// The element whose centre is clicked, or `nil` for `point`.
        var element: String?
        var point = CGPoint(x: 700, y: 420)
        var offset = CGPoint.zero
        var page = "page.html"
        var settle: Duration = .milliseconds(100)
    }

    static let menuTargets: [MenuTarget] = [
        MenuTarget(name: "page"),
        MenuTarget(name: "selection", prepare: "getSelection().selectAllChildren(document.getElementById('text'))", element: "text"),
        MenuTarget(name: "link", element: "link"),
        MenuTarget(name: "image", element: "image"),
        MenuTarget(name: "linked image", element: "imagelink"),
        MenuTarget(name: "field", prepare: "document.getElementById('field').focus()", element: "field"),
        MenuTarget(name: "field selection",
                   prepare: "const f = document.getElementById('field'); f.focus(); f.setSelectionRange(0, 5)",
                   element: "field", offset: CGPoint(x: -80, y: 0)),
        MenuTarget(name: "misspelling",
                   prepare: """
                       const t = document.getElementById('misspelt'); t.focus(); t.value = '';
                       document.execCommand('insertText', false, 'wrold ')
                       """,
                   element: "misspelt", offset: CGPoint(x: -85, y: -10), settle: .seconds(1)),
        MenuTarget(name: "video", element: "video"),
        MenuTarget(name: "audio", element: "audio"),
        MenuTarget(name: "canvas", element: "canvas"),
        MenuTarget(name: "iframe", element: "frame"),
        MenuTarget(name: "pdf", point: CGPoint(x: 450, y: 300), page: "doc.pdf", settle: .seconds(2)),
    ]

    /// Right-clicks `target` in `browser`, which `recorder` answers for, and
    /// returns the menu shown and Chromium's own.
    static func openMenu(
        _ target: MenuTarget, base: URL, in browser: CefBrowser, recorder: MenuRecorder, reload: Bool = false
    ) async -> (shown: CefContextMenu, chromium: CefContextMenu, target: CefContextMenuTarget)? {
        let url = base.appendingPathComponent(target.page)
        if browser.url != url || reload {
            guard await load(url, in: browser) else { return nil }
            try? await Task.sleep(for: target.settle)
        }
        var point = target.point
        if !target.prepare.isEmpty || target.element != nil {
            let script = """
                (() => { \(target.prepare);
                  const e = \(target.element.map { "document.getElementById('\($0)')" } ?? "null");
                  if (!e) return [0, 0];
                  const r = e.getBoundingClientRect();
                  return [r.left + r.width / 2, r.top + r.height / 2]; })()
                """
            guard let center = try? await browser.evaluateJavaScript(script).arrayValue,
                  center.count == 2, let x = center[0].doubleValue, let y = center[1].doubleValue
            else { return nil }
            if target.element != nil { point = CGPoint(x: x + target.offset.x, y: y + target.offset.y) }
            try? await Task.sleep(for: target.settle)
        }
        var chromium: CefContextMenu?
        CefBrowser.chromiumContextMenuObserver = { b, menu, _ in if b === browser { chromium = menu } }
        defer { CefBrowser.chromiumContextMenuObserver = nil }
        let before = recorder.menus.count
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": .string(type), "x": .number(point.x), "y": .number(point.y), "button": "right", "buttons": 2, "clickCount": 1,
            ])
        }
        guard await waitUntil(timeout: .seconds(5), { recorder.menus.count > before && chromium != nil }) else { return nil }
        let shown = recorder.menus[recorder.menus.count - 1]
        return (shown.menu, chromium!, shown.target)
    }

    /// A browser hosted one of the ways an app can host it.
    struct MenuHost {
        var name: String
        var browser: CefBrowser
        var close: @MainActor () async -> Void
    }

    static func makeMenuHost(
        _ style: String, base: URL, recorder: MenuRecorder, configure: (inout CefBrowser.Configuration) -> Void = { _ in }
    ) async -> MenuHost? {
        var configuration = CefBrowser.Configuration()
        configure(&configuration)
        // Downloads a menu item starts are decided by the profile.
        (configuration.profile ?? .default).delegate = recorder
        let url = base.appendingPathComponent("page.html")
        switch style {
        case "chrome":
            let browser = CefBrowser(url: url, configuration: configuration, delegate: recorder)
            let cefWindow = CefWindow(browser: browser)
            cefWindow.window?.setFrame(NSRect(x: 100, y: 100, width: 900, height: 640), display: true)
            cefWindow.show()
            guard await loaded(browser, title: "menu") else { cefWindow.close(); return nil }
            return MenuHost(name: style, browser: browser) {
                cefWindow.close()
                _ = await waitUntil { cefWindow.isClosed && browser.state == .closed }
            }
        case "offscreen":
            configuration.rendering = .offscreen
            let browser = CefBrowser(url: url, configuration: configuration, delegate: recorder)
            let view = hostOffscreen(browser)
            guard await loaded(browser, title: "menu") else { await closeHosted(browser, view); return nil }
            return MenuHost(name: style, browser: browser) { await closeHosted(browser, view) }
        default:
            let browser = CefBrowser(url: url, configuration: configuration, delegate: recorder)
            let view = hostWindowed(browser)
            guard await loaded(browser, title: "menu") else { await closeHosted(browser, view); return nil }
            return MenuHost(name: style, browser: browser) { await closeHosted(browser, view) }
        }
    }

    static func contextMenuChecks() async {
        guard let server = try? await LocalServer.start() else {
            check("contextMenu: local server starts", false)
            return
        }
        let base = URL(string: "http://127.0.0.1:\(server.port)/menu/")!
        if let dump = ProcessInfo.processInfo.environment["SELFTEST_MENU_DUMP"] {
            await dumpContextMenus(base: base, to: URL(fileURLWithPath: dump))
        } else {
            await contextMenuBehaviorChecks(base: base)
        }
        withExtendedLifetime(server) {}
    }

    /// Writes the menus and what their items do.
    static func dumpContextMenus(base: URL, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chromeTabs: [URL] = []
        let previousHandler = CefRuntime.shared.onChromeTab
        CefRuntime.shared.onChromeTab = { request in chromeTabs.append(request.url); return .close }
        defer { CefRuntime.shared.onChromeTab = previousHandler }
        let styles = ProcessInfo.processInfo.environment["SELFTEST_MENU_STYLES"]?.split(separator: ",").map(String.init)
            ?? ["windowed", "offscreen", "chrome"]
        for style in styles {
            for incognito in [false, true] {
                print("NOTE contextMenu dump: \(style)\(incognito ? " incognito" : "")")
                let recorder = MenuRecorder()
                guard let host = await makeMenuHost(style, base: base, recorder: recorder, configure: {
                    if incognito { $0.profile = .incognito() }
                }) else {
                    check("contextMenu \(style): page loads", false)
                    continue
                }
                var dump = "# \(style)\(incognito ? " incognito" : "")\n\n"
                let targets = incognito ? menuTargets.filter { ["page", "link"].contains($0.name) } : menuTargets
                for target in targets {
                    guard let opened = await openMenu(target, base: base, in: host.browser, recorder: recorder) else {
                        dump += "## \(target.name)\n\nno menu\n\n"
                        continue
                    }
                    dump += "## \(target.name)\n\ntarget: \(opened.target)\n\n"
                    dump += "### Chromium's menu\n\n" + menuTable(opened.chromium) + "\n### Shown\n\n" + menuTable(opened.shown) + "\n"
                    guard !incognito else { continue }
                    dump += "### Choosing each item\n\n"
                    for item in leaves(of: opened.shown) where item.isEnabled {
                        guard let command = item.command, !unprobedCommands.contains(command) else { continue }
                        let effect = await probe(command, target: target, base: base, host: host, recorder: recorder,
                                                 chromeTabs: { chromeTabs })
                        dump += "- \(command) \"\(item.title)\": \(effect)\n"
                        try? dump.write(
                            to: folder.appendingPathComponent("\(style)\(incognito ? "-incognito" : "").md"),
                            atomically: true, encoding: .utf8)
                    }
                    dump += "\n"
                }
                try? dump.write(
                    to: folder.appendingPathComponent("\(style)\(incognito ? "-incognito" : "").md"),
                    atomically: true, encoding: .utf8)
                await host.close()
            }
        }
    }

    /// Commands not chosen while probing: they open modal panels, speak, or
    /// show system windows that outlive the check.
    static let unprobedCommands: Set<CefContextMenuCommand> = [
        .print, .startSpeaking, .lookUp, .emojiAndSymbols, .savePage,
    ]

    static func leaves(of menu: CefContextMenu) -> [CefContextMenu.Item] {
        menu.items.flatMap { item -> [CefContextMenu.Item] in
            if let submenu = item.submenu { return leaves(of: submenu) }
            return item.isSeparator ? [] : [item]
        }
    }

    /// Chooses `command` from a fresh menu on `target` and describes what
    /// changed within two seconds.
    static func probe(
        _ command: CefContextMenuCommand, target: MenuTarget, base: URL, host: MenuHost, recorder: MenuRecorder,
        chromeTabs: () -> [URL]
    ) async -> String {
        let browser = host.browser
        print("NOTE contextMenu probe: \(target.name) \(command)")
        let state = "JSON.stringify([document.getElementById('video')?.loop, document.getElementById('video')?.controls, "
            + "document.getElementById('field')?.value, document.getElementById('misspelt')?.value, getSelection().toString(), "
            + "document.activeElement?.id])"
        recorder.choose = { $0[command] }
        var stateBefore: String?
        var urlBefore: URL?
        recorder.beforeChoosing = {
            stateBefore = try? await browser.evaluateJavaScript(state).stringValue
            urlBefore = browser.url
        }
        defer {
            recorder.choose = { _ in nil }
            recorder.beforeChoosing = nil
        }
        let browsersBefore = Set(CefRuntime.shared.browsers.map(ObjectIdentifier.init))
        let windowsBefore = NSApp.windows.filter(\.isVisible).count
        let opens = recorder.windowOpens.count, downloads = recorder.downloads.count, tabs = chromeTabs().count
        let pasteboard = NSPasteboard.general.changeCount
        guard await openMenu(target, base: base, in: browser, recorder: recorder, reload: true) != nil else { return "no menu" }
        try? await Task.sleep(for: .seconds(2))
        var effects: [String] = []
        if recorder.windowOpens.count > opens {
            effects += recorder.windowOpens[opens...].map { "window open \($0.disposition) \($0.targetURL?.absoluteString ?? "-")" }
        }
        if chromeTabs().count > tabs { effects += chromeTabs()[tabs...].map { "Chrome tab \($0.absoluteString)" } }
        if recorder.downloads.count > downloads { effects += recorder.downloads[downloads...].map { "download \($0)" } }
        if NSPasteboard.general.changeCount != pasteboard {
            let types = NSPasteboard.general.types?.map(\.rawValue).prefix(3).joined(separator: ",") ?? ""
            effects.append("pasteboard [\(types)] \"\(NSPasteboard.general.string(forType: .string)?.prefix(60) ?? "")\"")
        }
        if browser.isShowingDevTools { effects.append("DevTools open") }
        let newBrowsers = CefRuntime.shared.browsers.filter { !browsersBefore.contains(ObjectIdentifier($0)) }
        for other in newBrowsers {
            effects.append("new browser \(other.url?.absoluteString ?? "-")")
            other.close(force: true)
        }
        if browser.url != urlBefore { effects.append("navigated to \(browser.url?.absoluteString ?? "-")") }
        let stateAfter = try? await browser.evaluateJavaScript(state).stringValue
        if stateAfter != stateBefore { effects.append("page state \(stateBefore ?? "-") → \(stateAfter ?? "-")") }
        let windowsAfter = NSApp.windows.filter(\.isVisible).count
        if windowsAfter != windowsBefore { effects.append("visible windows \(windowsBefore) → \(windowsAfter)") }
        if browser.isShowingDevTools {
            browser.closeDevTools()
            _ = await waitUntil(timeout: .seconds(3)) { !browser.isShowingDevTools }
        }
        _ = await waitUntil(timeout: .seconds(3)) { newBrowsers.allSatisfy { $0.state == .closed } }
        return effects.isEmpty ? "NOTHING" : effects.joined(separator: "; ")
    }

    /// The menu as a Markdown table, one row per item.
    static func menuTable(_ menu: CefContextMenu, depth: Int = 0) -> String {
        var rows = depth == 0 ? "| id | command | label | enabled | type | group |\n|---|---|---|---|---|---|\n" : ""
        let indent = String(repeating: "› ", count: depth)
        for item in menu.items {
            if item.isSeparator {
                rows += "| | \(indent)— | | | separator | |\n"
                continue
            }
            let details = item.chromiumDetails
            rows += "| \(details.map { "\($0.id)" } ?? "app") | \(indent)\(item.command.map { "\($0)" } ?? "-") | \(item.title) | "
                + "\(item.isEnabled ? "yes" : "no")\(item.isChecked ? ", checked" : "") | \(details?.kind ?? "app") | "
                + "\(details?.group.map { "\($0)" } ?? "") |\n"
            if let submenu = item.submenu { rows += menuTable(submenu, depth: depth + 1) }
        }
        return rows
    }
}

/// The pages of the context-menu checks, which `LocalServer` serves under
/// `/menu/`: on http, as Chrome's QR code and sharing items want.
enum MenuPages {
    static func content(for path: String) -> (type: String, body: Data)? {
        switch path {
        case "page.html":
            return ("text/html", Data("""
                <title>menu</title>
                <style>body { margin: 0; font: 16px sans-serif } body > * { position: absolute }</style>
                <p id=text style="left: 10px; top: 0">Plain words to select</p>
                <a id=link href="target.html" style="left: 10px; top: 50px">A link</a>
                <img id=image src="icon.png" width=40 height=40 style="left: 10px; top: 90px">
                <a id=imagelink href="target.html" style="left: 70px; top: 90px"><img src="icon.png" width=40 height=40></a>
                <input id=field value="hello world" style="left: 10px; top: 150px; width: 200px">
                <textarea id=misspelt spellcheck=true style="left: 10px; top: 190px; width: 200px; height: 40px"></textarea>
                <video id=video src="tone.wav" controls style="left: 250px; top: 10px; width: 160px; height: 90px"></video>
                <audio id=audio src="tone.wav" controls style="left: 250px; top: 120px"></audio>
                <canvas id=canvas width=60 height=40 style="left: 250px; top: 180px; background: #ccc"></canvas>
                <iframe id=frame src="frame.html" style="left: 450px; top: 10px; width: 150px; height: 100px"></iframe>
                """.utf8))
        case "frame.html": return ("text/html", Data("<title>frame</title><p>frame</p>".utf8))
        case "target.html": return ("text/html", Data("<title>target</title><p>target</p>".utf8))
        case "icon.png": return ("image/png", EdgePages.iconPNG)
        case "tone.wav": return ("audio/wav", EdgePages.toneWAV)
        case "doc.pdf": return ("application/pdf", pdf)
        default: return nil
        }
    }

    /// A one-page PDF.
    static let pdf: Data = {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 60))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }()
}
