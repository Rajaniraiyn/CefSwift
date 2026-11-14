import AppKit
import CefChromium
import CefSwiftUI

/// An extension's action popup, shown under its toolbar button.
///
/// Chromium opens action popups only in windows with Chrome's own toolbar,
/// and this browser's tabs have a SwiftUI one; so the popup's page
/// (`default_popup`) is shown in a borderless Chrome-style window of its
/// own, sized to the page, and closed when it loses focus or the button is
/// clicked again, as Chrome's popups are. The page runs with the
/// extension's APIs; the differences from Chrome's popup: its "current
/// window" (`chrome.tabs.query({currentWindow: true})`) is the popup's own
/// window, not the tab's, and the click grants no `activeTab` permission.
/// An action without a popup has its click handler run by Chromium only
/// from Chrome's toolbar, so its button opens the extension's options or
/// details instead.
@MainActor
enum ExtensionPopup {
    private static var current: (id: CefExtension.ID, window: CefWindow)?
    private static var resignObserver: NSObjectProtocol?

    static func toggle(for item: CefExtension, from anchor: NSView, in browser: CefBrowser) {
        if let current {
            let wasSame = current.id == item.id
            close()
            if wasSame { return }
        }
        guard let url = item.action?.popupURL else {
            let fallback = item.optionsURL ?? ExtensionLinks.details(item.id)
            _ = browser.load(fallback)
            return
        }
        var configuration = CefBrowser.Configuration()
        configuration.profile = browser.configuration.profile
        let popupBrowser = CefBrowser(url: url, configuration: configuration)
        var windowConfiguration = CefWindow.Configuration()
        windowConfiguration.isFrameless = true
        windowConfiguration.titleFollowsPage = false
        let size = CGSize(width: 320, height: 240)
        windowConfiguration.frame = frame(of: size, under: anchor)
        let window = CefWindow(browser: popupBrowser, configuration: windowConfiguration)
        window.contentCornerRadius = 10
        window.onClose = { if current?.window === window { current = nil } }
        current = (item.id, window)
        window.show()
        window.withWindow { nsWindow in
            nsWindow.level = .popUpMenu
            nsWindow.hasShadow = true
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nsWindow, queue: .main
            ) { _ in MainActor.assumeIsolated { close() } }
        }
        Task { await fit(window, browser: popupBrowser, under: anchor) }
    }

    static func close() {
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = nil
        current?.window.close()
        current = nil
    }

    /// Sizes the window to the popup's page, within Chrome's limits for
    /// popups (25 × 25 to 800 × 600 points).
    private static func fit(_ window: CefWindow, browser: CefBrowser, under anchor: NSView) async {
        guard (try? await browser.waitUntilLoaded(timeout: .seconds(5))) != nil,
              let size = try? await browser.evaluateJavaScript(
                  "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"),
              let width = size[0].doubleValue, let height = size[1].doubleValue
        else { return }
        let fitted = CGSize(width: min(max(width, 25), 800), height: min(max(height, 25), 600))
        window.window?.setFrame(frame(of: fitted, under: anchor), display: true, animate: false)
    }

    /// Below `anchor`, its trailing edge at the anchor's, on screen.
    private static func frame(of size: CGSize, under anchor: NSView) -> CGRect {
        guard let window = anchor.window else { return CGRect(origin: .zero, size: size) }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 4)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = max(origin.y, screen.minY)
        }
        return CGRect(origin: origin, size: size)
    }
}
