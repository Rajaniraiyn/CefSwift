import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Checks of offscreen frame timing: Chromium's timer paints at the frame
/// rate, a hidden browser paints nothing, and a frame rate change applies
/// at once.
extension SelfTest {
    static func frameChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefRuntime.shared.energySaver = .off
        defer { CefRuntime.shared.energySaver = .automatic }
        let frameWindow = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 640, height: 480), styleMask: [.titled],
            backing: .buffered, defer: false)
        frameWindow.isReleasedWhenClosed = false
        frameWindow.level = .floating
        let probe = FrameProbeView(frame: frameWindow.contentView!.bounds)
        frameWindow.contentView!.addSubview(probe)
        frameWindow.orderFrontRegardless()

        var options = CefBrowserOptions()
        options.rendering = .offscreen(frameRate: 60)
        let browser = CefBrowser(url: URL(string: "selftest://bench/animated.html")!, options: options)
        browser.host(offscreenIn: probe, size: probe.bounds.size)
        browser.hostViewDidUnhide()
        _ = await waitUntil { browser.title == "animated" }
        try? await Task.sleep(for: .milliseconds(500))

        func paintsPerSecond() async -> Int {
            let before = probe.paints.count
            try? await Task.sleep(for: .seconds(1))
            return probe.paints.count - before
        }
        let visible = await paintsPerSecond()
        check("frames: an animated offscreen page paints at its frame rate", visible >= 40, detail: "\(visible) a second")
        browser.setOffscreenFrameRate(20)
        try? await Task.sleep(for: .milliseconds(200))
        let slow = await paintsPerSecond()
        check("frames: a lower frame rate applies at once", (15...25).contains(slow), detail: "\(slow) a second")
        browser.hostViewDidHide()
        try? await Task.sleep(for: .milliseconds(300))
        let hidden = await paintsPerSecond()
        check("frames: a hidden offscreen browser paints nothing", hidden == 0, detail: "\(hidden) a second")
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        frameWindow.close()
    }
}
