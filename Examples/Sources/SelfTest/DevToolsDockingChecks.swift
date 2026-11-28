import AppKit
@_spi(Testing) import CefKit

/// Docked DevTools in a ``CefWindow`` (`devToolsPlacement`, experimental
/// and off by default; see the `TODO(upstream)` in
/// `CefWindow+DevTools.swift`). By default DevTools opens in a window of
/// its own. Docked, it opens in the page's window, beside the page: the
/// `devToolsDocking` probe checks that in a process of its own and leaves
/// without closing DevTools, which stops the app on CEF 158.0.6.
extension SelfTest {
    static func devToolsDockingChecks() async {
        await devToolsDefaultPlacementCheck()
        await runProbe("devToolsDocking", label: "devTools docked", timeout: .seconds(60))
    }

    private static func devToolsTestWindow(_ url: URL) async -> (CefWindow, CefPage) {
        let page = CefPage(url: url)
        var configuration = CefWindow.Configuration()
        configuration.frame = CGRect(x: 120, y: 120, width: 1000, height: 760)
        let window = CefWindow(page: page, configuration: configuration)
        window.show()
        _ = await loaded(page)
        return (window, page)
    }

    /// Windows on screen other than SelfTest's own and `window`'s.
    private static func otherVisibleWindows(than window: CefWindow) -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0 !== window.window && $0 !== SelfTest.window }
    }

    private static func devToolsDefaultPlacementCheck() async {
        guard let server = try? await LocalServer.start() else { return check("local server starts", false) }
        defer { server.stop() }
        let (window, page) = await devToolsTestWindow(URL(string: "http://127.0.0.1:\(server.port)/page")!)
        check("devTools: docking is off by default", window.devToolsPlacement == .automatic)
        let othersBefore = otherVisibleWindows(than: window).count
        page.showDevTools()
        let opened = await waitUntil(timeout: .seconds(10)) {
            page.isShowingDevTools && otherVisibleWindows(than: window).count > othersBefore
        }
        check("devTools: DevTools opens in a window of its own by default",
              opened && window.dockedDevToolsEdge == nil,
              detail: "showing \(page.isShowingDevTools), windows \(otherVisibleWindows(than: window).count - othersBefore)")
        page.closeDevTools()
        check("devTools: DevTools in its own window closes",
              await waitUntil(timeout: .seconds(10)) { !page.isShowingDevTools })
        window.close()
        _ = await waitUntil { window.isClosed && page.state == .closed }
    }

    /// The `devToolsDocking` probe: DevTools docked at the bottom of a
    /// window, then a hard exit, since closing it or the window stops the
    /// app.
    static func devToolsDockingProbe() async {
        guard let server = try? await LocalServer.start() else { return check("local server starts", false) }
        let (window, page) = await devToolsTestWindow(URL(string: "http://127.0.0.1:\(server.port)/page")!)
        let before = window.pageViewBounds ?? .zero
        let othersBefore = otherVisibleWindows(than: window).count
        window.devToolsPlacement = .docked(.bottom, size: 300)
        page.showDevTools()
        let docked = await waitUntil(timeout: .seconds(10)) {
            page.isShowingDevTools && (window.dockedDevToolsBounds?.height ?? 0) > 0
        }
        let devTools = window.dockedDevToolsBounds ?? .zero
        let pageBounds = window.pageViewBounds ?? .zero
        let detail = "page \(before) → \(pageBounds), devtools \(devTools)"
        check("DevTools opens in the page's window", docked && window.dockedDevToolsEdge == .bottom, detail: detail)
        check("DevTools takes 300 points below the page",
              devTools.height == 300 && devTools.width == before.width && devTools.minY == pageBounds.maxY
                  && pageBounds.height == before.height - 300,
              detail: detail)
        check("no DevTools window opens", otherVisibleWindows(than: window).count == othersBefore,
              detail: otherVisibleWindows(than: window).map(\.title).description)
        check("the DevTools frontend loads",
              await waitUntil(timeout: .seconds(10)) { window.dockedDevToolsURL?.hasPrefix("devtools://devtools/") == true },
              detail: window.dockedDevToolsURL ?? "none")
        skip("closing docked DevTools", because: "closing, hiding or removing it stops the app at a Chromium check "
             + "(CEF 158.0.6; TODO(upstream) in CefWindow+DevTools.swift)", .limitation)
        server.stop()
        // Quitting closes the window, and the window cannot close with
        // DevTools docked in it: leave at once.
        fflush(stdout)
        exit(0)
    }
}
