import AppKit
import CefKit

/// `CefWindow.attach(to:)`: several Chrome-style tabs shown, one at a time,
/// in the page area of one app window.
extension SelfTest {
    static func attachedWindowChecks() async {
        func shellWindow(_ title: String, x: CGFloat) -> (NSWindow, NSView) {
            let shell = NSWindow(
                contentRect: NSRect(x: x, y: 160, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            shell.isReleasedWhenClosed = false
            shell.title = title
            let content = NSView()
            shell.contentView = content
            let pageArea = NSView(frame: content.bounds.insetBy(dx: 8, dy: 30).offsetBy(dx: 0, dy: -22))
            pageArea.autoresizingMask = [.width, .height]
            content.addSubview(pageArea)
            shell.makeKeyAndOrderFront(nil)
            return (shell, pageArea)
        }
        func tab(_ title: String, in pageArea: NSView) -> CefWindow {
            var configuration = CefWindow.Configuration()
            configuration.isFrameless = true
            let window = CefWindow(browser: CefBrowser(url: page(title)), configuration: configuration)
            window.attach(to: pageArea)
            return window
        }
        func screenFrame(of view: NSView) -> CGRect {
            view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } ?? .zero
        }

        NSApp.activate()
        let (shell, pageArea) = shellWindow("Attached", x: 160)
        let first = tab("first", in: pageArea), second = tab("second", in: pageArea)
        first.show()
        _ = await allLoaded([first.browser, second.browser])
        guard let a = first.window, let b = second.window else { return check("attached window: windows", false) }
        check("attached window: over its view, a shadowless child of the app window, out of the Window menu",
              a.frame == screenFrame(of: pageArea) && a.parent === shell && !a.hasShadow && a.isExcludedFromWindowsMenu
                  && !b.isVisible,
              detail: "\(NSStringFromRect(a.frame)) vs \(NSStringFromRect(screenFrame(of: pageArea))), parent \(a.parent?.title ?? "none"), shadow \(a.hasShadow)")
        let size = try? await first.browser.evaluateJavaScript("[innerWidth, innerHeight]")
        let filled = size?.arrayValue?.compactMap(\.doubleValue) == [Double(pageArea.bounds.width), Double(pageArea.bounds.height)]
        check("attached window: the page fills the view", filled, detail: "\(size.map { "\($0)" } ?? "?") in \(pageArea.bounds.size)")

        a.makeKeyAndOrderFront(nil)
        if await waitUntil(timeout: .seconds(3), { NSApp.isActive && a.isKeyWindow }) {
            let focus = await waitUntilAsync(timeout: .seconds(3)) {
                (try? await first.browser.evaluateJavaScript("document.hasFocus()").boolValue) == true
            }
            check("attached window: the page takes the keyboard while the app window stays main",
                  focus && shell.isMainWindow && !a.isMainWindow,
                  detail: "focus \(focus), shell main \(shell.isMainWindow), attached main \(a.isMainWindow)")
        } else {
            skip("attached window: the page takes the keyboard while the app window stays main",
                 because: "another app is active", .environment)
        }

        // Selecting the second tab: shown first, then the first hidden.
        second.show()
        first.hide()
        let swapped = await waitUntil(timeout: .seconds(5)) {
            first.browser.lifecycle == .hidden && second.browser.lifecycle != .hidden
        }
        check("attached window: switching tabs shows one and hides the other",
              swapped && b.parent === shell && b.frame == screenFrame(of: pageArea),
              detail: "\(first.browser.lifecycle) \(second.browser.lifecycle), parent \(b.parent?.title ?? "none"), "
                  + "visible \(b.isVisible), occlusion \(b.occlusionState.rawValue), key \(NSApp.keyWindow?.title ?? "-")")

        shell.setFrame(shell.frame.insetBy(dx: -40, dy: -30), display: true)
        _ = await waitUntil(timeout: .seconds(2)) { b.frame == screenFrame(of: pageArea) }
        check("attached window: follows its view as the app window resizes", b.frame == screenFrame(of: pageArea),
              detail: "\(NSStringFromRect(b.frame)) vs \(NSStringFromRect(screenFrame(of: pageArea)))")

        second.browser.execute(.find)
        let findBar = await waitUntil(timeout: .seconds(5)) {
            b.childWindows?.contains { $0.isVisible && b.frame.insetBy(dx: -2, dy: -2).contains($0.frame) } == true
        }
        check("attached window: Chromium's find bar opens over the tab shown", findBar,
              detail: "\(b.childWindows?.map { NSStringFromRect($0.frame) } ?? []) in \(NSStringFromRect(b.frame))")

        // Moving the tab to another app window keeps its browser and history.
        _ = try? await second.browser.load(page("second-later")).waitUntilLoaded(timeout: .seconds(10))
        let (other, otherArea) = shellWindow("Other", x: 260)
        second.attach(to: otherArea)
        second.show()
        let moved = await waitUntil(timeout: .seconds(3)) { b.parent === other && b.frame == screenFrame(of: otherArea) }
        check("attached window: moves to another app window with its history",
              moved && second.browser.canGoBack && second.browser.state == .live,
              detail: "parent \(b.parent?.title ?? "none"), back \(second.browser.canGoBack)")

        first.close()
        let closed = await waitUntil { first.isClosed && first.browser.state == .closed }
        let stillWorks = (try? await second.browser.evaluateJavaScript("1 + 1").intValue) == 2
        check("attached window: a hidden tab closes, the shown one carries on", closed && stillWorks)

        second.detach()
        check("attached window: detaching hides it and leaves the app window",
              await waitUntil(timeout: .seconds(2)) { !b.isVisible && b.parent == nil })
        second.close()
        _ = await waitUntil { second.isClosed }
        shell.close()
        other.close()
    }
}
