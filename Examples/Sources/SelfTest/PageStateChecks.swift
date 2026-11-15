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
        let html = "<title>frames</title><iframe id=a src='\(origin)/policy/page'></iframe>"
            + "<iframe id=b src='\(origin)/policy/blocked'></iframe>"
        let page = CefPage(url: dataURL(html), delegate: recorder)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "frames")
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
            let blocked = try await page.evaluateJavaScript(
                "(() => { try { return document.getElementById('b').contentDocument?.title ?? 'cross'; } catch { return 'cross'; } })()")
                .stringValue
            let frames = page.frames.filter { !$0.isMain }.compactMap(\.url?.path)
            return (page.title == "frames" && frames.contains("/policy/page") && !frames.contains("/policy/blocked"),
                    "\(blocked ?? "nil") \(frames)")
        }
        recorder.actions = []
        page.reload()
        _ = await loaded(page, title: "frames")
        check("navigation: a reload is reported as one",
              recorder.actions.first { $0.isMainFrame }?.transition.source == .reload,
              detail: "\(recorder.actions.map(\.transition))")
        await closeHosted(page, view)
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
        var configuration = CefPage.Configuration()
        configuration.bridges = [bridge]
        let html = "<title>bridge-frames</title><iframe src='\(origin)/policy/page'></iframe>"
        let page = CefPage(url: dataURL(html), configuration: configuration)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "bridge-frames")
        _ = await waitUntil { page.frames.count == 2 }
        guard let sub = page.frames.first(where: { !$0.isMain }) else {
            check("frames: the page's subframe attaches", false)
            await closeHosted(page, view)
            return
        }
        check("frames: a frame carries the origin its address establishes",
              sub.origin == origin && page.mainFrame?.origin == nil,
              detail: "\(sub.origin ?? "nil") \(page.mainFrame?.origin ?? "nil")")
        let fromSub = try? await page.evaluateJavaScript(
            "frameBridge.hello({}).then(v => { window.__said = v; return v; })", in: sub)
        _ = try? await page.evaluateJavaScript("frameBridge.hello({})")
        check("bridge: a call carries the frame it came from",
              fromSub?.stringValue == "sub" && callers.first?.id == sub.id && callers.last?.isMain == true,
              detail: "\(fromSub?.stringValue ?? "nil") \(callers.map(\.id))")
        let listen = "frameBridge.on('ping', v => { window.__pinged = v.n; }); 0"
        _ = try? await page.evaluateJavaScript(listen, in: sub)
        _ = try? await page.evaluateJavaScript(listen)
        bridge.emit("ping", ["n": 5], to: sub, in: page)
        let reached = await waitUntilAsync {
            (try? await page.evaluateJavaScript("window.__pinged ?? 0", in: sub).intValue) == 5
        }
        let mainPinged = try? await page.evaluateJavaScript("window.__pinged ?? 0").intValue
        check("bridge: an event sent to a frame reaches that frame alone", reached && mainPinged == 0,
              detail: "main \(mainPinged ?? -1)")
        await closeHosted(page, view)
    }

    /// Per-page content switches from `cef_browser_settings_t`.
    private static func contentSwitchChecks(origin: String) async {
        var noScript = CefPage.Configuration()
        noScript.content.javaScript = .disabled
        let staticPage = dataURL("<title>static</title><script>document.title = 'ran';</script>")
        let scriptless = CefPage(url: staticPage, configuration: noScript)
        let scriptlessView = hostWindowed(scriptless)
        _ = await loaded(scriptless)
        check("content: JavaScript off keeps a page's scripts from running", scriptless.title == "static",
              detail: scriptless.title)
        await closeHosted(scriptless, scriptlessView)

        var switched = CefPage.Configuration()
        switched.content.images = .disabled
        switched.content.localStorage = .disabled
        switched.content.fonts.standardFamily = "Courier"
        let page = CefPage(
            url: dataURL("<title>switches</title><p>text</p><img src='\(origin)/policy/image.png'>"),
            configuration: switched)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "switches")
        await expect("content: images, local storage and fonts follow the page's configuration") {
            let state = try await page.evaluateJavaScript("""
                (() => {
                  let storage; try { storage = typeof window.localStorage?.length; } catch (e) { storage = e.name; }
                  const style = getComputedStyle(document.querySelector('p'));
                  return [document.images[0].naturalWidth, storage, style.fontSize, style.fontFamily].join(' ');
                })()
                """).stringValue ?? ""
            return (state.hasPrefix("0 ") && !state.contains("number") && state.contains("Courier"),
                    state)
        }
        await closeHosted(page, view)
    }

    /// `-webkit-app-region` reaches the page's draggable regions, in
    /// windowed and offscreen views.
    private static func draggableRegionChecks() async {
        let html = dataURL("""
            <title>regions</title><body style="margin:0">
            <div style="-webkit-app-region: drag; position: fixed; left: 0; top: 0; width: 300px; height: 40px">
              <button style="-webkit-app-region: no-drag; position: absolute; left: 200px; top: 5px; width: 60px; height: 30px">x</button>
            </div></body>
            """)
        for rendering in [CefPage.Rendering.windowed, .offscreen] {
            var configuration = CefPage.Configuration()
            configuration.rendering = rendering
            let page = CefPage(url: html, configuration: configuration)
            let view: NSView = rendering == .windowed ? hostWindowed(page) : hostOffscreen(page)
            _ = await loaded(page, title: "regions")
            let label = rendering == .windowed ? "windowed" : "offscreen"
            check("draggable regions (\(label)): the page's regions arrive",
                  await waitUntil(timeout: .seconds(5)) { !page.draggableRegions.isEmpty }
                      && page.isDraggable(at: CGPoint(x: 20, y: 20))
                      && !page.isDraggable(at: CGPoint(x: 220, y: 20))
                      && !page.isDraggable(at: CGPoint(x: 20, y: 200)),
                  detail: "\(page.draggableRegions)")
            page.load(dataURL("<title>plain</title>plain"))
            _ = await loaded(page, title: "plain")
            check("draggable regions (\(label)): a page without regions has none", page.draggableRegions.isEmpty,
                  detail: "\(page.draggableRegions)")
            await closeHosted(page, view)
        }
    }

    /// An offscreen page's frame rate changes after creation.
    private static func offscreenFrameRateChecks() async {
        var configuration = CefPage.Configuration()
        configuration.rendering = .offscreen(frameRate: 60)
        let page = CefPage(url: dataURL("<title>rate</title>"), configuration: configuration)
        let view = hostOffscreen(page)
        _ = await loaded(page, title: "rate")
        let energy = CefRuntime.shared.energyPolicy
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = energy }
        page.offscreenFrameRate = 90
        let raised = await waitUntil(timeout: .seconds(3)) { page.currentOffscreenFrameRate == 90 }
        page.offscreenFrameRate = 500
        let clamped = page.offscreenFrameRate
        check("offscreen: the frame rate changes after creation, within 1…240",
              raised && clamped == 240, detail: "\(page.currentOffscreenFrameRate ?? -1) \(clamped)")
        page.setNeedsDisplay()
        await closeHosted(page, view)
    }
}

/// Records every navigation decision, cancelling subframe navigations to
/// one path.
@MainActor
final class NavigationRecorder: CefPageDelegate {
    var actions: [CefNavigationAction] = []
    var cancelsSubframePath: String?

    func page(_ page: CefPage, decidePolicyFor navigation: CefNavigationAction) -> CefNavigationDecision {
        actions.append(navigation)
        if !navigation.isMainFrame, let path = cancelsSubframePath, navigation.url?.path == path { return .cancel }
        return .allow
    }
}
