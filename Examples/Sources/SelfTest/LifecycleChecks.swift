import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Checks that `CefBrowser.lifecycle` and the page's own
/// `document.visibilityState` agree as windows are covered, minimized,
/// ordered out and tabbed, the app is hidden and views are hidden, in each
/// kind of host; and the energy saver's offscreen frame rate.
extension SelfTest {
    static func lifecycleChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        window.orderOut(nil)
        defer { window.orderFront(nil) }
        for host in BenchmarkHost.allCases {
            await lifecycleChecks(in: host)
        }
        await tabGroupChecks(.windowed)
        await tabGroupChecks(.chromeStyle)
        await energySaverChecks()
    }

    /// Whether the browser and its page agree that it is visible (or
    /// hidden), within a few seconds: Chromium notices covered windows
    /// with a delay.
    static func agree(_ browser: CefBrowser, visible: Bool) async -> (Bool, String) {
        var page = "?"
        let agreed = await waitUntilAsync(timeout: .seconds(6)) {
            page = (try? await browser.evaluateJavaScript("document.visibilityState").stringValue) ?? "?"
            return browser.lifecycle.isVisible == visible && page == (visible ? "visible" : "hidden")
        }
        return (agreed, "lifecycle \(browser.lifecycle), page \(page)")
    }

    static func lifecycleChecks(in host: BenchmarkHost) async {
        guard let hosted = await HostedBenchmarkBrowser(host, url: URL(string: "selftest://bench/animated.html")!) else {
            check("lifecycle \(host): opens", false)
            return
        }
        let browser = hosted.browser
        _ = await waitUntil { browser.title == "animated" }
        let name = "lifecycle \(host.rawValue)"
        func expectAgreement(_ step: String, visible: Bool) async {
            var (agreed, detail) = await agree(browser, visible: visible)
            // Another app's window over the test window (a screen-sharing
            // overlay, say) hides it for real; then both must say hidden.
            if !agreed, visible, !hosted.window.occlusionState.contains(.visible) {
                print("NOTE \(name): \(step): another window covers the test window")
                (agreed, detail) = await agree(browser, visible: false)
            }
            check("\(name): \(step) — \(visible ? "visible" : "hidden") to both", agreed, detail: detail)
        }
        await expectAgreement("shown", visible: true)

        let cover = NSWindow(
            contentRect: hosted.window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless],
            backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        cover.orderFrontRegardless()
        await expectAgreement("covered by a window", visible: false)
        cover.close()
        await expectAgreement("uncovered", visible: true)

        hosted.window.miniaturize(nil)
        await expectAgreement("minimized", visible: false)
        hosted.window.deminiaturize(nil)
        await expectAgreement("restored", visible: true)

        NSApp.hide(nil)
        await expectAgreement("app hidden", visible: false)
        NSApp.unhide(nil)
        hosted.window.orderFrontRegardless()
        await expectAgreement("app shown", visible: true)

        if host != .chromeStyle {
            hosted.window.orderOut(nil)
            await expectAgreement("window ordered out", visible: false)
            hosted.window.orderFrontRegardless()
            await expectAgreement("window ordered in", visible: true)
            let view = hosted.window.contentView?.subviews.first
            view?.isHidden = true
            await expectAgreement("view hidden", visible: false)
            view?.isHidden = false
            await expectAgreement("view shown", visible: true)
        }

        if host != .offscreen {
            // Focus: active exactly when the page has focus.
            hosted.window.makeKeyAndOrderFront(nil)
            if host == .windowed, let native = browser.nativeView { hosted.window.makeFirstResponder(native) }
            var detail = ""
            let consistent = await waitUntilAsync(timeout: .seconds(3)) {
                let focus = (try? await browser.evaluateJavaScript("document.hasFocus()").boolValue) ?? nil
                detail = "lifecycle \(browser.lifecycle), hasFocus \(focus.map(String.init) ?? "?"), app active \(NSApp.isActive)"
                return focus == (browser.lifecycle == .active)
            }
            check("\(name): active exactly when the page has focus", consistent, detail: detail)
        }
        await hosted.close()
        check("\(name): a closed browser is hidden", browser.lifecycle == .hidden, detail: "\(browser.lifecycle)")
    }

    /// Two browsers as tabs of one native tab group: only the selected
    /// tab is visible.
    static func tabGroupChecks(_ host: BenchmarkHost) async {
        guard let first = await HostedBenchmarkBrowser(host, url: URL(string: "selftest://bench/animated.html")!),
              let second = await HostedBenchmarkBrowser(host, url: URL(string: "selftest://bench/animated.html")!)
        else {
            check("lifecycle \(host.rawValue) tabs: open", false)
            return
        }
        _ = await waitUntil { first.browser.title == "animated" && second.browser.title == "animated" }
        first.window.addTabbedWindow(second.window, ordered: .above)
        second.window.makeKeyAndOrderFront(nil)
        // The selected tab is visible unless another app's window covers it.
        func selected(_ hosted: HostedBenchmarkBrowser) async -> (Bool, String) {
            let result = await agree(hosted.browser, visible: true)
            guard !result.0, !hosted.window.occlusionState.contains(.visible) else { return result }
            print("NOTE lifecycle \(host.rawValue) tabs: another window covers the test window")
            return await agree(hosted.browser, visible: false)
        }
        let (firstHidden, detail1) = await agree(first.browser, visible: false)
        let (secondVisible, detail2) = await selected(second)
        check("lifecycle \(host.rawValue) tabs: the tab not selected is hidden to both, the selected one visible",
              firstHidden && secondVisible, detail: "\(detail1); \(detail2)")
        first.window.tabGroup?.selectedWindow = first.window
        let (firstVisible, detail3) = await selected(first)
        let (secondHidden, detail4) = await agree(second.browser, visible: false)
        check("lifecycle \(host.rawValue) tabs: switching tabs swaps them", firstVisible && secondHidden,
              detail: "\(detail3); \(detail4)")
        await second.close()
        await first.close()
    }

    /// Animation frames a second in an offscreen page.
    static func animationFrameRate(_ browser: CefBrowser) async -> Int {
        (try? await browser.evaluateJavaScript("""
            new Promise(resolve => {
              let frames = 0; const start = performance.now();
              const tick = () => { frames++; performance.now() - start < 1000 ? requestAnimationFrame(tick) : resolve(frames); };
              requestAnimationFrame(tick);
            })
            """).intValue) ?? 0
    }

    static func energySaverChecks() async {
        guard let hosted = await HostedBenchmarkBrowser(.offscreen, url: URL(string: "selftest://bench/animated.html")!) else { return }
        _ = await waitUntil { hosted.browser.title == "animated" }
        try? await Task.sleep(for: .milliseconds(500))
        let browser = hosted.browser
        /// The rate Chromium was told, and the page's animation frames in
        /// each of three seconds.
        func sample() async -> String {
            try? await Task.sleep(for: .milliseconds(300))
            var rates: [Int] = []
            for _ in 0..<3 { rates.append(await animationFrameRate(browser)) }
            return "\(browser.currentOffscreenFrameRate ?? -1) \(rates)"
        }
        let normal = await sample()
        CefRuntime.shared.simulateEnergyConditions(lowPowerMode: true, thermalState: .nominal)
        let lowPower = await sample()
        hosted.window.contentView?.subviews.first?.isHidden = true
        try? await Task.sleep(for: .milliseconds(300))
        hosted.window.contentView?.subviews.first?.isHidden = false
        let shownAgain = await sample()
        CefRuntime.shared.simulateEnergyConditions(lowPowerMode: false, thermalState: .serious)
        let hot = await sample()
        CefRuntime.shared.energySaver = .off
        let off = await sample()
        CefRuntime.shared.energySaver = .automatic
        CefRuntime.shared.stopSimulatingEnergyConditions()
        let back = await sample()
        // On battery with Low Power Mode on, the Mac itself constrains energy.
        let unsimulated = ProcessInfo.processInfo.isLowPowerModeEnabled
            || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) ? 30 : 60
        func rate(_ sample: String) -> Int { Int(sample.split(separator: " ")[0]) ?? -1 }
        func median(_ values: [Int]) -> Int { values.isEmpty ? .max : values.sorted()[values.count / 2] }
        func frames(_ sample: String) -> [Int] {
            sample.drop { $0 != "[" }.dropFirst().dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        check("energy saver: offscreen frame rate drops to 30 in Low Power Mode and under thermal pressure, and comes back",
              rate(normal) == unsimulated && rate(lowPower) == 30 && rate(hot) == 30 && rate(off) == 60
                  && rate(back) == unsimulated
                  && median(frames(lowPower)) <= 35 && median(frames(hot)) <= 35
                  && median(frames(shownAgain)) <= 35,
              detail: "rate and frames: normal \(normal), low power \(lowPower), hidden and shown \(shownAgain), serious thermal \(hot), saver off \(off), after \(back)")
        print("NOTE energy saver: normal \(normal), low power \(lowPower), hidden and shown \(shownAgain), serious thermal \(hot), saver off \(off), after \(back)")
        await hosted.close()
    }
}
