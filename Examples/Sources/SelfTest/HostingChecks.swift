import AppKit
import CefKit

// A live browser moved from one host view to another, and withdrawn from
// its host with `stopHosting(in:)`: the host it left lets go completely.
extension SelfTest {
    static func hostingChecks() async {
        await offscreenTransferChecks()
        await windowedTransferChecks()
        await settersBeforeCreationChecks()
    }

    /// Zoom and mute set before Chromium creates the browser apply once it
    /// has.
    private static func settersBeforeCreationChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!)
        browser.zoomLevel = 1
        browser.isAudioMuted = true
        let view = hostWindowed(browser)
        guard await loaded(browser, title: "second") else {
            check("hosting: page loads for pre-creation setters", false, detail: browser.title)
            await closeHosted(browser, view)
            return
        }
        // At zoom level 1 (120%), CSS pixels are 1.2 times larger.
        let ratio = (try? await browser.evaluateJavaScript("devicePixelRatio").doubleValue) ?? 0
        let expected = window.backingScaleFactor * 1.2
        check("hosting: a zoom level set before creation applies to the first page",
              abs(ratio - expected) < 0.01 && abs(browser.zoomLevel - 1) < 0.001,
              detail: "devicePixelRatio \(ratio), expected \(expected), zoomLevel \(browser.zoomLevel)")
        check("hosting: muting before creation applies once created", browser.isAudioMuted)
        // Chromium keeps the level for the site, which later checks load.
        browser.zoomLevel = 0
        _ = await waitUntil { abs(browser.zoomLevel) < 0.001 }
        await closeHosted(browser, view)
    }

    static let transferPage = URL(string: "selftest://app/transfer.html")!

    private static func offscreenTransferChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: transferPage, configuration: configuration)
        let bounds = window.contentView!.bounds
        let first = CefOffscreenBrowserView(browser: browser)
        first.frame = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        window.contentView!.addSubview(first)
        defer { first.removeFromSuperview() }
        guard await loaded(browser, title: "transfer") else {
            check("hosting: offscreen page loads", false, detail: browser.title)
            await closeHosted(browser, first)
            return
        }

        let second = CefOffscreenBrowserView(browser: browser)
        second.frame = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2 - 40, height: bounds.height - 60)
        window.contentView!.addSubview(second)
        defer { second.removeFromSuperview() }
        check("hosting: offscreen transfer — the first view lets go",
              first.browser == nil && second.browser === browser && browser.hostView === second)

        func innerSize() async -> String {
            (try? await browser.evaluateJavaScript("innerWidth + 'x' + innerHeight").stringValue) ?? "?"
        }
        let secondSize = "\(Int(second.bounds.width))x\(Int(second.bounds.height))"
        check("hosting: offscreen transfer — the page takes the new view's size",
              await waitUntilAsync { await innerSize() == secondSize }, detail: await innerSize())

        // The view it left neither resizes the page nor hosts it again.
        first.setFrameSize(CGSize(width: first.frame.width + 50, height: first.frame.height - 50))
        first.layoutSubtreeIfNeeded()
        first.removeFromSuperview()
        window.contentView!.addSubview(first)
        try? await Task.sleep(for: .milliseconds(300))
        check("hosting: offscreen transfer — the old view does not take it back",
              browser.hostView === second && first.browser == nil && second.browser === browser)
        check("hosting: offscreen transfer — the old view does not resize it",
              await innerSize() == secondSize, detail: await innerSize())

        if window.occlusionState.contains(.visible) {
            let painted = await waitUntil { second.layer?.sublayers?.first?.contents != nil }
            let png = try? await browser.snapshot()
            let image = png.flatMap { NSBitmapImageRep(data: $0) }
            let scale = window.backingScaleFactor
            check("hosting: offscreen transfer — frames reach the new view, in full",
                  painted && first.layer?.sublayers?.first?.contents == nil
                      && image?.pixelsWide == Int(second.bounds.width * scale)
                      && image?.pixelsHigh == Int(second.bounds.height * scale),
                  detail: "painted \(painted), image \(image.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "none")")
        } else {
            skip("hosting: offscreen transfer — frames reach the new view, in full",
                 because: "the test window is not visible (screen locked or asleep?)", .environment)
        }

        // Input: a click in the new view reaches the page at its point;
        // one in the old view goes nowhere.
        func click(_ view: NSView, at point: CGPoint) {
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { continue }
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        click(first, at: CGPoint(x: 5, y: 5))
        click(second, at: CGPoint(x: 30, y: 40))
        check("hosting: offscreen transfer — input comes from the new view only",
              await waitUntil { browser.title == "down 30,40" }, detail: browser.title)

        // Accessibility: the tree belongs to the new view.
        _ = second.accessibilityChildren()
        let treeArrived = await waitUntil {
            allElements(under: second).contains { ($0.accessibilityTitle() ?? $0.accessibilityLabel()) == "Transfer" }
        }
        check("hosting: offscreen transfer — accessibility follows the new view",
              treeArrived && (first.accessibilityChildren() ?? []).isEmpty,
              detail: "\(browser.accessibilityTree.nodeCount) nodes")

        // Withdrawn: the view lets go and the browser stops painting, but
        // stays live; a stale host withdraws nothing.
        browser.stopHosting(in: first)
        check("hosting: stopHosting from a stale host does nothing", browser.hostView === second && second.browser === browser)
        browser.stopHosting(in: second)
        check("hosting: stopHosting withdraws without closing",
              second.browser == nil && browser.hostView == nil && browser.state == .live)
        second.browser = browser
        let resized = await waitUntilAsync { await innerSize() == secondSize }
        check("hosting: a withdrawn browser can be hosted again", browser.hostView === second && resized)
        await closeHosted(browser, second)
    }

    private static func windowedTransferChecks() async {
        let browser = CefBrowser(url: transferPage)
        let bounds = window.contentView!.bounds
        let first = CefWindowedBrowserView(browser: browser)
        first.frame = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        window.contentView!.addSubview(first)
        defer { first.removeFromSuperview() }
        guard await loaded(browser, title: "transfer") else {
            check("hosting: windowed page loads", false, detail: browser.title)
            await closeHosted(browser, first)
            return
        }
        let second = CefWindowedBrowserView(browser: browser)
        second.frame = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2 - 40, height: bounds.height - 60)
        window.contentView!.addSubview(second)
        defer { second.removeFromSuperview() }
        first.removeFromSuperview()
        window.contentView!.addSubview(first)
        check("hosting: windowed transfer — the old view lets go and does not take it back",
              first.browser == nil && browser.hostView === second && browser.nativeView?.superview === second
                  && !first.acceptsFirstResponder)
        let secondSize = "\(Int(second.bounds.width))x\(Int(second.bounds.height))"
        check("hosting: windowed transfer — the page takes the new view's size", await waitUntilAsync {
            (try? await browser.evaluateJavaScript("innerWidth + 'x' + innerHeight").stringValue) == secondSize
        })
        browser.stopHosting(in: second)
        check("hosting: windowed stopHosting removes the native view without closing",
              second.browser == nil && browser.nativeView?.superview == nil && browser.state == .live)
        await closeHosted(browser, second)
    }
}
