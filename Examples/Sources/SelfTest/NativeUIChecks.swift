import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import SwiftUI

/// Checks of what CefSwift does through Chromium's AppKit classes: presenting
/// Chromium's surfaces as the app asks, and swipe navigation with
/// its indicator. A CEF update that renames those classes fails here.
extension SelfTest {
    static func nativeUIChecks() async {
        let features = CefTesting.runtimeHookFeatures
        check("runtime hooks: every feature's AppKit classes and methods exist",
              !features.isEmpty && features.allSatisfy(\.missing.isEmpty),
              detail: features.filter { !$0.missing.isEmpty }.map { "\($0.name): \($0.missing.joined(separator: ", "))" }
                  .joined(separator: "; "))
        for feature in features {
            print("     \(feature.name): \(feature.missing.isEmpty ? "installed" : "unavailable")")
        }
        await bubbleChecks()
        await chromeSwipeChecks()
        await viewSwipeIndicatorChecks()
    }

    // MARK: Chromium's surfaces

    static func bubbleChecks() async {
        guard let server = try? await LocalServer.start() else {
            print("SKIP [environment] surfaces: could not start a local HTTP server")
            return
        }
        defer { server.stop() }
        let pageURL = URL(string: "http://127.0.0.1:\(server.port)/page")!
        let browser = CefBrowser(url: pageURL)
        var configuration = CefBrowserWindow.Configuration()
        configuration.frame = CGRect(x: 160, y: 160, width: 900, height: 640)
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        var announced: [CefChromiumSurface.Kind] = []
        window.onChromiumSurface = { announced.append($0.kind) }
        // In window coordinates: a control wider than the bubble, near the
        // top, with room on both sides.
        let anchorRect = CGRect(x: 240, y: 560, width: 400, height: 24)
        window.chromiumUI.anchor = .rect(anchorRect, alignment: .leading)
        window.show()
        _ = await waitUntil { browser.title == "page" && !browser.isLoading }
        guard let nsWindow = window.window else { return }

        // A SwiftUI view in the toolbar registers itself as an anchor (and
        // SwiftUI keeps updating: no update loop).
        window.setToolbar { Text("QR").chromiumSurfaceAnchor([.qrCode]) }
        check("surfaces: a SwiftUI toolbar view becomes an anchor",
              await waitUntil(timeout: .seconds(5)) { window.chromiumUI.anchors[.qrCode] != nil })
        window.chromiumUI.anchors[.qrCode] = nil

        /// The visible surface windows Chromium has attached.
        func visibleSurfaceWindows() -> [NSWindow] {
            (nsWindow.childWindows ?? []).filter {
                NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" && $0.isVisible && $0.alphaValue > 0
            }
        }

        // Native, anchored.
        browser.execute(.createQRCode)
        check("surfaces: QR code recognized and announced",
              await waitUntil { window.chromiumSurfaces.contains { $0.kind == .qrCode } && announced.contains(.qrCode) },
              detail: "\(window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })")
        if let qr = window.chromiumSurfaces.first(where: { $0.kind == .qrCode }) {
            func isUnderAnchor(_ rect: CGRect, trailing: Bool = false) -> Bool {
                guard let frame = qr.window?.frame else { return false }
                let anchor = nsWindow.convertToScreen(rect)
                let x = trailing ? frame.maxX - anchor.maxX : frame.minX - anchor.minX
                return abs(x) <= 1 && abs(frame.maxY - (anchor.minY - 4)) <= 1
            }
            check("surfaces: QR code placed under the anchor",
                  await waitUntil(timeout: .seconds(3)) { isUnderAnchor(anchorRect) },
                  detail: "\(qr.window.map { NSStringFromRect($0.frame) } ?? "-")")
            check("surfaces: QR code shows the page's address", qr.url == pageURL, detail: "\(String(describing: qr.url))")
            var frame = nsWindow.frame
            frame.origin.x += 60
            frame.origin.y -= 40
            nsWindow.setFrame(frame, display: true)
            check("surfaces: follow the window as it moves",
                  await waitUntil(timeout: .seconds(3)) { isUnderAnchor(anchorRect) })
            window.chromiumUI.anchors[.qrCode] = .rect(anchorRect, alignment: .trailing)
            check("surfaces: a kind's own anchor takes precedence",
                  await waitUntil(timeout: .seconds(3)) { isUnderAnchor(anchorRect, trailing: true) })
            window.chromiumUI.anchors[.qrCode] = nil
            qr.dismiss()
            check("surfaces: dismiss closes Chromium's surface",
                  await waitUntil(timeout: .seconds(5)) { qr.window?.isVisible != true && window.chromiumSurfaces.isEmpty })
        }

        // Hidden.
        window.chromiumUI[.qrCode] = .hidden
        browser.execute(.createQRCode)
        try? await Task.sleep(for: .milliseconds(800))
        check("surfaces: a hidden kind never shows", visibleSurfaceWindows().isEmpty && window.chromiumSurfaces.isEmpty)

        // Custom, from the command.
        var presented: [CefChromiumSurface] = []
        window.setCustomPresentation(for: .qrCode) { presented.append($0) }
        browser.execute(.createQRCode)
        check("surfaces: a custom QR code gets the page's address",
              presented.count == 1 && presented[0].url == pageURL && presented[0].window == nil
                  && visibleSurfaceWindows().isEmpty)
        presented.first?.dismiss()
        check("surfaces: dismissing a custom surface removes it", window.chromiumSurfaces.isEmpty)

        // Custom, decided as Chromium's surface appears.
        // Without a presenter, a custom surface goes to onChromiumSurface.
        window.setCustomPresentation(for: .qrCode, nil)
        window.onChromiumSurface = { surface in
            if surface.presentation == .custom { presented.append(surface) }
        }
        window.presentationForSurface = { $0.kind == .qrCode ? .custom : nil }
        presented = []
        browser.execute(.createQRCode)
        check("surfaces: Chromium's surface replaced as it appears",
              await waitUntil(timeout: .seconds(5)) { presented.count == 1 }
                  && presented.first?.url == pageURL && visibleSurfaceWindows().isEmpty,
              detail: "\(presented.count) \(visibleSurfaceWindows().map(\.title))")
        presented.first?.dismiss()
        window.presentationForSurface = nil
        window.onChromiumSurface = nil

        // Share: Chromium has none without its toolbar; custom here.
        window.setCustomPresentation(for: .share) { presented.append($0) }
        presented = []
        browser.execute(.showSharingHub)
        check("surfaces: share goes to the app", presented.first?.kind == .share && presented.first?.url == pageURL)
        presented.first?.dismiss()

        // Find: Chromium's bar, then the app's.
        browser.execute(.find)
        check("surfaces: find bar recognized",
              await waitUntil(timeout: .seconds(5)) { window.chromiumSurfaces.contains { $0.kind == .findBar } },
              detail: "\(window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })")
        if let findBar = window.chromiumSurfaces.first(where: { $0.kind == .findBar }) {
            let findAnchor = CGRect(x: 40, y: 500, width: 10, height: 10)
            window.chromiumUI.anchors[.findBar] = .rect(findAnchor, alignment: .leading)
            let anchor = nsWindow.convertToScreen(findAnchor)
            check("surfaces: find bar follows its own anchor", await waitUntil(timeout: .seconds(3)) {
                guard let frame = findBar.window?.frame else { return false }
                return abs(frame.minX - anchor.minX) <= 1 && abs(frame.maxY - (anchor.minY - 4)) <= 1
            })
            findBar.dismiss()
            check("surfaces: find bar dismisses", await waitUntil(timeout: .seconds(5)) { findBar.window?.isVisible != true })
        }
        window.setCustomPresentation(for: .findBar) { presented.append($0) }
        presented = []
        browser.execute(.find)
        let session = browser.findSession
        check("surfaces: a custom find bar starts a find session",
              presented.first?.kind == .findBar && session.isActive && visibleSurfaceWindows().isEmpty)
        // The page has "page" three times in its text.
        func findState(_ active: Int, of count: Int) async -> Bool {
            await waitUntil(timeout: .seconds(5)) {
                session.matchCount == count && session.activeMatch == active && session.isComplete
            }
        }
        session.text = "page"
        check("find session: a new search highlights 1 of 3", await findState(1, of: 3),
              detail: "\(session.activeMatch) of \(session.matchCount)")
        session.next()
        check("find session: next goes to 2 of 3", await findState(2, of: 3),
              detail: "\(session.activeMatch) of \(session.matchCount)")
        session.next()
        session.next()
        check("find session: next wraps around to 1 of 3", await findState(1, of: 3),
              detail: "\(session.activeMatch) of \(session.matchCount)")
        session.previous()
        check("find session: previous wraps back to 3 of 3", await findState(3, of: 3),
              detail: "\(session.activeMatch) of \(session.matchCount)")
        session.text = "zzqqxx"
        check("find session: no matches is 0 of 0", await findState(0, of: 0),
              detail: "\(session.activeMatch) of \(session.matchCount)")
        presented.first?.dismiss()
        check("find session: ends with the surface", !session.isActive && window.chromiumSurfaces.isEmpty)

        // Cast. The embedded configuration turns the media router off, and
        // with it Chromium's Cast dialog; discovering devices would also ask
        // for local network access.
        check("media router: off with the MediaRouter feature off", !CefMediaRouter.shared.isAvailable)
        CefMediaRouter.shared.startDiscovery()
        check("media router: discovery does not start when off", !CefMediaRouter.shared.isDiscovering)
        window.setCustomPresentation(for: .cast) { presented.append($0) }
        presented = []
        browser.execute(.castMedia)
        check("surfaces: a custom Cast picker gets the page", presented.first?.kind == .cast && presented.first?.url == pageURL)
        presented.first?.dismiss()

        // Status bubble, from a pointer over a link.
        func hoverLink() async {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 1, "y": 1])
            let point = try? await browser.evaluateJavaScript(
                "(() => { const r = document.getElementById('link').getBoundingClientRect(); return [r.x + 4, r.y + 4]; })()")
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": "mouseMoved", "x": .number(point?[0].doubleValue ?? 0), "y": .number(point?[1].doubleValue ?? 0),
            ])
        }
        await hoverLink()
        check("surfaces: status bubble recognized",
              await waitUntil(timeout: .seconds(5)) { window.chromiumSurfaces.contains { $0.kind == .statusBubble } },
              detail: "\(browser.statusText) \(window.chromiumSurfaces.map { "\($0.kind)" })")
        window.statusBubbleView = NSView()
        _ = try? await browser.devTools.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 1, "y": 1])
        try? await Task.sleep(for: .milliseconds(600))
        await hoverLink()
        // Chromium fades its bubble in by raising its window's alpha, so
        // sample across the fade rather than once.
        let shown = await waitUntil(timeout: .seconds(3)) { !browser.statusText.isEmpty }
        var leaks: [String] = []
        for _ in 0..<25 {
            leaks += visibleSurfaceWindows().map { "alpha \($0.alphaValue) \(NSStringFromRect($0.frame))" }
            try? await Task.sleep(for: .milliseconds(40))
        }
        check("surfaces: an app's status bubble keeps Chromium's hidden throughout its fade",
              shown && leaks.isEmpty, detail: "\(browser.statusText) \(leaks.prefix(3))")
        window.statusBubbleView = nil

        // CefSwiftUI's find bar: a title-bar accessory while the session runs.
        window.setFindBar { _ in Text("Find").padding() }
        func findBarShows() -> Bool {
            nsWindow.titlebarAccessoryViewControllers.contains { !$0.isHidden && $0.view.frame.height > 0 }
        }
        browser.execute(.find)
        check("surfaces: SwiftUI find bar shows under the toolbar", await waitUntil(timeout: .seconds(3)) { findBarShows() })
        browser.findSession.end()
        check("surfaces: SwiftUI find bar hides when the session ends",
              await waitUntil(timeout: .seconds(3)) { !findBarShows() && window.chromiumSurfaces.isEmpty })

        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Swipes

    /// Chrome-style windows swipe with Chrome's `HistorySwiper`; these
    /// checks drive its `HistoryOverlayController` as the swiper does.
    static func chromeSwipeChecks() async {
        var options = CefBrowserOptions()
        options.allowsBackForwardNavigationGestures = true
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "second" }
        guard let contentView = window.window?.contentView,
              let overlay = CefTesting.beginChromeSwipe(in: window, forward: false)
        else {
            check("swipe: Chrome's history overlay can be driven", false)
            window.close()
            _ = await waitUntil { window.isClosed }
            return
        }
        CefTesting.updateChromeSwipe(overlay, amount: 0.4, finished: false)
        check("swipe: Chrome's progress reaches navigationGestureProgress",
              abs(browser.navigationGestureProgress + 0.4) < 0.001, detail: "\(browser.navigationGestureProgress)")
        check("swipe: built-in indicator shows in a browser window",
              await waitUntil(timeout: .seconds(2)) { CefTesting.gestureIndicator(in: contentView).isShowing },
              detail: "\(CefTesting.gestureIndicator(in: contentView))")
        CefTesting.updateChromeSwipe(overlay, amount: 0.9, finished: true)
        check("swipe: Chrome's commit point is -1", browser.navigationGestureProgress <= -1,
              detail: "\(browser.navigationGestureProgress)")
        CefTesting.endChromeSwipe(overlay)
        check("swipe: progress returns to 0", browser.navigationGestureProgress == 0)
        check("swipe: Chrome's render widget delegate can be asked", historySwipingAllowed(in: contentView) != nil)
        window.close()
        _ = await waitUntil { window.isClosed }

        let plain = CefBrowser(url: URL(string: "selftest://app/second.html")!)
        let plainWindow = CefBrowserWindow(browser: plain)
        plainWindow.show()
        _ = await waitUntil { plain.title == "second" }
        if let contentView = plainWindow.window?.contentView {
            check("swipe: off by default in browser windows",
                  historySwipingAllowed(in: contentView) == false && !CefTesting.gestureIndicator(in: contentView).isInstalled,
                  detail: "\(String(describing: historySwipingAllowed(in: contentView)))")
        }
        plainWindow.close()
        _ = await waitUntil { plainWindow.isClosed }
    }

    /// What Chrome's render widget delegate answers to
    /// `shouldAllowHistorySwiping`, or `nil` if it cannot be asked.
    @MainActor
    static func historySwipingAllowed(in view: NSView) -> Bool? {
        func find(_ view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)) == "RenderWidgetHostViewCocoa" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let host = find(view.superview ?? view),
              let ivar = class_getInstanceVariable(type(of: host), "_responderDelegate")
                  ?? class_getInstanceVariable(type(of: host), "responderDelegate_"),
              let delegate = object_getIvar(host, ivar) as? NSObject
        else { return nil }
        let selector = NSSelectorFromString("shouldAllowHistorySwiping")
        guard let imp = class_getMethodImplementation(type(of: delegate), selector) else { return nil }
        typealias Getter = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Getter.self)(delegate, selector)
    }

    /// The built-in indicator in views, offscreen and windowed.
    static func viewSwipeIndicatorChecks() async {
        for rendering in [CefRendering.windowed, .offscreen] {
            let name = rendering == .windowed ? "windowed" : "offscreen"
            var options = CefBrowserOptions()
            options.rendering = rendering
            options.allowsBackForwardNavigationGestures = true
            let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, options: options)
            let view: NSView
            if rendering == .windowed {
                let windowed = CefWindowedBrowserView()
                windowed.browser = browser
                view = windowed
            } else {
                let offscreen = CefOffscreenBrowserView()
                offscreen.browser = browser
                view = offscreen
            }
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            _ = await waitUntil { browser.title == "second" }
            check("swipe indicator: \(name) view has it", CefTesting.gestureIndicator(in: view) == (true, false))
            CefTesting.setNavigationGestureProgress(0.6, for: browser)
            check("swipe indicator: \(name) view shows progress",
                  await waitUntil(timeout: .seconds(2)) { CefTesting.gestureIndicator(in: view).isShowing })
            if rendering == .windowed {
                check("swipe indicator: above Chromium's view",
                      NSStringFromClass(type(of: view.subviews.last ?? view)).contains("Indicator"),
                      detail: "\(view.subviews.map { NSStringFromClass(type(of: $0)) })")
            }
            CefTesting.setNavigationGestureProgress(0, for: browser)
            check("swipe indicator: \(name) view hides at rest",
                  await waitUntil(timeout: .seconds(2)) { !CefTesting.gestureIndicator(in: view).isShowing })
            browser.close(force: true)
            _ = await waitUntil { browser.state == .closed }
            view.removeFromSuperview()
        }
    }
}
