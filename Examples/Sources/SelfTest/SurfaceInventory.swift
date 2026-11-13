import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import CCef

/// An inventory of the interface Chromium shows of its own over a Chrome-style
/// window: `SELFTEST_SURFACE_DUMP=<folder>` runs the `surfaceInventory`
/// probe instead of the nativeUI group's checks. The probe triggers each
/// surface (a Chrome command, a page call with a user gesture, a click),
/// records every window that appears and every delegate call CefKit makes
/// instead, and writes `inventory.md` to the folder.
///
/// Nothing it triggers reaches a macOS prompt: media requests use fake
/// devices and are denied by the delegate, Cast stays off (discovery would
/// ask for local network access), Bluetooth, HID, screen capture and passkeys
/// are not triggered.
extension SelfTest {
    static let surfaceDumpEnvironmentKey = "SELFTEST_SURFACE_DUMP"

    static let surfaceStartEnvironmentKey = "SELFTEST_SURFACE_START"

    /// Runs the probe until it has gone through every trigger: a trigger
    /// that ends the browser process is recorded as such, and the probe
    /// starts again after it.
    static func runSurfaceInventory(to folder: String) async {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let marker = folder + "/current"
        var start = "0:0"
        for _ in 0..<20 {
            try? FileManager.default.removeItem(atPath: marker)
            await runProbe(
                "surfaceInventory", label: "surface inventory",
                environment: [surfaceDumpEnvironmentKey: folder, surfaceStartEnvironmentKey: start], timeout: .seconds(1100))
            guard let current = try? String(contentsOfFile: marker, encoding: .utf8) else { break }
            // "toolbar:index:name" of the trigger that was running.
            let parts = current.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let toolbar = Int(parts[0]), let index = Int(parts[1]) else { break }
            let hung = FileManager.default.fileExists(atPath: marker + "-hang")
            try? FileManager.default.removeItem(atPath: marker + "-hang")
            appendSurfaceRow(
                "| \(parts[2]) | | **\(hung ? "blocks the main thread for over a minute" : "ends the browser process")** |\n",
                toolbar: toolbar, folder: folder)
            start = "\(toolbar):\(index + 1)"
        }
        var report = (try? String(contentsOfFile: folder + "/header.md", encoding: .utf8)) ?? ""
        for (index, toolbar) in ["none", "chrome"].enumerated() {
            report += "## Toolbar `.\(toolbar)`\n\n| Trigger | How | Appeared |\n|---|---|---|\n"
            report += (try? String(contentsOfFile: folder + "/rows-\(index).md", encoding: .utf8)) ?? ""
            report += "\n"
        }
        try? report.write(toFile: folder + "/inventory.md", atomically: true, encoding: .utf8)
        print("NOTE surface inventory: \(folder)/inventory.md")
    }

    static func appendSurfaceRow(_ row: String, toolbar: Int, folder: String) {
        let path = folder + "/rows-\(toolbar).md"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(row.utf8))
            try? handle.close()
        } else {
            try? row.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func configureSurfaceInventoryProbe(_ configuration: inout CefRuntime.Configuration) {
        configuration.authenticationPrompt = .chromium
        configuration.services.translation = .automatic
        configuration.credentials.passwordSaving = .automatic
        configuration.credentials.autofill = .automatic
        configuration.safeStorage = .mockKeychain
        configuration.extraCommandLineSwitches["use-fake-device-for-media-stream"] = .some(nil)
        configuration.extraCommandLineSwitches["enable-automation"] = .some(nil)
    }

    /// A page with something to click for each surface a page opens.
    nonisolated static let surfaceInventoryPage = """
        <!doctype html><html lang="en"><title>surfaces</title>
        <style>body{font:16px system-ui} input,select,button,video{display:block;margin:6px}</style>
        <p>Surfaces: a page on http, which counts as secure on 127.0.0.1. <a id=link href=/page title="A tooltip">A link</a></p>
        <input id=file type=file><input id=color type=color><input id=date type=date>
        <select id=select><option>One</option><option>Two</option></select>
        <form id=login action=/page method=post><input id=user name=username autocomplete=username>
        <input id=pass name=password type=password autocomplete=current-password><button id=submit>Sign in</button></form>
        <form id=address action=/page method=post><input name=name autocomplete=name><input name=street autocomplete=street-address>
        <input name=city autocomplete=address-level2><input name=zip autocomplete=postal-code><input name=email autocomplete=email></form>
        <canvas id=canvas width=160 height=90></canvas><video id=video width=160 height=90 muted autoplay></video>
        <a id=download1 href=/one.txt download>one</a><a id=download2 href=/two.txt download>two</a>
        <a id=external href="cefswift-selftest-unhandled:hello">external</a>
        <script>
        const c = document.getElementById('canvas'), g = c.getContext('2d');
        setInterval(() => { g.fillStyle = '#' + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0'); g.fillRect(0, 0, 160, 90) }, 200);
        document.getElementById('video').srcObject = c.captureStream(5);
        </script>
        """

    /// The French page translate offers to translate.
    nonisolated static let surfaceInventoryFrenchPage = """
        <!doctype html><html lang="fr"><title>bonjour</title><p>Bonjour tout le monde. Ceci est une page écrite en français,
        avec assez de texte pour que la détection de la langue la reconnaisse comme telle. Le chat dort sur le canapé
        pendant que la pluie tombe doucement sur les toits de la ville.</p></html>
        """

    static func surfaceInventoryProbe() async {
        guard let folder = ProcessInfo.processInfo.environment[surfaceDumpEnvironmentKey] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard let server = try? await LocalServer.start() else {
            check("surface inventory: local server starts", false)
            return
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.port)/")!
        CefChromiumTesting.activate()
        // A trigger that blocks the main thread (a modal loop) for a minute
        // is recorded as hanging, and the probe ends.
        let marker = folder + "/current"
        Thread.detachNewThread {
            var last = "", since = Date()
            while true {
                Thread.sleep(forTimeInterval: 5)
                let current = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
                if current != last { (last, since) = (current, Date()) }
                if !current.isEmpty, Date().timeIntervalSince(since) > 60 {
                    try? "hang".write(toFile: marker + "-hang", atomically: true, encoding: .utf8)
                    exit(7)
                }
            }
        }
        let inventory = SurfaceInventory(base: base)
        let start = (ProcessInfo.processInfo.environment[surfaceStartEnvironmentKey] ?? "0:0").split(separator: ":").compactMap { Int($0) }
        let (startToolbar, startIndex) = (start.first ?? 0, start.count > 1 ? start[1] : 0)
        if startToolbar == 0, startIndex == 0 {
            let header = "# Chromium surfaces in a CEF Chrome-style window\n\n"
                + "CEF \(cef_version_info(0)).\(cef_version_info(1)).\(cef_version_info(2)) (Chromium \(cef_version_info(4))). "
                + "Each row: what was triggered, then each window that appeared (class, size, parent, title, Views classes, "
                + "CefChromium's kind), the native menus that opened, the delegate calls CefKit made instead, and the "
                + "surfaces `CefWindow.onChromiumSurface` announced. `kind` is what `CefChromiumSurface.Kind` recognizes; "
                + "`—` means not a surface window.\n\n"
            try? header.write(toFile: folder + "/header.md", atomically: true, encoding: .utf8)
        }
        for (toolbarIndex, toolbar) in [CefWindow.Toolbar.none, .chrome].enumerated() where toolbarIndex >= startToolbar {
            print("NOTE surface inventory: toolbar \(toolbar)")
            guard let host = await inventory.open(toolbar: toolbar) else {
                check("surface inventory: window with toolbar \(toolbar) loads", false)
                continue
            }
            for (index, trigger) in inventory.triggers(toolbar: toolbar).enumerated()
            where toolbarIndex > startToolbar || index >= startIndex {
                print("NOTE surface inventory: \(trigger.name)")
                try? "\(toolbarIndex):\(index):\(trigger.name)".write(toFile: folder + "/current", atomically: true, encoding: .utf8)
                let result = await inventory.run(trigger, in: host)
                appendSurfaceRow("| \(trigger.name) | \(trigger.how) | \(result) |\n", toolbar: toolbarIndex, folder: folder)
            }
            await inventory.close(host)
        }
        try? FileManager.default.removeItem(atPath: folder + "/current")
        check("surface inventory: every trigger ran", true)
    }
}

/// Records the delegate calls a trigger causes, answering each with a refusal.
@MainActor
final class SurfaceInventoryDelegate: CefBrowserDelegate {
    var calls: [String] = []

    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        calls.append("decidePermissionFor \(request.kinds)")
        return .deny
    }

    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        calls.append("runJavaScriptDialog \(dialog.kind)")
        return .dismiss
    }

    func browser(_ browser: CefBrowser, confirmLeavingPage isReload: Bool) async -> Bool {
        calls.append("confirmLeavingPage")
        return true
    }

    func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]? {
        calls.append("runFileDialog \(dialog.mode)")
        return nil
    }

    func browser(_ browser: CefBrowser, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
        calls.append("decideDestinationFor download")
        return .save(to: FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-inventory-\(UUID().uuidString).txt"))
    }

    func browserPageIsUnresponsive(_ browser: CefBrowser) async -> CefUnresponsivePageDecision {
        calls.append("browserPageIsUnresponsive")
        return .reload
    }

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenDecision {
        calls.append("decideWindowOpenFor \(request.disposition)")
        return .deny
    }

    func browser(_ browser: CefBrowser, runContextMenu menu: CefContextMenu, for target: CefContextMenuTarget) async -> CefContextMenu.Item? {
        calls.append("runContextMenu")
        return nil
    }
}

@MainActor
final class SurfaceInventory {
    struct Host {
        let window: CefWindow
        let browser: CefBrowser
        let delegate: SurfaceInventoryDelegate
    }

    struct Trigger {
        let name: String
        let how: String
        var wait: Duration = .milliseconds(1500)
        let run: @MainActor (Host) async -> Void
    }

    let base: URL
    private var menuObserver: NSObjectProtocol?
    private var menusOpened: [String] = []

    init(base: URL) {
        self.base = base
        // Native menus (`<select>`, Chrome's app menu) run a tracking loop
        // until closed: note and close each.
        // The tracking loop runs in a mode of its own: cancel from there.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
                self?.menusOpened.append("NSMenu \(menu.items.prefix(4).map(\.title))")
                nonisolated(unsafe) let tracked = menu
                let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
                    MainActor.assumeIsolated { tracked.cancelTrackingWithoutAnimation() }
                }
                for mode in [RunLoop.Mode.common, .eventTracking, .modalPanel, .default] {
                    RunLoop.main.add(timer, forMode: mode)
                }
            }
        }
    }

    func open(toolbar: CefWindow.Toolbar) async -> Host? {
        let delegate = SurfaceInventoryDelegate()
        let browser = CefBrowser(url: base.appendingPathComponent("surfaces"))
        browser.delegate = delegate
        var configuration = CefWindow.Configuration()
        configuration.toolbar = toolbar
        configuration.frame = CGRect(x: 140, y: 120, width: 1000, height: 720)
        let window = CefWindow(browser: browser, configuration: configuration)
        // Every surface native, so that each is followed and listed.
        window.chromiumSurfacePolicy = CefChromiumSurface.Policy()
        window.show()
        guard await SelfTest.loaded(browser, title: "surfaces") else { return nil }
        window.window?.orderFrontRegardless()
        return Host(window: window, browser: browser, delegate: delegate)
    }

    func close(_ host: Host) async {
        host.window.close()
        _ = await SelfTest.waitUntil { host.window.isClosed }
    }

    // MARK: Running a trigger

    func run(_ trigger: Trigger, in host: Host) async -> String {
        guard let nsWindow = host.window.window else { return "no window" }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let childrenBefore = Set((nsWindow.childWindows ?? []).map(ObjectIdentifier.init))
        host.delegate.calls = []
        menusOpened = []
        var announced: [String] = []
        host.window.onChromiumSurface = { announced.append("\($0.kind) (\($0.presentation))") }
        var seen: [ObjectIdentifier: String] = [:]
        var order: [ObjectIdentifier] = []
        await trigger.run(host)
        let deadline = ContinuousClock.now + trigger.wait
        repeat {
            for (window, parent) in Self.windows(of: nsWindow) + NSApp.windows.filter({ $0.parent == nil }).map({ ($0, nil) }) {
                let id = ObjectIdentifier(window)
                let isNew = !before.contains(id) || (parent != nil && !childrenBefore.contains(id))
                // TUINSWindow is macOS's text input window.
                guard isNew, window.isVisible, window !== nsWindow,
                      NSStringFromClass(type(of: window)) != "TUINSWindow" else { continue }
                // Describe as late as possible: Chromium builds the view tree after attaching.
                if seen[id] == nil { order.append(id) }
                seen[id] = describe(window, parent: parent, host: host)
            }
            try? await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        var parts = order.compactMap { seen[$0] }
        parts += menusOpened
        parts += host.delegate.calls.map { "delegate: \($0)" }
        if !announced.isEmpty { parts.append("announced: \(announced.joined(separator: ", "))") }
        host.window.onChromiumSurface = nil
        await cleanUp(host, before: before)
        return parts.isEmpty ? "nothing" : parts.joined(separator: "<br>")
    }

    /// `window`'s child windows, and theirs, with their parent.
    static func windows(of window: NSWindow) -> [(NSWindow, NSWindow?)] {
        (window.childWindows ?? []).flatMap { [($0, window)] + windows(of: $0) }
    }

    private func describe(_ window: NSWindow, parent: NSWindow?, host: Host) -> String {
        let description = CefChromiumTesting.describe(window)
        let root = window.contentView?.accessibilityChildren()?.first as? NSObject
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        let role = root.flatMap { root in
            root.responds(to: selector) ? root.perform(selector, with: "AXRole")?.takeUnretainedValue() as? String : nil
        } ?? "-"
        let frameClasses: Set<String> = [
            "RootView", "NonClientView", "BubbleFrameView", "ClientView", "DialogClientView", "View", "BoxLayoutView",
            "FlexLayoutView", "TableLayoutView", "Label", "ImageView", "ImageButton", "LabelButton", "MdTextButton",
            "Textfield", "ScrollView", "ScrollView::Viewport", "Separator", "DialogClientView::ButtonRowContainer",
        ]
        var classes: [String] = []
        for name in description.classes where !frameClasses.contains(name) && !classes.contains(name) { classes.append(name) }
        let kind = description.isSurface ? (description.kind.map { "`\($0)`" } ?? "nil (no view tree)") : "—"
        let size = "\(Int(window.frame.width))×\(Int(window.frame.height))"
        let relation = parent.map { "child of \(NSStringFromClass(type(of: $0)))" } ?? "top-level, level \(window.level.rawValue)"
        let title = (window.title.isEmpty ? description.title : window.title)
            .replacingOccurrences(of: "|", with: "/").split(whereSeparator: \.isNewline).joined(separator: " ")
        let alpha = window.alphaValue < 1 ? ", alpha \(window.alphaValue)" : ""
        return "\(NSStringFromClass(type(of: window))) \(size)\(alpha), \(relation); title \"\(title)\"; AX \(role); "
            + "views \(classes.prefix(6).joined(separator: ", ")); kind \(kind)"
    }

    /// Closes what the trigger left open and brings the page back.
    private func cleanUp(_ host: Host, before: Set<ObjectIdentifier>) async {
        for surface in host.window.chromiumSurfaces { surface.dismiss() }
        host.browser.execute(CefChromeCommand(rawValue: Int(IDC_CLOSE_FIND_OR_STOP)))
        if host.browser.isFullscreen {
            host.browser.execute(CefChromeCommand(rawValue: Int(IDC_FULLSCREEN)))
            _ = await SelfTest.waitUntil(timeout: .seconds(5)) { !host.browser.isFullscreen }
            try? await Task.sleep(for: .seconds(1))
        }
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        guard let nsWindow = host.window.window else { return }
        for (child, _) in Self.windows(of: nsWindow) where child.isVisible {
            Self.sendEscape(to: child)
        }
        try? await Task.sleep(for: .milliseconds(400))
        for window in NSApp.windows where !before.contains(ObjectIdentifier(window)) && window.isVisible && window !== nsWindow {
            if window.parent == nil { window.performClose(nil) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        for window in NSApp.windows where !before.contains(ObjectIdentifier(window)) && window.isVisible && window !== nsWindow
            && window.parent == nil {
            window.close()
        }
        // Back to the page, with the dialogs it left answered.
        if host.browser.url?.lastPathComponent != "surfaces" || host.browser.isLoading {
            _ = host.browser.load(base.appendingPathComponent("surfaces"))
        } else {
            host.browser.reload()
        }
        _ = await SelfTest.loaded(host.browser, title: "surfaces", timeout: .seconds(10))
        nsWindow.makeKeyAndOrderFront(nil)
    }

    static func sendEscape(to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53) {
                window.sendEvent(event)
            }
        }
    }

    // MARK: Triggers

    static func command(_ id: Int32) -> @MainActor (Host) async -> Void {
        { $0.browser.execute(CefChromeCommand(rawValue: Int(id))) }
    }

    /// Runs `script` in the page as a user gesture would.
    static func gesture(_ script: String) -> @MainActor (Host) async -> Void {
        { host in
            _ = try? await host.browser.devTools.send(
                "Runtime.evaluate", ["expression": .string(script), "userGesture": true, "awaitPromise": false])
        }
    }

    /// Clicks the element `id` with the pointer, through the DevTools protocol.
    static func click(_ id: String) -> @MainActor (Host) async -> Void {
        { host in
            let point = try? await host.browser.evaluateJavaScript(
                "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + 8, r.y + r.height / 2]; })()")
            let x = CefJSON.number(point?[0].doubleValue ?? 0), y = CefJSON.number(point?[1].doubleValue ?? 0)
            for type in ["mousePressed", "mouseReleased"] {
                _ = try? await host.browser.devTools.send(
                    "Input.dispatchMouseEvent", ["type": .string(type), "x": x, "y": y, "button": "left", "clickCount": 1])
            }
        }
    }

    static func load(_ path: String) -> @MainActor (Host) async -> Void {
        { host in
            guard let url = URL(string: path, relativeTo: host.browser.url) else { return }
            _ = host.browser.load(url)
        }
    }

    func triggers(toolbar: CefWindow.Toolbar) -> [Trigger] {
        typealias T = Trigger
        let toolbarOnly: [Trigger] = [
            T(name: "App menu", how: "`IDC_SHOW_APP_MENU`", run: Self.command(IDC_SHOW_APP_MENU)),
            T(name: "Avatar menu", how: "`IDC_SHOW_AVATAR_MENU`", run: Self.command(IDC_SHOW_AVATAR_MENU)),
            T(name: "Omnibox popup", how: "`IDC_FOCUS_SEARCH`", run: Self.command(IDC_FOCUS_SEARCH)),
            T(name: "Page info (lock icon)", how: "AXPress on the location icon", run: { host in
                guard let window = host.window.window else { return }
                Self.press(in: window) { element in
                    let text = [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityHelp()]
                        .compactMap { $0 }.joined(separator: " ").lowercased()
                    return element.accessibilityRole() == .button && (text.contains("site information") || text.contains("site info"))
                }
            }),
            T(name: "Extensions menu", how: "`IDC_EXTENSIONS_SUBMENU_MANAGE_EXTENSIONS`",
              run: Self.command(IDC_EXTENSIONS_SUBMENU_MANAGE_EXTENSIONS)),
            T(name: "Tab search", how: "`IDC_TAB_SEARCH`", run: Self.command(IDC_TAB_SEARCH)),
            T(name: "Bookmarks side panel", how: "`IDC_SHOW_BOOKMARK_SIDE_PANEL`", run: Self.command(IDC_SHOW_BOOKMARK_SIDE_PANEL)),
            T(name: "Reading list side panel", how: "`IDC_READING_LIST_MENU_SHOW_UI`", run: Self.command(IDC_READING_LIST_MENU_SHOW_UI)),
            T(name: "History side panel", how: "`IDC_SHOW_HISTORY_SIDE_PANEL`", run: Self.command(IDC_SHOW_HISTORY_SIDE_PANEL)),
            T(name: "Reading mode side panel", how: "`IDC_SHOW_READING_MODE_SIDE_PANEL`",
              run: Self.command(IDC_SHOW_READING_MODE_SIDE_PANEL)),
            T(name: "New tab group", how: "`IDC_CREATE_NEW_TAB_GROUP`", run: Self.command(IDC_CREATE_NEW_TAB_GROUP)),
        ]
        let common: [Trigger] = [
            T(name: "Find bar", how: "`IDC_FIND`", run: Self.command(IDC_FIND)),
            T(name: "Status bubble", how: "pointer over a link", wait: .milliseconds(2000), run: { host in
                _ = try? await host.browser.devTools.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 1, "y": 1])
                let point = try? await host.browser.evaluateJavaScript(
                    "(() => { const r = document.getElementById('link').getBoundingClientRect(); return [r.x + 4, r.y + 4]; })()")
                _ = try? await host.browser.devTools.send("Input.dispatchMouseEvent", [
                    "type": "mouseMoved", "x": .number(point?[0].doubleValue ?? 0), "y": .number(point?[1].doubleValue ?? 0),
                ])
            }),
            T(name: "Tooltip", how: "pointer resting on an element with `title`", wait: .milliseconds(3000), run: { host in
                let point = try? await host.browser.evaluateJavaScript(
                    "(() => { const r = document.getElementById('link').getBoundingClientRect(); return [r.x + 6, r.y + 6]; })()")
                _ = try? await host.browser.devTools.send("Input.dispatchMouseEvent", [
                    "type": "mouseMoved", "x": .number(point?[0].doubleValue ?? 0), "y": .number(point?[1].doubleValue ?? 0),
                ])
            }),
            T(name: "Zoom bubble", how: "`IDC_ZOOM_PLUS`", run: { host in
                host.browser.execute(CefChromeCommand(rawValue: Int(IDC_ZOOM_PLUS)))
            }),
            T(name: "Zoom reset", how: "`IDC_ZOOM_NORMAL`", run: Self.command(IDC_ZOOM_NORMAL)),
            T(name: "QR code", how: "`IDC_QRCODE_GENERATOR`", run: Self.command(IDC_QRCODE_GENERATOR)),
            T(name: "Sharing hub", how: "`IDC_SHARING_HUB`", run: Self.command(IDC_SHARING_HUB)),
            T(name: "Send tab to self", how: "`IDC_SEND_TAB_TO_SELF`", run: Self.command(IDC_SEND_TAB_TO_SELF)),
            T(name: "Bookmark this tab", how: "`IDC_BOOKMARK_THIS_TAB` (⌘D)", run: Self.command(IDC_BOOKMARK_THIS_TAB)),
            T(name: "Translate", how: "French page, then `IDC_SHOW_TRANSLATE`", wait: .milliseconds(3000), run: { host in
                _ = host.browser.load(host.browser.url!.deletingLastPathComponent().appendingPathComponent("french"))
                _ = await SelfTest.loaded(host.browser, timeout: .seconds(5))
                try? await Task.sleep(for: .milliseconds(1500))
                host.browser.execute(CefChromeCommand(rawValue: Int(IDC_SHOW_TRANSLATE)))
            }),
            T(name: "Manage passwords", how: "`IDC_MANAGE_PASSWORDS_FOR_PAGE`", run: Self.command(IDC_MANAGE_PASSWORDS_FOR_PAGE)),
            T(name: "Save password", how: "fill and submit a sign-in form", wait: .milliseconds(3000),
              run: Self.gesture("document.getElementById('user').value = 'ada'; document.getElementById('pass').value = 'lovelace-1843!';"
                                + "document.getElementById('login').requestSubmit()")),
            T(name: "Save address", how: "fill and submit an address form", wait: .milliseconds(3000),
              run: Self.gesture("""
                  const f = document.getElementById('address'); f.name.value = 'Ada Lovelace'; f.street.value = '12 St James Square';
                  f.city.value = 'London'; f.zip.value = 'SW1Y 4JH'; f.email.value = 'ada@example.com'; f.requestSubmit()
                  """)),
            T(name: "Autofill dropdown", how: "click a field with `autocomplete=email`", run: { host in
                await Self.gesture("document.querySelector('[autocomplete=email]').focus()")(host)
                _ = try? await host.browser.devTools.send("Input.insertText", ["text": "a"])
            }),
            T(name: "Download", how: "click a `download` link", wait: .milliseconds(2500), run: Self.click("download1")),
            T(name: "Multiple downloads", how: "two downloads from one gesture", wait: .milliseconds(2500),
              run: Self.gesture("document.getElementById('download1').click(); setTimeout(() => document.getElementById('download2').click(), 300)")),
            T(name: "Show downloads", how: "`IDC_SHOW_DOWNLOADS`", run: Self.command(IDC_SHOW_DOWNLOADS)),
            T(name: "Camera", how: "`getUserMedia({video})`, fake device", run: Self.gesture("navigator.mediaDevices.getUserMedia({video: true}).catch(() => {})")),
            T(name: "Microphone", how: "`getUserMedia({audio})`, fake device", run: Self.gesture("navigator.mediaDevices.getUserMedia({audio: true}).catch(() => {})")),
            T(name: "Location", how: "`geolocation.getCurrentPosition`", run: Self.gesture("navigator.geolocation.getCurrentPosition(() => {}, () => {})")),
            T(name: "Notifications", how: "`Notification.requestPermission()`", run: Self.gesture("Notification.requestPermission()")),
            T(name: "Clipboard read", how: "`clipboard.readText()`", run: Self.gesture("navigator.clipboard.readText().catch(() => {})")),
            T(name: "MIDI", how: "`requestMIDIAccess({sysex})`", run: Self.gesture("navigator.requestMIDIAccess({sysex: true}).catch(() => {})")),
            T(name: "Window management", how: "`getScreenDetails()`", run: Self.gesture("window.getScreenDetails().catch(() => {})")),
            T(name: "Storage access", how: "`requestStorageAccess()`", run: Self.gesture("document.requestStorageAccess().catch(() => {})")),
            T(name: "Protocol handler", how: "`registerProtocolHandler('web+cefswift', …)`",
              run: Self.gesture("navigator.registerProtocolHandler('web+cefswift', '/page?%s')")),
            T(name: "Popup without gesture", how: "`window.open` from a timer", run: { host in
                _ = try? await host.browser.evaluateJavaScript("setTimeout(() => window.open('/page'), 10); 0")
            }),
            T(name: "Screen share", how: "`getDisplayMedia()` (denied by the delegate)",
              run: Self.gesture("navigator.mediaDevices.getDisplayMedia({video: true}).catch(() => {})")),
            T(name: "USB chooser", how: "`usb.requestDevice({filters: []})`", run: Self.gesture("navigator.usb.requestDevice({filters: []}).catch(() => {})")),
            T(name: "Serial chooser", how: "`serial.requestPort()`", run: Self.gesture("navigator.serial.requestPort().catch(() => {})")),
            T(name: "Payment request", how: "`new PaymentRequest(…).show()`", run: Self.gesture("""
                new PaymentRequest([{supportedMethods: 'https://127.0.0.1/pay'}], {total: {label: 'T', amount: {currency: 'USD', value: '1'}}}).show().catch(() => {})
                """)),
            T(name: "HTTP authentication", how: "load a page answering 401", wait: .milliseconds(2500), run: Self.load("/private")),
            T(name: "alert()", how: "`alert()`", run: Self.gesture("setTimeout(() => alert('hello'), 0)")),
            T(name: "confirm()", how: "`confirm()`", run: Self.gesture("setTimeout(() => confirm('sure?'), 0)")),
            T(name: "prompt()", how: "`prompt()`", run: Self.gesture("setTimeout(() => prompt('name?', 'ada'), 0)")),
            T(name: "beforeunload", how: "a `beforeunload` handler, then reload", wait: .milliseconds(2500), run: { host in
                await Self.gesture("window.onbeforeunload = e => { e.preventDefault(); return 'x' }; document.body.click()")(host)
                await Self.click("link")(host)
                try? await Task.sleep(for: .milliseconds(500))
            }),
            T(name: "File chooser", how: "click `<input type=file>`", run: Self.click("file")),
            T(name: "Colour picker", how: "click `<input type=color>`", run: Self.click("color")),
            T(name: "Date picker", how: "click `<input type=date>`", run: Self.click("date")),
            T(name: "`<select>` popup", how: "click `<select>`", run: Self.click("select")),
            T(name: "Picture in picture", how: "`video.requestPictureInPicture()`", wait: .milliseconds(2500),
              run: Self.gesture("document.getElementById('video').play().then(() => document.getElementById('video').requestPictureInPicture()).catch(e => console.log(e))")),
            T(name: "Fullscreen", how: "`requestFullscreen()`", wait: .milliseconds(3000),
              run: Self.gesture("document.documentElement.requestFullscreen().catch(() => {})")),
            T(name: "Keyboard lock in fullscreen", how: "`requestFullscreen()` then `keyboard.lock()`", wait: .milliseconds(3000),
              run: Self.gesture("document.documentElement.requestFullscreen().then(() => navigator.keyboard.lock()).catch(() => {})")),
            T(name: "Browser fullscreen", how: "`IDC_FULLSCREEN`", wait: .milliseconds(3000), run: Self.command(IDC_FULLSCREEN)),
            T(name: "External protocol", how: "click a link to an unhandled scheme", run: Self.click("external")),
            T(name: "Print preview", how: "`IDC_PRINT`", wait: .milliseconds(3000), run: Self.command(IDC_PRINT)),
            T(name: "Task manager", how: "`IDC_TASK_MANAGER`", run: Self.command(IDC_TASK_MANAGER)),
            T(name: "DevTools", how: "`IDC_DEV_TOOLS`", wait: .milliseconds(2500), run: Self.command(IDC_DEV_TOOLS)),
            T(name: "Clear browsing data", how: "`IDC_CLEAR_BROWSING_DATA`", run: Self.command(IDC_CLEAR_BROWSING_DATA)),
            T(name: "Save page", how: "`IDC_SAVE_PAGE`", run: Self.command(IDC_SAVE_PAGE)),
            T(name: "Crashed tab", how: "load `chrome://crash`", wait: .milliseconds(2500), run: Self.load("chrome://crash")),
            T(name: "Context menu", how: "right click (CefKit presents it)", run: { host in
                for type in ["mousePressed", "mouseReleased"] {
                    _ = try? await host.browser.devTools.send(
                        "Input.dispatchMouseEvent", ["type": .string(type), "x": 300, "y": 400, "button": "right", "clickCount": 1])
                }
            }),
        ]
        return toolbar == .none ? common : toolbarOnly + common.filter {
            ["Zoom bubble", "Zoom reset", "Bookmark this tab", "Translate", "Manage passwords", "Save password",
             "Download", "Camera", "Location", "Popup without gesture", "Find bar", "QR code"].contains($0.name)
        }
    }

    /// Presses the first element of `window`'s accessibility tree that matches.
    static func press(in window: NSWindow, matching: (NSAccessibilityProtocol) -> Bool) {
        func search(_ element: NSObject, depth: Int) -> NSAccessibilityProtocol? {
            guard depth < 14, let element = element as? NSAccessibilityProtocol else { return nil }
            if matching(element) { return element }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? NSObject, let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        if let contentView = window.contentView, let found = search(contentView, depth: 0) {
            _ = found.accessibilityPerformPress()
        }
    }
}
