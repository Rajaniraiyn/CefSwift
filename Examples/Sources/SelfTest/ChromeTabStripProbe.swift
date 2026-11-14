import AppKit
@_spi(Testing) import CefKit

/// Exploratory probe (`CEFSWIFT_SELFTEST_PROBE=chromeTabStrip`): a window
/// Chrome draws, with several real tabs — what reaches the app, where the
/// page sits, what `chrome.tabs` in the bookmarks WebUI can do and what
/// `chrome://tab-strip-internals` reports.
extension SelfTest {
    static func chromeTabStripProbe() async {
        var created: [CefBrowser] = []
        CefRuntime.shared.onBrowserCreated = { created.append($0) }
        let first = CefRuntime.shared.openChromeWindow(url: page("a"))
        _ = await loaded(first, title: "a")
        guard let window = first.nativeView?.window else { return print("NOTE no window") }
        print("NOTE window \(type(of: window)) frame \(NSStringFromRect(window.frame)) style \(window.styleMask.rawValue)")

        let host = CefBrowser(url: URL(string: "chrome://bookmarks/")!)
        let hostWindow = CefWindow(browser: host)
        _ = await loaded(host)
        func run(_ label: String, _ script: String) async {
            do {
                print("NOTE \(label): \(try await host.evaluateJavaScript(script))")
            } catch {
                print("NOTE \(label): error \(error)")
            }
            fflush(stdout)
        }
        let query = "(async () => JSON.stringify((await chrome.tabs.query({})).map(t => [t.id, t.windowId, t.index, t.pinned, t.groupId, t.active, t.title, t.url.slice(0, 40)])))()"
        func tabsOf(_ body: String) -> String {
            """
            (async () => { try {
              const [a] = (await chrome.tabs.query({})).filter(t => t.title == 'a');
              const tabs = await chrome.tabs.query({windowId: a.windowId});
              \(body)
            } catch (e) { return 'error ' + e.message } })()
            """
        }
        await run("create", tabsOf("for (const u of ['chrome://version/?b', 'chrome://version/?c']) await chrome.tabs.create({windowId: a.windowId, url: u}); return 'ok'"))
        try? await Task.sleep(for: .seconds(1))
        print("NOTE after create: created \(created.count), browsers \(CefRuntime.shared.browsers.map { "\($0.title)/\($0.lifecycle)" })")
        await run("pin", tabsOf("await chrome.tabs.update(tabs[0].id, {pinned: true}); return 'ok'"))
        await run("move", tabsOf("await chrome.tabs.move(tabs[2].id, {index: 1}); return 'ok'"))
        await run("group", tabsOf("return String(await chrome.tabs.group({tabIds: [tabs[1].id, tabs[2].id], createProperties: {windowId: a.windowId}}))"))
        await run("activate", tabsOf("await chrome.tabs.update(tabs[1].id, {active: true}); return 'ok'"))
        await run("duplicate", tabsOf("const t = await chrome.tabs.duplicate(tabs[2].id); return t.index + ' ' + t.windowId"))
        await run("ungroup", tabsOf("await chrome.tabs.ungroup([tabs[2].id]); return 'ok'"))
        if let last = CefRuntime.shared.browsers.last(where: { $0.title == "About Version" }) {
            last.close()
            let closed = await waitUntil(timeout: .seconds(5)) { last.state == .closed }
            print("NOTE close a tab through CEF: closed \(closed)")
        }
        await run("new window with tab", tabsOf("const w = await chrome.windows.create({tabId: tabs[2].id}); return w.id + ' ' + w.type + ' tabs ' + w.tabs?.length"))
        await run("windows", "(async () => JSON.stringify((await chrome.windows.getAll()).map(w => [w.id, w.type, w.focused, w.state])))()")
        await run("query after", query)
        first.execute(CefChromeCommand(rawValue: 34101))  // IDC_CREATE_NEW_TAB_GROUP, on the active tab
        try? await Task.sleep(for: .seconds(1))
        await run("query after IDC_CREATE_NEW_TAB_GROUP", query)

        // Where the page sits, and covering Chrome's strip and toolbar.
        if let content = window.contentView,
           let page = content.subviews.first(where: { "\(type(of: $0))" == "WebContentsViewCocoa" }) {
            let pageRect = content.convert(page.bounds, from: page)
            print("NOTE content flipped \(content.isFlipped), page in window \(NSStringFromRect(page.convert(page.bounds, to: nil))), content \(NSStringFromRect(content.bounds))")
            let coverFrame = content.isFlipped
                ? CGRect(x: 0, y: 0, width: content.bounds.width, height: pageRect.minY)
                : CGRect(x: 0, y: pageRect.maxY, width: content.bounds.width, height: content.bounds.height - pageRect.maxY)
            let cover = NSView(frame: coverFrame)
            // In the frame view, above Chromium's content view, which
            // answers every hit test inside itself.
            cover.frame = content.convert(coverFrame, to: content.superview)
            content.superview?.addSubview(cover, positioned: .above, relativeTo: content)
            let superview = content.superview
            let buttons = window.standardWindowButton(.closeButton)
            let buttonHit = buttons.flatMap { b in superview?.hitTest(b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: superview)) }
            print("NOTE cover: close button still hit \(buttonHit === buttons)")
            let hit = superview?.hitTest(content.convert(CGPoint(x: 300, y: coverFrame.midY), to: superview))
            let pageHit = superview?.hitTest(content.convert(CGPoint(x: 300, y: pageRect.midY), to: superview))
            print("NOTE cover \(NSStringFromRect(coverFrame)): strip point hits cover \(hit === cover) (\(hit.map { "\(type(of: $0))" } ?? "-")), page point hits \(pageHit.map { "\(type(of: $0))" } ?? "-")")
        }

        // A real move to another Chrome window: the same CefBrowser?
        let second = CefRuntime.shared.openChromeWindow(url: page("z"))
        _ = await loaded(second, title: "z")
        let before = CefRuntime.shared.browsers.first { $0.url?.absoluteString.hasSuffix("?c") == true }
        await run("move to window", tabsOf("const [z] = (await chrome.tabs.query({})).filter(t => t.title == 'z'); const [c] = tabs.filter(t => t.url.endsWith('?c')); await chrome.tabs.move(c.id, {windowId: z.windowId, index: -1}); return 'ok'"))
        try? await Task.sleep(for: .seconds(1))
        let after = CefRuntime.shared.browsers.first { $0.url?.absoluteString.hasSuffix("?c") == true }
        print("NOTE moved tab: same CefBrowser \(before != nil && before === after), state \(after.map { "\($0.state)" } ?? "-"), identifier \(before?.identifier ?? -1) -> \(after?.identifier ?? -1), window changed \(after?.nativeView?.window !== window), live browsers \(CefRuntime.shared.browsers.count)")
        await run("query after move", query)

        // chrome://tab-strip-internals: every window's tab strip.
        let internals = CefBrowser(url: URL(string: "chrome://tab-strip-internals/")!)
        let internalsWindow = CefWindow(browser: internals)
        _ = await loaded(internals, timeout: .seconds(5))
        print("NOTE internals: url \(internals.url?.absoluteString ?? "-") title \(internals.title)")
        do {
            let value = try await internals.evaluateJavaScript("""
                (async () => { try {
                  const m = await import('chrome://tab-strip-internals/tab_strip_internals.mojom-webui.js');
                  const handler = new m.PageHandlerRemote();
                  const router = new m.PageCallbackRouter();
                  m.PageHandlerFactory.getRemote().createPageHandler(router.$.bindNewPipeAndPassRemote(), handler.$.bindNewPipeAndPassReceiver());
                  const {data} = await handler.getTabStripData();
                  const str = s => s && s.data ? String.fromCharCode(...s.data) : '';
                  const walk = n => { const d = n.data; const k = Object.keys(d).find(k => d[k]); const v = d[k];
                    return k == 'tab' ? ['tab', v.id.nodeId, str(v.title), String(v.url?.url ?? JSON.stringify(v.url)).slice(0, 30), v.active, v.pinned, JSON.stringify(v.alertStates)]
                      : [k, v.visualData ? JSON.stringify(v.visualData, (key, x) => key == 'title' ? str(x) : x) : '', n.children.map(walk)] };
                  return JSON.stringify(data.tabstripTree.windows.map(w => [w.id.nodeId, w.tabstripModel.root ? walk(w.tabstripModel.root) : null]))
                } catch (e) { return 'error ' + e.message + ' ' + e.stack } })()
                """)
            print("NOTE internals data: \(value)")
        } catch { print("NOTE internals data: error \(error)") }
        internalsWindow.close()
        hostWindow.close()
        for open in CefRuntime.shared.browsers { open.close(force: true) }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }
}
