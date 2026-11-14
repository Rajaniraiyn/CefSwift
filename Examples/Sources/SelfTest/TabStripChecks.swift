import AppKit
import CefChromium
import CefKit
import SwiftUI

/// `CefTabStrip`, `CefTab`, `CefChromeWindow`: Chromium's own tabbed
/// windows, mirrored and driven, with the app's views over Chrome's.
extension SelfTest {
    static func tabStripChecks() async {
        let strip = CefProfile.default.tabStrip
        func url(_ name: String) -> URL { URL(string: "chrome://version/?\(name)")! }
        func tabs(_ window: CefChromeWindow) -> [String] { window.tabs.map { $0.url?.query ?? "-" } }
        func tab(_ name: String, in window: CefChromeWindow? = nil) -> CefTab? {
            (window.map { [$0] } ?? strip.windows).flatMap(\.tabs).first { $0.url == url(name) }
        }
        var announced: [CefChromeWindow] = []
        strip.onWindowOpened = { announced.append($0) }
        defer { strip.onWindowOpened = nil }

        let window: CefChromeWindow
        do {
            window = try await CefChromeWindow.open(url: url("a"))
        } catch {
            check("tab strip: opens a window Chrome draws", false, detail: "\(error), \(strip.lastError ?? "")")
            return closeAll()
        }
        _ = await waitUntil(timeout: .seconds(10)) { window.window != nil && window.activeTab?.browser != nil }
        check("tab strip: opens a window, listed with its tab and browser",
              strip.windows.contains { $0 === window } && tabs(window) == ["a"] && window.activeTab?.browser?.url == url("a")
                && window.window != nil && announced.contains { $0 === window },
              detail: "\(tabs(window)) window \(window.window != nil) announced \(announced.count) \(strip.lastError ?? "")")

        // Tabs the app makes (configured) and tabs Chromium makes.
        var configuration = CefBrowser.Configuration()
        configuration.userScripts = [CefUserScript(source: "window.selfTestConfigured = '1'")]
        await expect("tab strip: opens an app-configured tab in the window, keeping its browser") {
            let probe = try await window.openTab(URL(string: "data:text/html,<title>configured</title>")!, configuration: configuration)
            _ = try? await probe.browser?.waitUntilLoaded(timeout: .seconds(10))
            let scripted = try await probe.browser?.evaluateJavaScript("String(window.selfTestConfigured || '')").stringValue
            probe.close()
            _ = await waitUntil { probe.window == nil }
            let b = try await window.openTab(url("b"), configuration: configuration)
            _ = try? await b.browser?.waitUntilLoaded(timeout: .seconds(10))
            let configured = scripted
            return (tabs(window) == ["a", "b"] && b.isActive && b.browser?.url == url("b") && configured == "1"
                    && strip.windows.count == 1, "\(tabs(window)) configured \(configured ?? "-") windows \(strip.windows.count) browser \(b.browser?.identifier ?? -1) scripts \(b.browser?.configuration.userScripts.count ?? -1) url \(b.browser?.url?.absoluteString ?? "-")")
        }
        await expect("tab strip: opens Chromium's own tab, at an index, in the background") {
            let c = try await window.openChromiumTab(url("c"), at: 1, isActive: false)
            _ = await waitUntil { c.browser != nil }
            return (tabs(window) == ["a", "c", "b"] && !c.isActive && c.browser?.url == url("c"), "\(tabs(window))")
        }

        // Exact matching: tabs of the same address, in the background.
        do {
            _ = try await window.openChromiumTab(url("a"), isActive: false)
            _ = try await window.openChromiumTab(url("a"), isActive: false)
        } catch { check("tab strip: opens tabs of the same address", false, detail: "\(error)") }
        _ = await waitUntil(timeout: .seconds(10)) { window.tabs.count == 5 && window.tabs.allSatisfy { $0.browser != nil } }
        let browsers = window.tabs.compactMap(\.browser)
        check("tab strip: matches each tab with its own browser, same addresses included",
              browsers.count == 5 && Set(browsers.map(ObjectIdentifier.init)).count == 5
                && window.tabs.allSatisfy { $0.browser?.url == $0.url },
              detail: "\(window.tabs.map { "\($0.url?.query ?? "-"):\($0.browser?.identifier ?? -1)" })")
        // Each match is the browser Chromium shows when the tab is selected.
        await expect("tab strip: the matched browser is the one shown when its tab is selected") {
            var wrong: [String] = []
            for candidate in window.tabs where candidate.url == url("a") {
                try await candidate.select()
                _ = await waitUntil(timeout: .seconds(3)) { candidate.browser?.nativeView?.window === window.window }
                if candidate.browser?.nativeView?.window !== window.window { wrong.append("\(candidate.id)") }
            }
            return (wrong.isEmpty, "not shown: \(wrong)")
        }

        await expect("tab strip: pins a tab, which moves to the front") {
            guard let c = tab("c") else { return false }
            try await c.pin()
            return await waitUntil(timeout: .seconds(5)) { c.isPinned && c.index == 0 }
        }
        await expect("tab strip: groups tabs, and reads the group back") {
            guard let a = tab("a"), let b = tab("b") else { return false }
            let group = try await strip.group([a, b])
            return await waitUntil(timeout: .seconds(5)) {
                group != nil && a.group === group && b.group === group && window.groups.first === group
                    && group?.tabs.map(\.id).contains(a.id) == true
            }
        }
        if let group = window.groups.first {
            do {
                try await group.setCollapsed(true)
                check("tab strip: collapses a group", await waitUntil(timeout: .seconds(3)) { group.isCollapsed })
            } catch CefTabStrip.Error.unsupported(let reason) {
                skip("tab strip: collapses a group", because: reason, .limitation)
            } catch {
                check("tab strip: collapses a group", false, detail: "\(error)")
            }
            await expect("tab strip: renames and recolours a group through Chrome's own editor") {
                try await group.setTitle("Reading")
                try await group.setColor(.green)
                let done = await waitUntil(timeout: .seconds(3)) { group.title == "Reading" && group.color == .green }
                return (done, "title '\(group.title)' color \(group.color)")
            }
        }
        await expect("tab strip: ungroups") {
            guard let b = tab("b") else { return false }
            try await strip.ungroup([b])
            return await waitUntil(timeout: .seconds(5)) { b.group == nil && tab("a")?.group != nil }
        }
        await expect("tab strip: selects several tabs, as ⌘-clicks do") {
            guard let a = tab("a"), let b = tab("b") else { return false }
            try await strip.select([b, a])
            return await waitUntil(timeout: .seconds(5)) { a.isSelected && b.isSelected && window.selectedTabs.count == 2 }
        }
        await expect("tab strip: mutes a tab") {
            guard let b = tab("b") else { return (false, "no tab") }
            b.setMuted(true)
            let muted = await waitUntil(timeout: .seconds(5)) { b.isMuted }
            b.setMuted(false)
            let unmuted = await waitUntil(timeout: .seconds(5)) { !b.isMuted }
            return (muted && unmuted, "muted \(muted)")
        }
        // A change made by Chromium itself shows up.
        let count = window.tabs.count
        window.activeTab?.browser?.execute(.newTab)
        check("tab strip: follows a change Chromium makes (Chrome's New Tab command)",
              await waitUntil(timeout: .seconds(5)) { window.tabs.count == count + 1 },
              detail: "\(tabs(window)) \(strip.lastError ?? "")")

        await expect("tab strip: captures a background tab's preview") {
            guard let background = window.tabs.first(where: { !$0.isActive && $0.browser != nil }) else {
                return (false, "no background tab")
            }
            let start = ContinuousClock.now
            let preview = try await background.capturePreview()
            let elapsed = ContinuousClock.now - start
            return (preview.image.size.width > 50 && preview.image.size.height > 50 && background.preview != nil,
                    "\(preview.image.size) in \(elapsed)")
        }

        await hostChecks(window)

        // Moves between windows keep the browser.
        let other: CefChromeWindow
        do { other = try await CefChromeWindow.open(url: url("z")) } catch {
            check("tab strip: opens a second window", false, detail: "\(error)")
            return closeAll()
        }
        await expect("tab strip: moves a tab to another window, keeping its browser") {
            guard let b = tab("b") else { return (false, "no tab") }
            let before = b.browser
            try await b.move(to: 1, in: other)
            let moved = await waitUntil(timeout: .seconds(5)) { b.window === other && b.index == 1 }
            return (moved && before != nil && b.browser === before && before?.state == .live && tab("b") === b,
                    "in \(b.window?.id.description ?? "-") at \(b.index), browser \(before?.identifier ?? -1) -> \(b.browser?.identifier ?? -1)")
        }
        await expect("tab strip: moves a tab to a new window, announced") {
            guard let b = tab("b") else { return (false, "no tab") }
            let before = b.browser
            let made = try await b.moveToNewWindow()
            let shown = await waitUntil(timeout: .seconds(5)) { made.window != nil && announced.contains { $0 === made } }
            return (shown && made.tabs.first === b && b.browser === before, "window \(made.window != nil) announced \(announced.count)")
        }
        await expect("tab strip: closes a tab, and reopens it") {
            guard let b = tab("b") else { return (false, "no tab") }
            b.close()
            guard await waitUntil(timeout: .seconds(5), { tab("b") == nil }) else { return (false, "not closed") }
            let listed = await waitUntil(timeout: .seconds(5)) { strip.recentlyClosed.contains { $0.url == url("b") } }
            other.reopenClosedTab()
            let reopened = await waitUntil(timeout: .seconds(5)) { tab("b")?.browser != nil }
            return (reopened, "recently closed listed \(listed): \(strip.recentlyClosed.prefix(3))")
        }

        // Closing every window with background tabs leaves nothing behind.
        for open in strip.windows { open.close() }
        check("tab strip: closing windows with background tabs closes every browser",
              await waitUntil(timeout: .seconds(10)) { strip.windows.isEmpty && CefRuntime.shared.browsers.isEmpty },
              detail: "windows \(strip.windows.count), browsers \(CefRuntime.shared.browsers.map { $0.url?.absoluteString ?? "-" })")
        closeAll()

        func closeAll() {
            for browser in CefRuntime.shared.browsers { browser.close(force: true) }
        }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }

    /// The app's views over Chrome's tab strip and toolbar.
    private static func hostChecks(_ window: CefChromeWindow) async {
        guard let nsWindow = window.window, let content = nsWindow.contentView else {
            return check("chrome window: has its NSWindow", false)
        }
        window.showsChromeUI = false
        window.setTopBar {
            HStack {
                Text("App tabs").accessibilityIdentifier("selftest-top-bar")
                TextField("Address", text: .constant("")).accessibilityIdentifier("selftest-address")
            }
            .padding(.leading, 80)
        }
        _ = await waitUntil(timeout: .seconds(2)) { window.topBarHeight > 0 }
        let page = content.subviews.last { "\(type(of: $0))" == "WebContentsViewCocoa" && !$0.isHidden }
        let pageTop = page.map { content.isFlipped ? $0.frame.minY : content.bounds.height - $0.frame.maxY } ?? -1
        check("chrome window: the top bar covers Chrome's strip and toolbar, down to the page",
              window.topBarHeight > 40 && abs(window.topBarHeight - pageTop) < 1 && window.contentFrame.minY == window.topBarHeight
                && window.topBar?.superview != nil,
              detail: "top \(window.topBarHeight), page top \(pageTop), content \(window.contentFrame)")

        // Clicks at the strip reach the app's view; the page still takes its own.
        if let frameView = content.superview {
            let stripPoint = content.convert(CGPoint(x: content.bounds.midX, y: content.isFlipped ? 20 : content.bounds.height - 20), to: frameView)
            let hit = frameView.hitTest(stripPoint)
            let pagePoint = content.convert(CGPoint(x: content.bounds.midX, y: content.bounds.midY), to: frameView)
            let pageHit = frameView.hitTest(pagePoint)
            check("chrome window: clicks on Chrome's strip reach the app's views; the page takes its own",
                  hit.map { $0.isDescendant(of: window.topBar ?? NSView()) || "\(type(of: $0))".contains("Cover") } == true
                    && pageHit.map { "\(type(of: $0))".contains("RenderWidgetHostViewCocoa") || $0.isDescendant(of: content) } == true,
                  detail: "\(hit.map { "\(type(of: $0))" } ?? "-") / \(pageHit.map { "\(type(of: $0))" } ?? "-")")
        }

        // Accessibility sees the app's views and not Chrome's.
        func roles(_ element: AnyObject, depth: Int = 0) -> [String] {
            guard depth < 14 else { return [] }
            let role = (element.accessibilityRole?() ?? nil)?.rawValue ?? ""
            let identifier = (element.accessibilityIdentifier?() ?? nil) ?? ""
            if role == "AXWebArea" { return [role] }
            let children = (element.accessibilityChildren?() ?? nil) ?? []
            return [role + (identifier.isEmpty ? "" : "#" + identifier)] + children.flatMap { roles($0 as AnyObject, depth: depth + 1) }
        }
        let tree = roles(nsWindow)
        let windowChildren = (nsWindow.accessibilityChildren() ?? []).map { $0 as AnyObject }
        if ProcessInfo.processInfo.environment["SELFTEST_TABS_DUMP"] != nil {
            let frameView = content.superview
            print("NOTE ax window children \((nsWindow.accessibilityChildren() ?? []).map { "\(type(of: $0))" })")
            print("NOTE ax frame view children \((frameView?.accessibilityChildren() ?? []).map { "\(type(of: $0))" }) ignored \(frameView?.isAccessibilityElement() ?? false)")
            print("NOTE ax content children \((content.accessibilityChildren() ?? []).map { "\(type(of: $0))" }) is element \(content.isAccessibilityElement())")
            print("NOTE ax content tree \(roles(content).filter { $0 != "AXGroup" }.prefix(40))")
            func chain(_ element: AnyObject, depth: Int) {
                guard depth < 9 else { return }
                let children = (element.accessibilityChildren?() ?? nil) ?? []
                let role = (element.accessibilityRole?() ?? nil)?.rawValue ?? "-"
                let frame = element.accessibilityFrame?() ?? .zero
                print("NOTE ax chain \(String(repeating: " ", count: depth))\(type(of: element)) \(role) \(NSStringFromRect(frame)) children \(children.count)")
                for child in children { chain(child as AnyObject, depth: depth + 1) }
            }
            chain(content, depth: 0)
            if let top = window.topBar { chain(top, depth: 0) }
            print("NOTE ax focused \(String(describing: content.accessibilityFocusedUIElement)) window focused \(String(describing: nsWindow.accessibilityFocusedUIElement))")
        }
        check("chrome window: Chrome's covered tab strip and toolbar leave the accessibility tree; the app's views are in it",
              !tree.contains("AXTabGroup") && !tree.contains("AXToolbar") && windowChildren.contains { $0 === window.topBar },
              detail: "\(tree.filter { $0 != "AXGroup" }.prefix(30))")

        // Keyboard focus sent to Chrome's covered omnibox moves to the app's views.
        NSApp.activate()
        nsWindow.makeKeyAndOrderFront(nil)
        window.activeTab?.browser?.execute(.focusLocation)
        let moved = await waitUntil(timeout: .seconds(3)) {
            (nsWindow.firstResponder as? NSView).map { $0.isDescendant(of: window.topBar ?? NSView()) } == true
        }
        check("chrome window: keyboard focus that reaches Chrome's covered controls moves to the app's views",
              moved, detail: "first responder \(nsWindow.firstResponder.map { "\(type(of: $0))" } ?? "-"), focused \(String(describing: content.accessibilityFocusedUIElement))")

        // The page frame follows the window.
        let width = window.contentFrame.width
        var frame = nsWindow.frame
        frame.size.width -= 120
        nsWindow.setFrame(frame, display: true)
        check("chrome window: the page frame follows a resize",
              await waitUntil(timeout: .seconds(3)) { abs(window.contentFrame.width - (width - 120)) < 2 },
              detail: "\(width) -> \(window.contentFrame.width)")

        // Tabs at the side: Chrome's vertical tab strip, covered by the sidebar.
        window.setSidebar { Text("Sidebar").accessibilityIdentifier("selftest-sidebar") }
        window.strip.layout = .vertical(width: 220)
        let vertical = await waitUntil(timeout: .seconds(5)) { window.sidebarWidth > 100 }
        check("chrome window: with tabs at the side, the sidebar covers Chrome's vertical tab strip",
              vertical && window.contentFrame.minX == window.sidebarWidth,
              detail: "sidebar \(window.sidebarWidth), content \(window.contentFrame), top \(window.topBarHeight)")
        window.strip.layout = .horizontal
        _ = await waitUntil(timeout: .seconds(5)) { window.sidebarWidth == 0 }
    }
}
