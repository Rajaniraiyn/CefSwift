import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import CCef
import CefSwiftUI
import SwiftUI

/// The states of Chromium's surfaces and the transitions between them, as
/// CefChromium models them: each of Chromium's windows goes attaching →
/// recognizing → shown or suppressed; each surface goes presented →
/// dismissed, once, with the reason.
extension SelfTest {
    static func surfaceStateChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("surface states", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(server.port)/")!
        await nativeTransitionChecks(base: base)
        await customTransitionChecks(base: base)
        await zoomAndStatusChecks(base: base)
        await newKindChecks(base: base)
        await windowLifecycleChecks(base: base)
    }

    /// A Chrome-style window on `/page`, every surface native.
    static func surfaceWindow(
        _ base: URL, path: String = "page", configure: (inout CefWindow.Configuration) -> Void = { _ in },
        browserConfiguration: CefBrowser.Configuration = .init()
    ) async -> CefWindow? {
        let browser = CefBrowser(url: base.appendingPathComponent(path), configuration: browserConfiguration)
        var configuration = CefWindow.Configuration()
        configuration.frame = CGRect(x: 160, y: 160, width: 900, height: 640)
        configure(&configuration)
        let window = CefWindow(browser: browser, configuration: configuration)
        window.chromiumSurfacePolicy = window.chromiumSurfacePolicy
        window.show()
        guard await loaded(browser), window.window != nil else {
            window.close()
            return nil
        }
        window.window?.orderFrontRegardless()
        return window
    }

    static func closeSurfaceWindow(_ window: CefWindow) async {
        window.close()
        _ = await waitUntil { window.isClosed && window.browser.state == .closed }
    }

    static func nativeSurface(_ kind: CefChromiumSurface.Kind, in window: CefWindow, timeout: Duration = .seconds(5)) async
        -> CefChromiumSurface?
    {
        _ = await waitUntil(timeout: timeout) { window.chromiumSurfaces.contains { $0.kind == kind && $0.window != nil } }
        return window.chromiumSurfaces.first { $0.kind == kind && $0.window != nil }
    }

    static func visibleWidgets(of window: CefWindow) -> [NSWindow] {
        (window.window?.childWindows ?? []).filter {
            NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" && $0.isVisible && $0.alphaValue > 0
        }
    }

    // MARK: Native surfaces

    static func nativeTransitionChecks(base: URL) async {
        guard let window = await surfaceWindow(base) else {
            return check("surface states: window loads", false)
        }
        let browser = window.browser

        // presented → dismissed(.app)
        browser.execute(.createQRCode)
        if let qr = await nativeSurface(.qrCode, in: window) {
            check("surface states: a native surface's window is followed as shown",
                  CefChromiumTesting.widgetPhases(of: window).contains("shown qrCode"),
                  detail: "\(CefChromiumTesting.widgetPhases(of: window))")
            qr.dismiss()
            check("surface states: dismiss() ends it as .app and Chromium's window closes",
                  await waitUntil { qr.state == .dismissed(.app) && qr.window?.isVisible != true && window.chromiumSurfaces.isEmpty },
                  detail: "\(qr.state)")
        } else {
            check("surface states: QR code appears", false)
        }

        // presented → dismissed(.chromium): Esc in Chromium's own bubble.
        browser.execute(.createQRCode)
        if let qr = await nativeSurface(.qrCode, in: window), let child = qr.window {
            SurfaceInventory.sendEscape(to: child)
            check("surface states: Esc in Chromium's bubble ends it as .chromium",
                  await waitUntil { qr.state == .dismissed(.chromium) && window.chromiumSurfaces.isEmpty },
                  detail: "\(qr.state)")
            check("surface states: a closed widget is no longer followed",
                  await waitUntil(timeout: .seconds(3)) { !CefChromiumTesting.widgetPhases(of: window).contains("shown qrCode") },
                  detail: "\(CefChromiumTesting.widgetPhases(of: window))")
        }

        // A second bubble of another kind while one is open: whatever
        // Chromium does with the first, its state says so.
        try? await Task.sleep(for: .milliseconds(500))
        browser.execute(.createQRCode)
        let qr = await nativeSurface(.qrCode, in: window)
        browser.execute(.zoomIn)
        let zoom = await nativeSurface(.zoom, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        print("NOTE surface states: QR code then zoom: \(window.chromiumSurfaces.map { "\($0.kind)" }), QR \(qr.map { "\($0.state)" } ?? "-")")
        // Chromium hides the first and shows it again: a new surface for
        // the same window. Listed surfaces are on screen; an ended one's
        // window is hidden or belongs to a newer surface.
        let listed = window.chromiumSurfaces
        let consistent = qr != nil && listed.allSatisfy { $0.window?.isVisible == true } && (qr.map { qr in
            qr.state == .presented || qr.window?.isVisible != true || listed.contains { $0.window === qr.window }
        } ?? false)
        check("surface states: a second bubble while one is open is followed, and the first's state matches its window",
              zoom != nil && consistent, detail: "\(window.chromiumSurfaces.map { "\($0.kind)" }) QR \(qr.map { "\($0.state)" } ?? "-")")
        browser.execute(.resetZoom)
        window.chromiumSurfaces.forEach { $0.dismiss() }
        _ = await waitUntil(timeout: .seconds(3)) { window.chromiumSurfaces.isEmpty }

        // Native → hidden while open.
        browser.execute(.createQRCode)
        if let qr = await nativeSurface(.qrCode, in: window) {
            window.chromiumSurfacePolicy[.qrCode] = .hidden
            check("surface states: native → hidden while open ends it as .presentation and hides Chromium's",
                  await waitUntil { qr.state == .dismissed(.presentation) && visibleWidgets(of: window).isEmpty },
                  detail: "\(qr.state) \(visibleWidgets(of: window).map(\.title))")
        }
        // A hidden one Chromium shows anyway (the zoom command still zooms)
        // is still announced.
        var announced: [CefChromiumSurface] = []
        window.onChromiumSurface = { announced.append($0) }
        window.chromiumSurfacePolicy[.zoom] = .hidden
        browser.execute(.zoomIn)
        check("surface states: a hidden kind is still announced, already dismissed",
              await waitUntil { announced.contains { $0.kind == .zoom && $0.state == .dismissed(.presentation) } }
                  && visibleWidgets(of: window).isEmpty,
              detail: "\(announced.map { "\($0.kind) \($0.state)" })")
        window.onChromiumSurface = nil
        browser.execute(.resetZoom)
        _ = await waitUntil(timeout: .seconds(3)) { browser.zoomLevel == 0 }
        try? await Task.sleep(for: .seconds(2))
        window.chromiumSurfacePolicy[.zoom] = .native

        // Native → custom while open: the app's interface takes over.
        window.chromiumSurfacePolicy[.qrCode] = .native
        browser.execute(.createQRCode)
        if let qr = await nativeSurface(.qrCode, in: window) {
            var presented: [CefChromiumSurface] = []
            window.setCustomPresentation(for: .qrCode) { presented.append($0) }
            check("surface states: native → custom while open moves it to the app's interface",
                  await waitUntil { qr.state == .dismissed(.presentation) && presented.count == 1 }
                      && presented.first?.url == qr.url && visibleWidgets(of: window).isEmpty,
                  detail: "\(qr.state), \(presented.count) presented")
            // Custom → native while presented: the app's is dismissed.
            window.setCustomPresentation(for: .qrCode, nil)
            check("surface states: custom → native dismisses the app's as .presentation",
                  presented.first?.state == .dismissed(.presentation) && window.chromiumSurfaces.isEmpty)
        }

        // Re-anchoring when an anchor view moves within the window.
        if let content = window.window?.contentView?.superview {
            let anchorView = NSView(frame: CGRect(x: 100, y: content.bounds.maxY - 80, width: 300, height: 20))
            content.addSubview(anchorView)
            window.chromiumSurfacePolicy.anchors[.qrCode] = .view(anchorView, alignment: .leading)
            browser.execute(.createQRCode)
            if let qr = await nativeSurface(.qrCode, in: window), let nsWindow = window.window {
                func isUnder(_ view: NSView) -> Bool {
                    guard let frame = qr.window?.frame else { return false }
                    let anchor = nsWindow.convertToScreen(view.convert(view.bounds, to: nil))
                    return abs(frame.minX - anchor.minX) <= 1 && abs(frame.maxY - (anchor.minY - 4)) <= 1
                }
                _ = await waitUntil(timeout: .seconds(3)) { isUnder(anchorView) }
                anchorView.frame.origin.x += 120
                NSApp.updateWindows()
                check("surface states: follows an anchor view that moves within the window",
                      await waitUntil(timeout: .seconds(3)) { isUnder(anchorView) },
                      detail: "\(qr.window.map { NSStringFromRect($0.frame) } ?? "-")")
                // Right to left: leading is the right edge.
                window.window?.contentView?.userInterfaceLayoutDirection = .rightToLeft
                window.chromiumSurfacePolicy.anchors[.qrCode] = .view(anchorView, alignment: .leading)
                check("surface states: a leading anchor lines up right edges in a right-to-left layout",
                      await waitUntil(timeout: .seconds(3)) {
                          guard let frame = qr.window?.frame else { return false }
                          let anchor = nsWindow.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
                          return abs(frame.maxX - anchor.maxX) <= 1
                      }, detail: "\(qr.window.map { NSStringFromRect($0.frame) } ?? "-")")
                window.window?.contentView?.userInterfaceLayoutDirection = .leftToRight
                qr.dismiss()
            }
            window.chromiumSurfacePolicy.anchors[.qrCode] = nil
            anchorView.removeFromSuperview()
        }

        // A native bubble and a navigation.
        browser.execute(.createQRCode)
        if let qr = await nativeSurface(.qrCode, in: window) {
            _ = await load(base.appendingPathComponent("ping-page"), in: browser)
            try? await Task.sleep(for: .milliseconds(500))
            print("NOTE surface states: Chromium's QR code bubble after a navigation: \(qr.state)")
            qr.dismiss()
        }
        await closeSurfaceWindow(window)
    }

    // MARK: Custom surfaces

    static func customTransitionChecks(base: URL) async {
        guard let window = await surfaceWindow(base) else {
            return check("surface states: custom window loads", false)
        }
        let browser = window.browser
        var presented: [CefChromiumSurface] = []
        window.setCustomPresentation(for: .qrCode) { presented.append($0) }

        // A second command replaces the first.
        browser.execute(.createQRCode)
        browser.execute(.createQRCode)
        check("surface states: a second custom surface replaces the first (.replaced)",
              presented.count == 2 && presented[0].state == .dismissed(.replaced) && presented[1].state == .presented
                  && window.chromiumSurfaces.count == 1)

        // A navigation ends it, as Chromium's bubbles end.
        _ = await load(base.appendingPathComponent("ping-page"), in: browser)
        check("surface states: a navigation ends a custom bubble as .chromium",
              await waitUntil(timeout: .seconds(3)) { presented.last?.state == .dismissed(.chromium) && window.chromiumSurfaces.isEmpty },
              detail: "\(presented.last.map { "\($0.state)" } ?? "-")")
        window.setCustomPresentation(for: .qrCode, nil)

        // Only replaceable kinds take a presenter.
        window.setCustomPresentation(for: .translate) { _ in }
        window.setCustomPresentation(for: .autofillSuggestions) { _ in }
        check("surface states: kinds the app cannot replace keep their native presentation",
              window.chromiumSurfacePolicy[.translate] == .native && window.chromiumSurfacePolicy[.autofillSuggestions] == .native)

        // The find bar: ⌘F again keeps it and its search; the session's end
        // ends it.
        var finds: [CefChromiumSurface] = []
        window.setCustomPresentation(for: .findBar) { finds.append($0) }
        let session = browser.findSession
        browser.execute(.find)
        session.text = "page"
        browser.execute(.find)
        check("surface states: ⌘F with the custom find bar open keeps it and its search",
              finds.count == 1 && finds[0].state == .presented && session.isActive && session.text == "page")
        session.end()
        check("surface states: ending the find session ends the custom find bar as .app",
              await waitUntil(timeout: .seconds(3)) { finds.first?.state == .dismissed(.app) && window.chromiumSurfaces.isEmpty })
        // Rapid toggling.
        for _ in 0..<10 {
            browser.execute(.find)
            browser.execute(CefChromeCommand(rawValue: Int(IDC_CLOSE_FIND_OR_STOP)))
            finds.last?.dismiss()
        }
        try? await Task.sleep(for: .milliseconds(300))
        check("surface states: toggling the find bar ten times leaves nothing behind",
              !session.isActive && window.chromiumSurfaces.isEmpty && finds.allSatisfy { $0.state != .presented }
                  && visibleWidgets(of: window).isEmpty,
              detail: "\(finds.count) bars, active \(session.isActive), \(window.chromiumSurfaces.count) listed")
        window.setCustomPresentation(for: .findBar, nil)

        // SwiftUI panel: keyboard focus returns to the window afterwards.
        window.setCustomPresentation(for: .qrCode) { _ in Text("QR").padding() }
        window.window?.makeKeyAndOrderFront(nil)
        browser.execute(.createQRCode)
        let panel = await waitUntil(timeout: .seconds(3)) { NSApp.keyWindow?.parent === window.window }
        let panelSurface = window.chromiumSurfaces.first { $0.kind == .qrCode }
        panelSurface?.dismiss()
        let keyAgain = await waitUntil(timeout: .seconds(3)) { window.window?.isKeyWindow == true }
        check("surface states: a SwiftUI panel takes focus and gives it back to the window on dismissal",
              panel && keyAgain,
              detail: "panel key \(panel), key \(NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) } ?? "nil")")
        window.setCustomPresentation(for: .qrCode, nil)
        await closeSurfaceWindow(window)
    }

    // MARK: Zoom and status

    static func zoomAndStatusChecks(base: URL) async {
        guard let window = await surfaceWindow(base) else {
            return check("surface states: zoom window loads", false)
        }
        let browser = window.browser
        var zooms: [CefChromiumSurface] = []
        window.setCustomPresentation(for: .zoom) { zooms.append($0) }
        let before = browser.zoomLevel
        // As key repeat sends them, a few milliseconds apart.
        for _ in 0..<5 {
            browser.execute(.zoomIn)
            try? await Task.sleep(for: .milliseconds(30))
        }
        check("surface states: a custom zoom bubble follows the zoom commands, which still zoom",
              await waitUntil(timeout: .seconds(3)) { browser.zoomLevel > before }
                  && zooms.count == 5 && zooms.filter { $0.state == .presented }.count == 1,
              detail: "level \(browser.zoomLevel), \(zooms.count) surfaces")
        try? await Task.sleep(for: .milliseconds(400))
        check("surface states: Chromium's zoom bubble stays hidden under a custom one", visibleWidgets(of: window).isEmpty,
              detail: "\(visibleWidgets(of: window).map { NSStringFromRect($0.frame) })")
        window.setCustomPresentation(for: .zoom, nil)
        window.chromiumSurfacePolicy[.zoom] = .hidden
        browser.execute(.resetZoom)
        check("surface states: a hidden zoom bubble still lets the command zoom",
              await waitUntil(timeout: .seconds(3)) { browser.zoomLevel == 0 })
        window.chromiumSurfacePolicy[.zoom] = .native

        // The custom status bubble follows statusText.
        var statuses: [CefChromiumSurface] = []
        window.onChromiumSurface = { if $0.kind == .statusBubble, $0.presentation == .custom { statuses.append($0) } }
        window.chromiumSurfacePolicy[.statusBubble] = .custom
        var shown = false
        for _ in 0..<5 where !shown {
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 1, "y": 1])
            let point = try? await browser.evaluateJavaScript(
                "(() => { const r = document.getElementById('link').getBoundingClientRect(); return [r.x + 4, r.y + 4]; })()")
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", [
                "type": "mouseMoved", "x": .number(point?[0].doubleValue ?? 0), "y": .number(point?[1].doubleValue ?? 0),
            ])
            shown = await waitUntil(timeout: .seconds(2)) { statuses.contains { $0.state == .presented } }
        }
        if !shown, window.window?.occlusionState.contains(.visible) == false {
            skip("surface states: a custom status bubble follows statusText",
                 because: "the test window is covered, so Chromium does not hover the page", .environment)
        } else {
            check("surface states: a custom status bubble appears with the status text",
                  shown && statuses.last?.title == browser.statusText, detail: "'\(browser.statusText)'")
            _ = try? await browser.devTools.send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 1, "y": 1])
            check("surface states: and ends as .chromium when the text goes",
                  await waitUntil(timeout: .seconds(3)) { statuses.last?.state == .dismissed(.chromium) },
                  detail: "'\(browser.statusText)' \(statuses.last.map { "\($0.state)" } ?? "-")")
        }
        window.chromiumSurfacePolicy[.statusBubble] = .native
        window.onChromiumSurface = nil
        await closeSurfaceWindow(window)
    }

    // MARK: Kinds from the inventory

    static func newKindChecks(base: URL) async {
        guard let window = await surfaceWindow(base, path: "surfaces") else {
            return check("surface states: surfaces page loads", false)
        }
        let browser = window.browser
        func gesture(_ script: String) async {
            _ = try? await browser.devTools.send(
                "Runtime.evaluate", ["expression": .string(script), "userGesture": true, "awaitPromise": false])
        }
        await gesture("navigator.usb.requestDevice({filters: []}).catch(() => {})")
        if let chooser = await nativeSurface(.deviceChooser, in: window) {
            check("surface kinds: the USB chooser is a device chooser that hangs from the toolbar",
                  chooser.kind.hangsFromToolbar && chooser.kind.capabilities.contains(.dismiss))
            chooser.dismiss()
            let closed = await waitUntil { chooser.window?.isVisible != true }
            let usable = await pageTakesInput(browser)
            check("surface kinds: dismissing the device chooser cancels it", closed && usable)
        } else {
            check("surface kinds: the USB chooser is recognized", false,
                  detail: "\(window.chromiumSurfaces.map { "\($0.kind)" })")
        }
        await gesture("""
            new PaymentRequest([{supportedMethods: 'https://127.0.0.1/pay'}], {total: {label: 'T', amount: {currency: 'USD', value: '1'}}}).show().catch(() => {})
            """)
        if let payment = await nativeSurface(.paymentRequest, in: window) {
            payment.dismiss()
            check("surface kinds: the payment sheet is recognized and dismisses",
                  await waitUntil { payment.window?.isVisible != true })
        } else {
            print("NOTE surface kinds: no payment sheet: \(window.chromiumSurfaces.map { "\($0.kind)" })")
        }
        browser.execute(.print)
        if let preview = await nativeSurface(.printPreview, in: window, timeout: .seconds(8)) {
            try? await Task.sleep(for: .seconds(1))
            preview.dismiss()
            let closed = await waitUntil { preview.window?.isVisible != true }
            let usable = await pageTakesInput(browser)
            check("surface kinds: print preview is recognized and dismisses, leaving the page usable", closed && usable,
                  detail: "closed \(closed), page takes input \(usable)")
        } else {
            check("surface kinds: print preview is recognized", false,
                  detail: "\(window.chromiumSurfaces.map { "\($0.kind) '\($0.title)'" })")
        }
        // Hiding a tab-modal dialog leaves the page usable.
        window.chromiumSurfacePolicy[.printPreview] = .hidden
        browser.execute(.print)
        try? await Task.sleep(for: .seconds(2))
        let usable = await pageTakesInput(browser)
        check("surface kinds: a hidden print preview is cancelled and the page takes input",
              visibleWidgets(of: window).isEmpty && usable,
              detail: "\(visibleWidgets(of: window).map(\.title))")
        await closeSurfaceWindow(window)
    }

    /// Whether the page answers a click: a tab-modal dialog left open
    /// would leave it inert.
    static func pageTakesInput(_ browser: CefBrowser) async -> Bool {
        _ = try? await browser.evaluateJavaScript("window.__clicked = false; document.addEventListener('click', () => window.__clicked = true, {once: true}); 0")
        for type in ["mousePressed", "mouseReleased"] {
            _ = try? await browser.devTools.send(
                "Input.dispatchMouseEvent", ["type": .string(type), "x": 850, "y": 600, "button": "left", "clickCount": 1])
        }
        return await waitUntilAsync(timeout: .seconds(3)) {
            (try? await browser.evaluateJavaScript("window.__clicked"))?.boolValue == true
        }
    }

    // MARK: Windows

    static func windowLifecycleChecks(base: URL) async {
        // Two windows keep their own presentations; an incognito one too.
        guard let first = await surfaceWindow(base),
              let second = await surfaceWindow(base, browserConfiguration: {
                  var configuration = CefBrowser.Configuration()
                  configuration.profile = .incognito()
                  return configuration
              }())
        else {
            return check("surface states: two windows load", false)
        }
        var presented: [CefChromiumSurface] = []
        first.setCustomPresentation(for: .qrCode) { presented.append($0) }
        second.browser.execute(.createQRCode)
        let native = await nativeSurface(.qrCode, in: second)
        check("surface states: a second (incognito) window keeps Chromium's QR code while the first replaces it",
              native != nil && presented.isEmpty && second.chromiumSurfacePolicy[.qrCode] == .native)

        // Closing the window ends its surfaces, and nothing is called after.
        first.browser.execute(.createQRCode)
        first.browser.execute(.find)
        _ = await waitUntil(timeout: .seconds(5)) { first.chromiumSurfaces.count == 2 }
        let open = first.chromiumSurfaces
        var calledAfterClose = false
        await closeSurfaceWindow(first)
        first.onChromiumSurface = { _ in calledAfterClose = true }
        first.browser.execute(.createQRCode)
        check("surface states: closing the window ends its surfaces as .window",
              open.count == 2 && open.allSatisfy { $0.state == .dismissed(.window) } && first.chromiumSurfaces.isEmpty,
              detail: "\(open.map { "\($0.kind) \($0.state)" })")
        check("surface states: nothing is announced after the window closed", !calledAfterClose)
        await closeSurfaceWindow(second)
        check("surface states: closing a window with Chromium's surface open ends it",
              native.map { $0.state != .presented } ?? false, detail: "\(native.map { "\($0.state)" } ?? "-")")

        // A surface asked for right as the window shows.
        let browser = CefBrowser(url: base.appendingPathComponent("page"))
        let early = CefWindow(browser: browser)
        early.chromiumSurfacePolicy = CefChromiumSurface.Policy()
        early.show()
        browser.execute(.createQRCode)
        _ = await loaded(browser)
        browser.execute(.createQRCode)
        check("surface states: a QR code asked for as the window first shows is followed",
              await nativeSurface(.qrCode, in: early) != nil)
        await closeSurfaceWindow(early)
    }
}
