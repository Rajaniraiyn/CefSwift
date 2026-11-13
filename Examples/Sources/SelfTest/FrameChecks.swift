import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Checks of offscreen frame timing: Chromium's timer paints at the frame
/// rate, a hidden browser paints nothing, and a frame rate change applies
/// at once.
extension SelfTest {
    static func frameChecks() async {
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = .automatic }
        let frameWindow = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 640, height: 480), styleMask: [.titled],
            backing: .buffered, defer: false)
        frameWindow.isReleasedWhenClosed = false
        frameWindow.level = .floating
        let probe = FrameProbeView(frame: frameWindow.contentView!.bounds)
        frameWindow.contentView!.addSubview(probe)
        frameWindow.orderFrontRegardless()

        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen(frameRate: 60)
        let browser = CefBrowser(url: URL(string: "selftest://bench/animated.html")!, configuration: configuration)
        browser.host(offscreenIn: probe, size: probe.bounds.size)
        browser.hostViewDidUnhide()
        _ = await waitUntil { browser.title == "animated" }
        try? await Task.sleep(for: .milliseconds(500))

        func paintsPerSecond() async -> Int {
            let before = probe.paints.count
            try? await Task.sleep(for: .seconds(1))
            return probe.paints.count - before
        }
        // In Low Power Mode macOS slows Chromium's timers, and a virtual
        // machine's display has no steady refresh, so a rate that is off
        // then says nothing about CefSwift.
        func rateCheck(_ name: String, _ passed: Bool, _ rate: Int) {
            if !passed, let reason = SelfTestReport.unsteadyFrameRateReason {
                skip(name, because: "\(rate) a second; \(reason)", .environment)
            } else {
                check(name, passed, detail: "\(rate) a second")
            }
        }
        let visible = await paintsPerSecond()
        rateCheck("frames: an animated offscreen page paints at its frame rate", visible >= 40, visible)
        browser.setOffscreenFrameRate(20)
        try? await Task.sleep(for: .milliseconds(200))
        let slow = await paintsPerSecond()
        rateCheck("frames: a lower frame rate applies at once", (15...25).contains(slow), slow)
        browser.hostViewDidHide()
        try? await Task.sleep(for: .milliseconds(300))
        let hidden = await paintsPerSecond()
        check("frames: a hidden offscreen browser paints nothing", hidden == 0, detail: "\(hidden) a second")
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        frameWindow.close()
    }
}
