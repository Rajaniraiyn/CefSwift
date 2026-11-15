import AppKit
import CefKit

// The page's `title` tooltips, per hosting mode: what Chromium reports
// (browser.tooltip), who shows it by default, and that the custom policy
// leaves the showing to the app.
extension SelfTest {
    private static let tooltipPage = """
        document.body.innerHTML = '<div title="A tip" style="position:fixed;inset:0"></div>'; 0
        """

    static func tooltipChecks() async {
        await offscreenTooltipChecks(policy: .automatic)
        await offscreenTooltipChecks(policy: .custom)
        await windowedTooltipChecks(chromeStyle: false)
        await windowedTooltipChecks(chromeStyle: true)
    }

    private static func offscreenTooltipChecks(policy: CefPage.TooltipPolicy) async {
        let name = policy == .automatic ? "offscreen" : "offscreen, custom"
        var configuration = CefPage.Configuration()
        configuration.rendering = .offscreen
        let page = CefPage(url: transferPage, configuration: configuration)
        page.tooltipPolicy = policy
        let view = hostOffscreen(page)
        guard await loaded(page, title: "transfer") else {
            check("tooltips (\(name)): page loads", false, detail: page.title)
            await closeHosted(page, view)
            return
        }
        _ = try? await page.evaluateJavaScript(tooltipPage)
        let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        // Chromium shows a tooltip once the pointer rests: move, then wait.
        var shown = false
        for step in 0..<4 where !shown {
            page.sendMouseMove(to: CGPoint(x: point.x + CGFloat(step), y: point.y))
            shown = await waitUntil(timeout: .seconds(2)) { page.tooltip?.text == "A tip" }
        }
        let location = page.tooltip?.location ?? .zero
        check("tooltips (\(name)): hovering a title reports its text where the pointer is",
              shown && abs(location.y - point.y) < 1 && abs(location.x - point.x) < 4,
              detail: "\(String(describing: page.tooltip))")
        if policy == .automatic {
            check("tooltips (offscreen): the view shows it as its own toolTip", view.toolTip == "A tip",
                  detail: view.toolTip ?? "none")
        } else {
            check("tooltips (offscreen, custom): nothing native shows", view.toolTip == nil, detail: view.toolTip ?? "")
        }
        page.sendScrollWheel(at: point, delta: CGVector(dx: 0, dy: -1))
        check("tooltips (\(name)): scrolling hides it", page.tooltip == nil)
        page.sendMouseMove(to: CGPoint(x: point.x + 5, y: point.y))
        _ = await waitUntil(timeout: .seconds(3)) { page.tooltip != nil }
        _ = await load(URL(string: "selftest://app/second.html")!, in: page, title: "second")
        check("tooltips (\(name)): navigating hides it",
              page.tooltip == nil && (policy == .custom || view.toolTip == nil),
              detail: "\(String(describing: page.tooltip)), view \(view.toolTip ?? "none")")
        await closeHosted(page, view)
    }

    /// A windowed or Chrome-style page: the pointer is the real mouse,
    /// which SelfTest does not move, so a mouse-moved event is sent to the
    /// window over Chromium's view.
    private static func windowedTooltipChecks(chromeStyle: Bool) async {
        let name = chromeStyle ? "Chrome style" : "windowed"
        let page = CefPage(url: transferPage)
        var view: NSView?
        var cefWindow: CefWindow?
        if chromeStyle {
            cefWindow = CefWindow(page: page)
            cefWindow?.show()
        } else {
            view = hostWindowed(page)
        }
        guard await loaded(page, title: "transfer"), let native = page.nativeView, let host = native.window else {
            check("tooltips (\(name)): page loads", false, detail: page.title)
            page.close(force: true)
            _ = await waitUntil { page.state == .closed }
            view?.removeFromSuperview()
            return
        }
        _ = try? await page.evaluateJavaScript(tooltipPage)
        let location = native.convert(CGPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil)
        for step in 0..<4 where page.tooltip == nil {
            if let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: location.x + CGFloat(step), y: location.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)
            {
                // Straight to the view under the point, as AppKit's
                // tracking areas would deliver it.
                let target = host.contentView?.hitTest(host.contentView?.convert(event.locationInWindow, from: nil) ?? .zero)
                (target ?? native).mouseMoved(with: event)
            }
            _ = await waitUntil(timeout: .seconds(2)) { page.tooltip != nil }
        }
        // Not a check: AppKit delivers hovers only from the real pointer,
        // which an unattended run must not move.
        print("NOTE tooltips (\(name)): a synthesized hover reported \(page.tooltip?.text ?? "no tooltip")")
        page.close(force: true)
        _ = await waitUntil { page.state == .closed && (cefWindow?.isClosed ?? true) }
        view?.removeFromSuperview()
        check("tooltips (\(name)): closing hides it", page.tooltip == nil)
    }
}
