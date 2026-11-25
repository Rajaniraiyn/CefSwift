import AppKit
import CefKit

// A live page moved from one host view to another, and withdrawn from
// its host with `stopHosting(in:)`: the host it left lets go completely.
extension SelfTest {
    static func hostingChecks() async {
        await offscreenTransferChecks()
        await windowedTransferChecks()
        await windowedTouchChecks()
        await settersBeforeCreationChecks()
    }

    private static func windowedTouchChecks() async {
        let name = "hosting: a windowed page receives a touch sequence at the requested coordinates"
        guard window.occlusionState.contains(.visible) else {
            skip(name, because: "the test window is not visible (screen locked or asleep?)", .environment)
            return
        }

        let page = CefPage(url: URL(string: "selftest://app/windowed-touch.html")!)
        let view = hostWindowed(page)
        guard await loaded(page), await waitUntil({ page.title == "touch ready" }) else {
            check(name, false, detail: "touch target did not paint: \(page.title)")
            await closeHosted(page, view)
            return
        }
        page.hostViewDidBecomeKey()
        let point = CGPoint(x: 30, y: 40)
        page.sendTouchEvent(.init(id: 1, location: point, phase: .began, pressure: 1))
        let began = await waitUntil { page.title == "touchstart 30,40" }
        page.sendTouchEvent(.init(id: 1, location: point, phase: .ended))
        let ended = await waitUntil { page.title == "touchstart 30,40; touchend 30,40" }
        check(name, began && ended, detail: page.title)
        await closeHosted(page, view)
    }

    /// Zoom and mute set before Chromium creates the page apply once it
    /// has.
    private static func settersBeforeCreationChecks() async {
        let page = CefPage(url: URL(string: "selftest://app/second.html")!)
        page.zoomLevel = 1
        page.isAudioMuted = true
        let view = hostWindowed(page)
        guard await loaded(page, title: "second") else {
            check("hosting: page loads for pre-creation setters", false, detail: page.title)
            await closeHosted(page, view)
            return
        }
        // At zoom level 1 (120%), CSS pixels are 1.2 times larger.
        let ratio = (try? await page.evaluateJavaScript("devicePixelRatio").doubleValue) ?? 0
        let expected = window.backingScaleFactor * 1.2
        check("hosting: a zoom level set before creation applies to the first page",
              abs(ratio - expected) < 0.01 && abs(page.zoomLevel - 1) < 0.001,
              detail: "devicePixelRatio \(ratio), expected \(expected), zoomLevel \(page.zoomLevel)")
        check("hosting: muting before creation applies once created", page.isAudioMuted)
        // Chromium keeps the level for the site, which later checks load.
        page.zoomLevel = 0
        _ = await waitUntil { abs(page.zoomLevel) < 0.001 }
        await closeHosted(page, view)
    }

    static let transferPage = URL(string: "selftest://app/transfer.html")!

    private static func offscreenTransferChecks() async {
        var configuration = CefPage.Configuration()
        configuration.rendering = .offscreen
        let page = CefPage(url: transferPage, configuration: configuration)
        let bounds = window.contentView!.bounds
        let first = CefOffscreenPageView(page: page)
        first.frame = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        window.contentView!.addSubview(first)
        defer { first.removeFromSuperview() }
        guard await loaded(page, title: "transfer") else {
            check("hosting: offscreen page loads", false, detail: page.title)
            await closeHosted(page, first)
            return
        }

        let second = CefOffscreenPageView(page: page)
        second.frame = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2 - 40, height: bounds.height - 60)
        window.contentView!.addSubview(second)
        defer { second.removeFromSuperview() }
        check("hosting: offscreen transfer — the first view lets go",
              first.page == nil && second.page === page && page.hostView === second)

        func innerSize() async -> String {
            (try? await page.evaluateJavaScript("innerWidth + 'x' + innerHeight").stringValue) ?? "?"
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
              page.hostView === second && first.page == nil && second.page === page)
        check("hosting: offscreen transfer — the old view does not resize it",
              await innerSize() == secondSize, detail: await innerSize())

        if window.occlusionState.contains(.visible) {
            let painted = await waitUntil { second.layer?.sublayers?.first?.contents != nil }
            // The first frame at the new size can trail the transfer on a
            // slow machine: take snapshots until one has it.
            let scale = window.backingScaleFactor
            var image: NSBitmapImageRep?
            _ = await waitUntilAsync(timeout: .seconds(5)) {
                image = (try? await page.snapshot()).flatMap { NSBitmapImageRep(data: $0) }
                return image?.pixelsWide == Int(second.bounds.width * scale)
                    && image?.pixelsHigh == Int(second.bounds.height * scale)
            }
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
              await waitUntil { page.title == "down 30,40" }, detail: page.title)

        // Accessibility: the tree belongs to the new view.
        _ = second.accessibilityChildren()
        let treeArrived = await waitUntil {
            allElements(under: second).contains { ($0.accessibilityTitle() ?? $0.accessibilityLabel()) == "Transfer" }
        }
        check("hosting: offscreen transfer — accessibility follows the new view",
              treeArrived && (first.accessibilityChildren() ?? []).isEmpty,
              detail: "\(page.accessibilityTree.nodeCount) nodes")

        // Withdrawn: the view lets go and the page stops painting, but
        // stays live; a stale host withdraws nothing.
        page.stopHosting(in: first)
        check("hosting: stopHosting from a stale host does nothing", page.hostView === second && second.page === page)
        page.stopHosting(in: second)
        check("hosting: stopHosting withdraws without closing",
              second.page == nil && page.hostView == nil && page.state == .live)
        second.page = page
        let resized = await waitUntilAsync { await innerSize() == secondSize }
        check("hosting: a withdrawn browser can be hosted again", page.hostView === second && resized)
        await closeHosted(page, second)
    }

    private static func windowedTransferChecks() async {
        let page = CefPage(url: transferPage)
        let bounds = window.contentView!.bounds
        let first = CefWindowedPageView(page: page)
        first.frame = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        window.contentView!.addSubview(first)
        defer { first.removeFromSuperview() }
        guard await loaded(page, title: "transfer") else {
            check("hosting: windowed page loads", false, detail: page.title)
            await closeHosted(page, first)
            return
        }
        let second = CefWindowedPageView(page: page)
        second.frame = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2 - 40, height: bounds.height - 60)
        window.contentView!.addSubview(second)
        defer { second.removeFromSuperview() }
        first.removeFromSuperview()
        window.contentView!.addSubview(first)
        check("hosting: windowed transfer — the old view lets go and does not take it back",
              first.page == nil && page.hostView === second && page.nativeView?.superview === second
                  && !first.acceptsFirstResponder)
        let secondSize = "\(Int(second.bounds.width))x\(Int(second.bounds.height))"
        check("hosting: windowed transfer — the page takes the new view's size", await waitUntilAsync {
            (try? await page.evaluateJavaScript("innerWidth + 'x' + innerHeight").stringValue) == secondSize
        })
        page.stopHosting(in: second)
        // CEF closes a page whose view goes away, a moment later.
        try? await Task.sleep(for: .milliseconds(500))
        check("hosting: windowed stopHosting removes the native view without closing",
              second.page == nil && page.nativeView?.superview == nil && page.state == .live,
              detail: "\(page.state)")
        await closeHosted(page, second)
    }
}
