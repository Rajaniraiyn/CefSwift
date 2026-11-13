import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// Favicons, toolbars and zoom, where a bridge is installed, when a
/// profile's hidden service browsers close, and what a second launch does.
extension SelfTest {
    static let relaunchEnvironmentKey = "CEFSWIFT_SELFTEST_RELAUNCH_ROOT"

    // MARK: Favicons

    static func faviconChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://edge/favicon.html")!)
        let window = CefWindow(browser: browser)
        window.show()
        check("favicon: downloaded as an image", await waitUntil { browser.favicon != nil },
              detail: "\(String(describing: browser.faviconURL))")
        if let favicon = browser.favicon {
            let color = favicon.representations.compactMap { $0 as? NSBitmapImageRep }.first?
                .colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
            check("favicon: the page's icon, sized in points",
                  browser.faviconURL?.lastPathComponent == "icon.png" && favicon.size.width <= 32
                      && (color?.redComponent ?? 0) > 0.9 && (color?.greenComponent ?? 1) < 0.3,
                  detail: "\(favicon.size) \(String(describing: color))")
        }
        let history = CefProfile.default.history
        check("favicon: Chromium keeps the icon of a visited page", await waitUntilAsync(timeout: .seconds(15)) {
            (try? await history.favicon(for: URL(string: "selftest://edge/favicon.html")!, size: 32)) != nil
        })
        await expect("favicon: none kept for a page never visited") {
            try await history.favicon(for: URL(string: "https://never-visited.invalid/")!) == nil
        }
        // tab.html declares no icon; its default /favicon.ico is not an image.
        browser.load(URL(string: "selftest://edge/tab.html")!)
        check("favicon: reset when a new page loads", await waitUntil {
            browser.title == "tab" && browser.faviconURL?.lastPathComponent != "icon.png"
        })
        try? await Task.sleep(for: .milliseconds(500))
        check("favicon: none for a page without one", browser.favicon == nil)
        browser.goBack()
        check("favicon: back again shows the icon", await waitUntil { browser.favicon != nil },
              detail: "\(String(describing: browser.faviconURL))")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Toolbar and zoom

    static func toolbarAndZoomChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!)
        let window = CefWindow(browser: browser)
        let renders = RenderLog()
        window.setToolbar { TitleProbe(browser: browser, log: renders) }
        window.setTabAccessory { TitleProbe(browser: browser, log: renders) }
        window.show()
        _ = await loaded(browser, title: "second")
        check("toolbar: installed in the window",
              window.window?.toolbar?.items.count == 5 && window.window?.tab.accessoryView != nil)
        check("toolbar: its views follow the browser's state", await waitUntil { renders.titles.last == "second" },
              detail: "\(renders.titles)")

        let zoom = ZoomObserver(browser)
        browser.zoomLevel = 1
        check("zoom: a level set reads back and is observed",
              await waitUntil { browser.zoomLevel == 1 && zoom.changes == 1 },
              detail: "\(browser.zoomLevel), \(zoom.changes) changes")
        browser.execute(.zoomIn)
        check("zoom: Chrome's zoom commands are observed",
              await waitUntil { browser.zoomLevel > 1 && zoom.changes >= 2 },
              detail: "\(browser.zoomLevel)")
        browser.load(URL(string: "selftest://edge/tab.html")!)
        check("zoom: each site keeps its own level", await waitUntil {
            browser.title == "tab" && !browser.isLoading && browser.zoomLevel == 0
        }, detail: "\(browser.zoomLevel)")
        browser.goBack()
        check("zoom: returning to a site restores its level", await waitUntil {
            browser.title == "second" && browser.zoomLevel > 1
        }, detail: "\(browser.zoomLevel)")
        browser.zoomLevel = 0

        window.close()
        _ = await waitUntil { window.isClosed }
        var ranAfterClose = false
        window.withWindow { _ in ranAfterClose = true }
        check("toolbar: setup after the window closed is ignored", !ranAfterClose)
    }

    // MARK: Bridge scope

    static func bridgeScopeChecks() async {
        let bridge = CefBridge(name: "scoped")
        bridge.access = .origins(["selftest://app"])
        bridge.handle("ping") { (_: CefJSON) in "pong" }
        // Open to every frame: reports the origin the browser process
        // established for the caller.
        let probe = CefBridge(name: "probe")
        probe.access = .anyFrame
        probe.handle("origin") { (_: CefJSON, call: CefBridgeCall) in call.origin }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [bridge, probe]
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        _ = await loaded(browser, title: "second")
        await expect("bridge scope: a permitted origin gets the bridge, not its raw binding") {
            try await browser.evaluateJavaScript(
                "typeof __cefswift_scoped === 'undefined' ? scoped.ping() : 'binding visible'").stringValue == "pong"
        }
        await hostlessFrameChecks(browser, bridge: bridge)
        _ = await load(URL(string: "selftest://edge/tab.html")!, in: browser, title: "tab")
        await expect("bridge scope: other origins have no global at all") {
            try await browser.evaluateJavaScript(
                "typeof scoped === 'undefined' && typeof __cefswift_scoped === 'undefined'").boolValue == true
        }
        bridge.access = .anyFrame
        try? await Task.sleep(for: .milliseconds(200))
        browser.reload()
        await expect("bridge scope: widening access installs it on the next load") {
            await waitUntilAsync {
                (try? await browser.evaluateJavaScript("typeof scoped === 'object' && document.readyState === 'complete'").boolValue) == true
            }
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// `srcdoc`, `about:blank` and `blob:` frames of a permitted page reach
    /// its `.origins` bridge, with the origin the browser process
    /// establishes from their parent or address; an opaque `data:` frame
    /// does not, and its calls carry `"null"`. On an HTTP page;
    /// ``bridgeOriginChecks()`` covers `file:` and custom schemes.
    private static func hostlessFrameChecks(_ browser: CefBrowser, bridge: CefBridge) async {
        guard let server = try? await LocalServer.start() else {
            skip("bridge scope: hostless frames", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"
        let previousAccess = bridge.access
        bridge.access = .origins(["selftest://app", origin])
        defer { bridge.access = previousAccess }
        try? await Task.sleep(for: .milliseconds(200))
        browser.load(URL(string: "\(origin)/page")!)
        guard await waitUntil({ browser.title == "page" && !browser.isLoading }) else {
            check("bridge scope: hostless frames", false, detail: "the HTTP page did not load: \(browser.title)")
            return
        }
        let script = """
            (async () => {
              const make = setup => new Promise(resolve => {
                const frame = document.createElement('iframe');
                frame.onload = () => resolve(frame);
                setup(frame);
                document.body.appendChild(frame);
              });
              const call = async (window, f) => { try { return await f(window); } catch (e) { return 'rejected: ' + e.message; } };
              const frames = {
                srcdoc: await make(f => f.srcdoc = '<p>srcdoc</p>'),
                blank: await make(f => f.src = 'about:blank'),
                blob: await make(f => f.src = URL.createObjectURL(new Blob(['<p>blob</p>'], { type: 'text/html' }))),
              };
              await make(f => f.src = 'data:text/html,<title>data</title>');
              const results = {};
              for (const [name, frame] of Object.entries(frames)) {
                const w = frame.contentWindow;
                results[name] = {
                  scoped: typeof w.scoped === 'object' ? await call(w, w => w.scoped.ping()) : 'missing',
                  origin: await call(w, w => w.probe.origin()),
                  page: w.location.href + ' ' + w.location.origin,
                };
              }
              return results;
            })()
            """
        struct Outcome: Decodable, CustomStringConvertible {
            var scoped: String, origin: String, page: String
            var description: String { "\(scoped), \(origin) (\(page))" }
        }
        let outcomes: [String: Outcome]
        do {
            outcomes = try await browser.evaluateJavaScript(script, as: [String: Outcome].self)
        } catch {
            check("bridge scope: hostless frames", false, detail: "\(error)")
            return
        }
        for name in ["srcdoc", "blank", "blob"] {
            let outcome = outcomes[name]
            check("bridge scope: a \(name) frame of a permitted page calls with its parent's origin",
                  outcome?.scoped == "pong" && outcome?.origin == origin,
                  detail: "\(outcome.map(\.description) ?? "none"); frames \(browser.frames.map { $0.url?.absoluteString ?? "nil" })")
        }
        guard await waitUntil({ browser.frames.contains { $0.url?.scheme == "data" } }),
              let dataFrame = browser.frames.first(where: { $0.url?.scheme == "data" })
        else {
            check("bridge scope: a data: frame has an opaque origin", false, detail: "no data: frame")
            return
        }
        await expect("bridge scope: a data: frame has an opaque origin and no scoped bridge") {
            let result = try await browser.evaluateJavaScript(
                "typeof scoped === 'undefined' ? probe.origin() : 'scoped visible'", in: dataFrame)
            return (result.stringValue == "null", "\(result)")
        }
    }

    // MARK: Bridge origins by scheme

    /// What a document reports about itself and what the bridge makes of it:
    /// `self.origin`, `location.origin`, whether an `.origins` bridge listing
    /// the page's origin is there and answers, and the origin the browser
    /// process establishes (through an `.anyFrame` bridge).
    struct OriginReport: Decodable, Equatable, CustomStringConvertible {
        var selfOrigin: String, locationOrigin: String, scoped: String, established: String
        var description: String { "self \(selfOrigin), location \(locationOrigin), scoped \(scoped), established \(established)" }
    }

    /// A frame's report, posted to its parent as `{ name, r }`.
    static let originReportScript = """
        (async () => ({
          selfOrigin: String(self.origin), locationOrigin: String(location.origin),
          scoped: typeof scoped === 'object' ? await scoped.ping().catch(() => 'rejected') : 'missing',
          established: typeof probe === 'object' ? await probe.origin().catch(() => 'rejected') : 'missing',
        }))()
        """

    /// The reports of a page and of a `srcdoc`, a sandboxed `srcdoc` and a
    /// `data:` frame in it, and of a frame at `subframe` (a page that posts
    /// its report as `subframe`) when given.
    static func originReports(in browser: CefBrowser, subframe: URL? = nil) async throws -> [String: OriginReport] {
        try await browser.evaluateJavaScript("""
            (async () => {
              const report = () => \(originReportScript);
              const child = name => `<script>${report.toString().slice(6)}.then(r => parent.postMessage({ name: '${name}', r }, '*'));<\\/script>`;
              const results = { page: await report() };
              const expected = \(subframe == nil ? 4 : 5);
              const pending = new Promise(resolve => addEventListener('message', e => {
                results[e.data.name] = e.data.r;
                if (Object.keys(results).length === expected) resolve();
              }));
              const add = setup => { const f = document.createElement('iframe'); setup(f); document.body.appendChild(f); };
              add(f => f.srcdoc = child('srcdoc'));
              add(f => { f.sandbox = 'allow-scripts'; f.srcdoc = child('sandboxed'); });
              add(f => f.src = 'data:text/html,' + encodeURIComponent(child('data')));
              \(subframe.map { "add(f => f.src = '\($0.absoluteString)');" } ?? "")
              await Promise.race([pending, new Promise(r => setTimeout(r, 5000))]);
              return results;
            })()
            """, as: [String: OriginReport].self)
    }

    static func bridgeOriginChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-origins-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.html")
        try? Data("<title>file</title><body></body>".utf8).write(to: file)
        let fileFrame = directory.appendingPathComponent("frame.html")
        try? Data("""
            <script>\(originReportScript).then(r => parent.postMessage({ name: 'subframe', r }, '*'));</script>
            """.utf8).write(to: fileFrame)

        let scoped = CefBridge(name: "scoped")
        scoped.access = .origins(["file://", "selftest://app", "selftest-local://app", "null"])
        scoped.handle("ping") { (_: CefJSON) in "pong" }
        let probe = CefBridge(name: "probe")
        probe.access = .anyFrame
        probe.handle("origin") { (_: CefJSON, call: CefBridgeCall) in call.origin }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [scoped, probe]
        let browser = CefBrowser(url: file, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        // The page's origin when it reaches the `.origins` bridge; `nil`
        // when it must not (an opaque origin, even with "null" listed).
        let cases: [(page: URL, label: String, origin: String?)] = [
            (file, "a top-level file: page", "file://"),
            (URL(string: "selftest://app/second.html")!, "a standard custom scheme page", "selftest://app"),
            (URL(string: "selftest-local://app/second.html")!, "a .local custom scheme page", "selftest-local://app"),
            (URL(string: "selftest-plain:/second.html")!, "a non-standard custom scheme page", nil),
        ]
        for (page, label, origin) in cases {
            guard await load(page, in: browser) else {
                check("bridge origins: \(label) loads", false, detail: browser.title)
                continue
            }
            let reports: [String: OriginReport]
            do {
                reports = try await originReports(in: browser, subframe: page.isFileURL ? fileFrame : nil)
            } catch {
                check("bridge origins: \(label) reports", false, detail: "\(error)")
                continue
            }
            let report = reports["page"]
            check("bridge origins: \(label) " + (origin == nil ? "is opaque" : "reaches an .origins bridge as \(origin!)"),
                  origin.map { report?.scoped == "pong" && report?.established == $0 }
                    ?? (report?.scoped != "pong" && report?.established == "null"),
                  detail: report.map(\.description) ?? "no report")
            // srcdoc children of a standard scheme inherit its origin; every
            // other child here is opaque.
            var children = ["sandboxed", "data"]
            if page.scheme == "selftest" {
                check("bridge origins: a srcdoc frame of \(label) inherits its origin",
                      reports["srcdoc"]?.scoped == "pong" && reports["srcdoc"]?.established == origin,
                      detail: reports["srcdoc"].map(\.description) ?? "no report")
            } else {
                children.append("srcdoc")
            }
            if page.isFileURL { children.append("subframe") }
            for name in children {
                let child = reports[name]
                check("bridge origins: a \(name) frame of \(label) is opaque",
                      child != nil && child?.scoped != "pong" && child?.established == "null",
                      detail: child.map(\.description) ?? "no report")
            }
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Bridge serialization

    /// What the renderer does with values whose getters run page code:
    /// detach an `ArrayBuffer` already read, or throw.
    static func bridgeWireChecks() async {
        struct Read: Decodable { var a: Data; var b: Int }
        let wire = CefBridge(name: "wire")
        wire.handle("read") { (value: Read) in "\(value.a.count):\(value.a.allSatisfy { $0 == 7 })" }
        wire.handle("echo") { (value: CefJSON) in value }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [wire]
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, configuration: configuration)
        let window = CefWindow(browser: browser)
        window.show()
        guard await waitUntil({ browser.title == "second" }) else {
            check("bridge wire: page loads", false, detail: browser.title)
            window.close()
            return
        }
        let large = "const big = new ArrayBuffer(4 << 20); new Uint8Array(big).fill(7);"
        await expect("bridge wire: a large ArrayBuffer survives a later getter transferring it") {
            // `transfer` moves the bytes to a new buffer and frees the old
            // memory, which a deferred copy would read after.
            let result = try await browser.evaluateJavaScript("""
                (() => { \(large)
                  return wire.read({ get a() { return big; }, get b() { big.transfer(16); return 1; } }); })()
                """).stringValue
            return (result == "\(4 << 20):true", result ?? "nil")
        }
        await expect("bridge wire: a large ArrayBuffer survives a later getter detaching it by postMessage") {
            let result = try await browser.evaluateJavaScript("""
                (() => { \(large)
                  return wire.read({ get a() { return big; },
                    get b() { new MessageChannel().port1.postMessage(big, [big]); return big.byteLength; } }); })()
                """).stringValue
            return (result == "\(4 << 20):true", result ?? "nil")
        }
        await expect("bridge wire: a large ArrayBuffer read last travels intact") {
            let result = try await browser.evaluateJavaScript("(() => { \(large) return wire.read({ b: 2, a: big }); })()")
                .stringValue
            return (result == "\(4 << 20):true", result ?? "nil")
        }
        await expect("bridge wire: a throwing getter rejects the call") {
            let result = try await browser.evaluateJavaScript("""
                wire.echo({ ok: 1, get bad() { throw new Error('getter boom'); } }).then(() => 'resolved', e => e.message)
                """).stringValue
            return (result?.contains("getter boom") == true, result ?? "nil")
        }
        await expect("bridge wire: a Proxy whose ownKeys trap throws rejects the call") {
            let result = try await browser.evaluateJavaScript("""
                wire.echo(new Proxy({}, { ownKeys() { throw new Error('keys boom'); } })).then(() => 'resolved', e => e.message)
                """).stringValue
            return (result?.contains("keys boom") == true, result ?? "nil")
        }
        await expect("bridge wire: only own enumerable properties travel") {
            let result = try await browser.evaluateJavaScript("""
                wire.echo(Object.create({ inherited: 1 }, { own: { value: 2, enumerable: true }, hidden: { value: 3 } }))
                  .then(v => JSON.stringify(v))
                """).stringValue
            return (result == #"{"own":2}"#, result ?? "nil")
        }
        await expect("bridge wire: a throwing getter fails an evaluation") {
            do {
                _ = try await browser.evaluateJavaScript("({ ok: 1, get bad() { throw new Error('eval boom'); } })")
                return (false, "resolved")
            } catch let error as CefJavaScriptError {
                return (error.message.contains("eval boom"), error.message)
            }
        }
        await expect("bridge wire: the page still works after the failures") {
            try await browser.evaluateJavaScript("wire.echo([1, 'two'])").arrayValue?.count == 2
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Service browsers

    static func serviceLifetimeChecks() async {
        weak var released: CefProfile?
        do {
            let profile = CefProfile.incognito()
            released = profile
            var configuration = CefBrowser.Configuration()
            configuration.profile = profile
            let window = CefWindow(browser: CefBrowser(url: URL(string: "selftest://app/second.html")!, configuration: configuration))
            check("service lifetime: incognito tab loads", await loaded(window.browser, title: "second"))
            // Starts the profile's suggestions host.
            await expect("service lifetime: incognito suggestions answer") {
                try await !profile.autocomplete.suggestions(for: "cefswift").isEmpty
            }
            await expect("service lifetime: incognito favicons throw, as its history does") {
                do {
                    _ = try await profile.history.favicon(for: URL(string: "selftest://edge/favicon.html")!)
                    return false
                } catch {
                    return true
                }
            }
            await expect("service lifetime: incognito history throws instead of opening chrome://history") {
                do {
                    _ = try await profile.history.search(limit: 1)
                    return false
                } catch {
                    return true
                }
            }
            await expect("service lifetime: incognito bookmarks are the default profile's") {
                guard profile.bookmarks === CefProfile.default.bookmarks else { return false }
                return try await profile.bookmarks.tree().contains { $0.permanentFolder == .bookmarksBar }
            }
            window.close()
            _ = await waitUntil { window.isClosed }
        }
        check("service lifetime: an incognito profile goes with its last tab", await waitUntil { released == nil })
    }

    // MARK: Relaunch

    static func relaunchChecks() async {
        var received: [([String], URL?)] = []
        CefRuntime.shared.onRelaunch = { received.append(($0, $1)) }
        defer { CefRuntime.shared.onRelaunch = nil }
        guard let root = CefRuntime.shared.configuration?.rootCacheDirectory else {
            check("relaunch: cache directory known", false)
            return
        }
        let visibleBefore = NSApp.windows.filter(\.isVisible).count
        let second = Process()
        second.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        second.arguments = ["https://relaunch.selftest/"]
        second.currentDirectoryURL = FileManager.default.temporaryDirectory
        second.environment = ProcessInfo.processInfo.environment.merging([relaunchEnvironmentKey: root.path]) { $1 }
        do {
            try second.run()
        } catch {
            check("relaunch: second launch starts", false, detail: "\(error)")
            return
        }
        let exited = await waitUntil(timeout: .seconds(20)) { !second.isRunning }
        check("relaunch: the second launch exits", exited && second.terminationStatus == 0,
              detail: exited ? "status \(second.terminationStatus)" : "still running")
        if !exited { second.terminate() }
        check("relaunch: arguments reach onRelaunch", await waitUntil(timeout: .seconds(5)) {
            received.contains { $0.0.contains("https://relaunch.selftest/") && $0.1 != nil }
        }, detail: "\(received)")
        try? await Task.sleep(for: .seconds(1))
        check("relaunch: no window of Chromium's appears",
              NSApp.windows.filter(\.isVisible).count == visibleBefore && CefRuntime.shared.browsers.isEmpty,
              detail: "\(NSApp.windows.filter(\.isVisible).map(\.title)), \(CefRuntime.shared.browsers.count) browsers")
    }
}

/// Records what a SwiftUI view saw each time it rendered.
@MainActor
final class RenderLog {
    var titles: [String] = []
}

/// Shows a browser's title and logs each render.
struct TitleProbe: View {
    let browser: CefBrowser
    let log: RenderLog

    var body: some View {
        let _ = log.titles.append(browser.title)
        Text(browser.title)
    }
}

/// Counts changes to a browser's observable zoom level.
@MainActor
final class ZoomObserver {
    let browser: CefBrowser
    private(set) var changes = 0

    init(_ browser: CefBrowser) {
        self.browser = browser
        observe()
    }

    private func observe() {
        withObservationTracking { _ = browser.zoomLevel } onChange: { [weak self] in
            Task { @MainActor in
                self?.changes += 1
                self?.observe()
            }
        }
    }
}
