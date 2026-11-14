import AppKit
@_spi(Testing) import CefKit

/// Page-level state and decisions: frame-aware navigation decisions, frame
/// origins, bridge calls and events per frame, content switches,
/// draggable regions and a frame rate that changes after creation.
extension SelfTest {
    static func pageStateChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("page state", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"
        await navigationDecisionChecks(origin: origin)
        await frameBridgeChecks(origin: origin)
        await contentSwitchChecks(origin: origin)
        await draggableRegionChecks()
        await offscreenFrameRateChecks()
    }

    private static func dataURL(_ html: String) -> URL {
        URL(string: "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    /// Subframe navigations reach the delegate, with their frame and
    /// transition, and cancelling one leaves the page.
    private static func navigationDecisionChecks(origin: String) async {
        let recorder = NavigationRecorder()
        recorder.cancelsSubframePath = "/policy/blocked"
        let page = "<title>frames</title><iframe id=a src='\(origin)/policy/page'></iframe>"
            + "<iframe id=b src='\(origin)/policy/blocked'></iframe>"
        let browser = CefBrowser(url: dataURL(page), delegate: recorder)
        let view = hostWindowed(browser)
        _ = await loaded(browser, title: "frames")
        _ = await waitUntil { recorder.actions.filter { !$0.isMainFrame }.count >= 2 }
        let main = recorder.actions.first { $0.isMainFrame }
        let sub = recorder.actions.first { !$0.isMainFrame && $0.url?.path == "/policy/page" }
        check("navigation: the main frame's decision has its frame and transition",
              main?.frame.isMain == true && main?.transition.source == .explicit && main?.transition.isDirectLoad == true,
              detail: "\(String(describing: main))")
        check("navigation: a subframe's navigation is decided, with its frame",
              sub != nil && sub?.frame.isMain == false && sub?.frame.parentID != nil
                  && sub?.transition.source == .autoSubframe,
              detail: "\(recorder.actions.map { ($0.url?.path ?? "", $0.isMainFrame, $0.transition.source) })")
        await expect("navigation: cancelling a subframe's navigation leaves the page and the other frame") {
            let blocked = try await browser.evaluateJavaScript(
                "(() => { try { return document.getElementById('b').contentDocument?.title ?? 'cross'; } catch { return 'cross'; } })()")
                .stringValue
            let frames = browser.frames.filter { !$0.isMain }.compactMap(\.url?.path)
            return (browser.title == "frames" && frames.contains("/policy/page") && !frames.contains("/policy/blocked"),
                    "\(blocked ?? "nil") \(frames)")
        }
        recorder.actions = []
        browser.reload()
        _ = await loaded(browser, title: "frames")
        check("navigation: a reload is reported as one",
              recorder.actions.first { $0.isMainFrame }?.transition.source == .reload,
              detail: "\(recorder.actions.map(\.transition))")
        await closeHosted(browser, view)
    }

    /// Frames know their origin; a bridge call knows its frame, and an
    /// event can go to that frame alone.
    private static func frameBridgeChecks(origin: String) async {
        let bridge = CefBridge(name: "frameBridge")
        bridge.access = .anyFrame
        var callers: [CefFrame] = []
        bridge.handle("hello") { (_: CefJSON, call: CefBridge.Call) -> String in
            callers.append(call.frame)
            return call.frame.isMain ? "main" : "sub"
        }
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [bridge]
        let page = "<title>bridge-frames</title><iframe src='\(origin)/policy/page'></iframe>"
        let browser = CefBrowser(url: dataURL(page), configuration: configuration)
        let view = hostWindowed(browser)
        _ = await loaded(browser, title: "bridge-frames")
        _ = await waitUntil { browser.frames.count == 2 }
        guard let sub = browser.frames.first(where: { !$0.isMain }) else {
            check("frames: the page's subframe attaches", false)
            await closeHosted(browser, view)
            return
        }
        check("frames: a frame carries the origin its address establishes",
              sub.origin == origin && browser.mainFrame?.origin == nil,
              detail: "\(sub.origin ?? "nil") \(browser.mainFrame?.origin ?? "nil")")
        let fromSub = try? await browser.evaluateJavaScript(
            "frameBridge.hello({}).then(v => { window.__said = v; return v; })", in: sub)
        _ = try? await browser.evaluateJavaScript("frameBridge.hello({})")
        check("bridge: a call carries the frame it came from",
              fromSub?.stringValue == "sub" && callers.first?.id == sub.id && callers.last?.isMain == true,
              detail: "\(fromSub?.stringValue ?? "nil") \(callers.map(\.id))")
        let listen = "frameBridge.on('ping', v => { window.__pinged = v.n; }); 0"
        _ = try? await browser.evaluateJavaScript(listen, in: sub)
        _ = try? await browser.evaluateJavaScript(listen)
        bridge.emit("ping", ["n": 5], to: sub, in: browser)
        let reached = await waitUntilAsync {
            (try? await browser.evaluateJavaScript("window.__pinged ?? 0", in: sub).intValue) == 5
        }
        let mainPinged = try? await browser.evaluateJavaScript("window.__pinged ?? 0").intValue
        check("bridge: an event sent to a frame reaches that frame alone", reached && mainPinged == 0,
              detail: "main \(mainPinged ?? -1)")
        await closeHosted(browser, view)
    }

    /// Per-page content switches from `cef_browser_settings_t`.
    private static func contentSwitchChecks(origin: String) async {
        var noScript = CefBrowser.Configuration()
        noScript.content.javaScript = .disabled
        let staticPage = dataURL("<title>static</title><script>document.title = 'ran';</script>")
        let scriptless = CefBrowser(url: staticPage, configuration: noScript)
        let scriptlessView = hostWindowed(scriptless)
        _ = await loaded(scriptless)
        check("content: JavaScript off keeps a page's scripts from running", scriptless.title == "static",
              detail: scriptless.title)
        await closeHosted(scriptless, scriptlessView)

        var switched = CefBrowser.Configuration()
        switched.content.images = .disabled
        switched.content.localStorage = .disabled
        switched.content.fonts.standardFamily = "Courier"
        let browser = CefBrowser(
            url: dataURL("<title>switches</title><p>text</p><img src='\(origin)/policy/image.png'>"),
            configuration: switched)
        let view = hostWindowed(browser)
        _ = await loaded(browser, title: "switches")
        await expect("content: images, local storage and fonts follow the page's configuration") {
            let state = try await browser.evaluateJavaScript("""
                (() => {
                  let storage; try { storage = typeof window.localStorage?.length; } catch (e) { storage = e.name; }
                  const style = getComputedStyle(document.querySelector('p'));
                  return [document.images[0].naturalWidth, storage, style.fontSize, style.fontFamily].join(' ');
                })()
                """).stringValue ?? ""
            return (state.hasPrefix("0 ") && !state.contains("number") && state.contains("Courier"),
                    state)
        }
        await closeHosted(browser, view)
    }

    /// `-webkit-app-region` reaches the page's draggable regions, in
    /// windowed and offscreen views.
    private static func draggableRegionChecks() async {
        let page = dataURL("""
            <title>regions</title><body style="margin:0">
            <div style="-webkit-app-region: drag; position: fixed; left: 0; top: 0; width: 300px; height: 40px">
              <button style="-webkit-app-region: no-drag; position: absolute; left: 200px; top: 5px; width: 60px; height: 30px">x</button>
            </div></body>
            """)
        for rendering in [CefBrowser.Rendering.windowed, .offscreen] {
            var configuration = CefBrowser.Configuration()
            configuration.rendering = rendering
            let browser = CefBrowser(url: page, configuration: configuration)
            let view: NSView = rendering == .windowed ? hostWindowed(browser) : hostOffscreen(browser)
            _ = await loaded(browser, title: "regions")
            let label = rendering == .windowed ? "windowed" : "offscreen"
            check("draggable regions (\(label)): the page's regions arrive",
                  await waitUntil(timeout: .seconds(5)) { !browser.draggableRegions.isEmpty }
                      && browser.isDraggable(at: CGPoint(x: 20, y: 20))
                      && !browser.isDraggable(at: CGPoint(x: 220, y: 20))
                      && !browser.isDraggable(at: CGPoint(x: 20, y: 200)),
                  detail: "\(browser.draggableRegions)")
            browser.load(dataURL("<title>plain</title>plain"))
            _ = await loaded(browser, title: "plain")
            check("draggable regions (\(label)): a page without regions has none", browser.draggableRegions.isEmpty,
                  detail: "\(browser.draggableRegions)")
            await closeHosted(browser, view)
        }
    }

    /// An offscreen browser's frame rate changes after creation.
    private static func offscreenFrameRateChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen(frameRate: 60)
        let browser = CefBrowser(url: dataURL("<title>rate</title>"), configuration: configuration)
        let view = hostOffscreen(browser)
        _ = await loaded(browser, title: "rate")
        let energy = CefRuntime.shared.energyPolicy
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = energy }
        browser.offscreenFrameRate = 90
        let raised = await waitUntil(timeout: .seconds(3)) { browser.currentOffscreenFrameRate == 90 }
        browser.offscreenFrameRate = 500
        let clamped = browser.offscreenFrameRate
        check("offscreen: the frame rate changes after creation, within 1…240",
              raised && clamped == 240, detail: "\(browser.currentOffscreenFrameRate ?? -1) \(clamped)")
        browser.setNeedsDisplay()
        await closeHosted(browser, view)
    }
}

/// Records every navigation decision, cancelling subframe navigations to
/// one path.
@MainActor
final class NavigationRecorder: CefBrowserDelegate {
    var actions: [CefNavigationAction] = []
    var cancelsSubframePath: String?

    func browser(_ browser: CefBrowser, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        actions.append(navigation)
        if !navigation.isMainFrame, let path = cancelsSubframePath, navigation.url?.path == path { return .cancel }
        return .allow
    }
}
