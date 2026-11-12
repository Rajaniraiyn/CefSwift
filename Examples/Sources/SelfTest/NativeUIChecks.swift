import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Checks of what CefSwift does through Chromium's AppKit classes: placing
/// Chromium's bubbles under the app's anchors, and swipe navigation with
/// its indicator. A CEF update that renames those classes fails here.
extension SelfTest {
    static func nativeUIChecks() async {
        let missing = CefTesting.missingRuntimeHooks
        check("runtime hooks: Chromium's AppKit classes and methods exist", missing.isEmpty,
              detail: missing.joined(separator: ", "))
        await bubbleChecks()
        await chromeSwipeChecks()
        await viewSwipeIndicatorChecks()
    }

    // MARK: Bubbles

    static func bubbleChecks() async {
        guard let server = try? await LocalServer.start() else {
            print("SKIP bubbles: could not start a local HTTP server")
            return
        }
        defer { server.stop() }
        let browser = CefBrowser(url: URL(string: "http://127.0.0.1:\(server.port)/page")!)
        var configuration = CefBrowserWindow.Configuration()
        configuration.frame = CGRect(x: 160, y: 160, width: 900, height: 640)
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        var announced: [CefChromiumBubble.Kind] = []
        window.onChromiumBubble = { announced.append($0.kind) }
        // In window coordinates: a control wider than the bubble, near the
        // top, with room on both sides.
        let anchorRect = CGRect(x: 240, y: 560, width: 400, height: 24)
        window.bubbleAnchor = .rect(anchorRect, alignment: .leading)
        window.show()
        _ = await waitUntil { browser.title == "page" && !browser.isLoading }

        browser.execute(.createQRCode)
        check("bubbles: QR code bubble recognized and announced",
              await waitUntil { window.chromiumBubbles.contains { $0.kind == .qrCode } && announced.contains(.qrCode) },
              detail: "\(window.chromiumBubbles.map { "\($0.kind) '\($0.title)'" })")
        guard let bubble = window.chromiumBubbles.first(where: { $0.kind == .qrCode }), let nsWindow = window.window else {
            window.close()
            _ = await waitUntil { window.isClosed }
            return
        }

        /// Whether the bubble hangs under the anchor, aligned as asked.
        func isUnderAnchor(trailing: Bool = false) -> Bool {
            guard let frame = bubble.window?.frame else { return false }
            let anchor = nsWindow.convertToScreen(anchorRect)
            let x = trailing ? frame.maxX - anchor.maxX : frame.minX - anchor.minX
            return abs(x) <= 1 && abs(frame.maxY - (anchor.minY - 4)) <= 1
        }
        check("bubbles: placed under the anchor", await waitUntil(timeout: .seconds(3)) { isUnderAnchor() },
              detail: "\(bubble.window.map { NSStringFromRect($0.frame) } ?? "-")")
        var frame = nsWindow.frame
        frame.origin.x += 60
        frame.origin.y -= 40
        nsWindow.setFrame(frame, display: true)
        check("bubbles: follow the window as it moves", await waitUntil(timeout: .seconds(3)) { isUnderAnchor() },
              detail: "\(bubble.window.map { NSStringFromRect($0.frame) } ?? "-")")
        window.bubbleAnchor = .rect(anchorRect, alignment: .trailing)
        check("bubbles: follow a changed anchor", await waitUntil(timeout: .seconds(3)) { isUnderAnchor(trailing: true) })
        bubble.dismiss()
        check("bubbles: dismiss closes the bubble",
              await waitUntil(timeout: .seconds(5)) { !bubble.isVisible && window.chromiumBubbles.isEmpty })

        // The find bar is attached to the page; it moves only with an
        // anchor of its own.
        browser.execute(.find)
        check("bubbles: find bar recognized",
              await waitUntil(timeout: .seconds(5)) { window.chromiumBubbles.contains { $0.kind == .findBar } },
              detail: "\(window.chromiumBubbles.map { "\($0.kind) '\($0.title)'" })")
        if let findBar = window.chromiumBubbles.first(where: { $0.kind == .findBar }) {
            window.bubbleAnchors[.findBar] = .rect(CGRect(x: 40, y: 500, width: 10, height: 10), alignment: .leading)
            let anchor = nsWindow.convertToScreen(CGRect(x: 40, y: 500, width: 10, height: 10))
            check("bubbles: find bar follows its own anchor", await waitUntil(timeout: .seconds(3)) {
                guard let frame = findBar.window?.frame else { return false }
                return abs(frame.minX - anchor.minX) <= 1 && abs(frame.maxY - (anchor.minY - 4)) <= 1
            })
            findBar.dismiss()
            check("bubbles: find bar dismisses",
                  await waitUntil(timeout: .seconds(5)) { !findBar.isVisible })
        }
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
