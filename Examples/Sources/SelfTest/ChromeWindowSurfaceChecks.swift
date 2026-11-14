import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import SwiftUI

/// Chromium's surfaces in a `CefChromeWindow`: the same policy, anchors and
/// custom presentations as in a `CefWindow`, per tab, and the kinds only
/// a tabbed window has.
extension SelfTest {
    static func chromeWindowSurfaceChecks() async {
        guard let server = try? await LocalServer.start() else {
            return skip("chrome window surfaces", because: "could not start a local HTTP server", .environment)
        }
        defer { server.stop() }
        // On http: Chrome's QR code generator takes no data: page.
        func url(_ name: String) -> URL { URL(string: "http://127.0.0.1:\(server.port)/page?\(name)")! }
        let window: CefChromeWindow
        do {
            window = try await CefChromeWindow.open(url: url("one"), frame: CGRect(x: 120, y: 120, width: 1000, height: 760))
        } catch {
            return check("chrome window surfaces: opens a window", false, detail: "\(error)")
        }
        _ = await waitUntil(timeout: .seconds(10)) { window.window != nil && window.activeTab?.browser != nil }
        window.showsChromeUI = false
        window.setTopBar { Text("Top bar").frame(maxWidth: .infinity, maxHeight: .infinity) }
        _ = await waitUntil(timeout: .seconds(2)) { window.topBarHeight > 0 }
        window.window?.makeKeyAndOrderFront(nil)
        var seen: [CefChromiumSurface] = []
        window.onChromiumSurface = { seen.append($0) }

        // Chromium's own QR code bubble, under the app's top bar.
        guard let first = window.activeTab?.browser else { return check("chrome window surfaces: has a browser", false) }
        _ = try? await first.waitUntilLoaded(timeout: .seconds(10))
        first.execute(.createQRCode)
        let native = await waitUntil(timeout: .seconds(5)) { window.chromiumSurfaces.contains { $0.kind == .qrCode && $0.window != nil } }
        let qr = window.chromiumSurfaces.first { $0.kind == .qrCode }
        let pageTop = (window.window?.contentView).map { $0.frame.maxY - window.contentFrame.minY } ?? 0
        let qrTop = qr?.window.flatMap { child in window.window.map { child.frame.maxY - $0.frame.minY } } ?? 0
        check("chrome window surfaces: Chromium's QR code bubble is a surface of the window, under the app's top bar",
              native && qr?.browser === first && qr?.chromeWindow === window && qrTop <= pageTop + 1 && qrTop > pageTop - 40,
              detail: "native \(native) kinds \(window.chromiumSurfaces.map { "\($0.kind)" }) top \(qrTop) page top \(pageTop) children \(childDescriptions(window)) hooks \(CefTesting.runtimeHookFeatures.filter { $0.name.contains("surfaces") })")
        qr?.dismiss()
        _ = await waitUntil(timeout: .seconds(3)) { qr?.window?.isVisible != true }

        // The app's own QR code panel instead, per tab.
        var presented: [CefChromiumSurface] = []
        window.setCustomPresentation(for: .qrCode) { presented.append($0) }
        first.execute(.createQRCode)
        check("chrome window surfaces: a custom presentation gets the command, for the active tab",
              await waitUntil(timeout: .seconds(3)) { presented.count == 1 } && presented.first?.browser === first
                && presented.first?.state == .presented,
              detail: "presented \(presented.count)")

        // A custom find bar along the top of the page, per tab.
        window.setFindBar { session in TextField("Find", text: Bindable(session).text).accessibilityIdentifier("selftest-find") }
        first.execute(.find)
        let bar = window.pageBar
        check("chrome window surfaces: the custom find bar shows for the active tab's find session",
              await waitUntil(timeout: .seconds(3)) { bar?.isHidden == false && first.findSession.isActive }
                && window.chromiumSurfaces.contains { $0.kind == .findBar && $0.window == nil && $0.browser === first },
              detail: "bar \(bar.map { "\($0.isHidden)" } ?? "none") session \(first.findSession.isActive)")

        // Switching tabs: the QR panel about the first tab is dismissed, the
        // find bar hides with its search kept, and comes back.
        await expect("chrome window surfaces: switching tabs dismisses the tab's bubbles and keeps its find bar") {
            let second = try await window.openTab(url("two"))
            let switched = await waitUntil(timeout: .seconds(5)) { second.isActive && window.activeTab?.browser != nil }
            let qrDismissed = await waitUntil(timeout: .seconds(3)) { presented.first?.state == .dismissed(.chromium) }
            let barHidden = await waitUntil(timeout: .seconds(3)) { bar?.isHidden == true }
            guard let firstTab = window.tabs.first(where: { $0.browser === first }) else { return (false, "no first tab") }
            try await firstTab.select()
            let barBack = await waitUntil(timeout: .seconds(3)) { bar?.isHidden == false }
            let kept = first.findSession.isActive
            return (switched && qrDismissed && barHidden && barBack && kept,
                    "switched \(switched) qr \(qrDismissed) hidden \(barHidden) back \(barBack) kept \(kept)")
        }
        first.findSession.end()
        window.setCustomPresentation(for: .qrCode, nil)

        // Tab search and the group editor: tabbed windows' own kinds.
        first.execute(.searchTabs)
        let searched = await waitUntil(timeout: .seconds(5)) { seen.contains { $0.kind == .tabSearch } }
        check("chrome window surfaces: tab search is recognized", searched,
              detail: "seen \(seen.map { "\($0.kind) '\($0.title)'" }) \(childDescriptions(window))")
        window.chromiumSurfaces.filter { $0.kind == .tabSearch }.forEach { $0.dismiss() }
        try? await Task.sleep(for: .milliseconds(300))
        first.execute(.createTabGroup)
        let editor = await waitUntil(timeout: .seconds(5)) { seen.contains { $0.kind == .tabGroupEditor } }
        check("chrome window surfaces: the tab group editor is recognized", editor,
              detail: "seen \(seen.map { "\($0.kind) '\($0.title)'" }) \(childDescriptions(window))")
        window.chromiumSurfaces.filter { $0.kind == .tabGroupEditor }.forEach { $0.dismiss() }

        window.close()
        _ = await waitUntil(timeout: .seconds(10)) { window.isClosed }
        for browser in CefRuntime.shared.browsers { browser.close(force: true) }
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
    }

    private static func childDescriptions(_ window: CefChromeWindow) -> String {
        (window.window?.childWindows ?? []).map { child in
            let described = CefChromiumTesting.describe(child)
            return "\(described.kind ?? "-") '\(described.title)' \(described.classes.prefix(10))"
        }.joined(separator: "; ")
    }
}
