import AppKit
import CefKit
import CefSwiftUI
import Darwin

/// Hosts the lifecycle and frame benchmarks compare.
enum BenchmarkHost: String, CaseIterable {
    case windowed, chromeStyle, offscreen
}

/// A browser shown in one kind of host, in a window of its own.
@MainActor
final class HostedBenchmarkBrowser {
    let browser: CefBrowser
    let window: NSWindow
    private var browserWindow: CefBrowserWindow?

    init?(_ host: BenchmarkHost, url: URL, frame: CGRect = CGRect(x: 200, y: 200, width: 640, height: 480)) async {
        var options = CefBrowserOptions()
        switch host {
        case .windowed, .chromeStyle:
            browser = CefBrowser(url: url, options: options)
        case .offscreen:
            options.rendering = .offscreen
            browser = CefBrowser(url: url, options: options)
        }
        switch host {
        case .chromeStyle:
            var configuration = CefBrowserWindow.Configuration()
            configuration.frame = frame
            let browserWindow = CefBrowserWindow(browser: browser, configuration: configuration)
            self.browserWindow = browserWindow
            guard await SelfTest.waitUntil({ browserWindow.window != nil }), let window = browserWindow.window else { return nil }
            self.window = window; window.level = .floating
        case .windowed, .offscreen:
            window = NSWindow(
                contentRect: frame, styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .floating
            let view: NSView
            if host == .windowed {
                let windowed = CefWindowedBrowserView()
                windowed.browser = browser
                view = windowed
            } else {
                let offscreen = CefOffscreenBrowserView()
                offscreen.browser = browser
                view = offscreen
            }
            view.frame = window.contentView!.bounds
            view.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(view)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() async {
        browser.close(force: true)
        _ = await SelfTest.waitUntil { browser.state == .closed }
        if browserWindow == nil { window.close() }
        _ = await SelfTest.waitUntil { CefBrowserWindow.all.isEmpty }
    }
}

/// CPU time of this process and its helpers.
enum ProcessCPU {
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Seconds of CPU time used so far, by process identifier.
    static func sample() -> [pid_t: Double] {
        var pids = [getpid()]
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.size))
        if count > 0 { pids += children.prefix(Int(count)) }
        var result: [pid_t: Double] = [:]
        for pid in pids where pid > 0 {
            var info = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if status == 0 { result[pid] = Double(info.ri_user_time + info.ri_system_time) * timebase / 1e9 }
        }
        return result
    }

    /// CPU seconds used between two samples, and the app's own share.
    static func used(from start: [pid_t: Double], to end: [pid_t: Double]) -> (total: Double, app: Double) {
        let total = end.reduce(0.0) { $0 + max($1.value - (start[$1.key] ?? 0), 0) }
        return (total, (end[getpid()] ?? 0) - (start[getpid()] ?? 0))
    }
}

extension Benchmarks {
    /// `lifecycle`: CPU use of an animated page in each host while it is
    /// visible, covered by another window, minimized and while the app is
    /// hidden, with what the page reports.
    static func lifecycleCPU() async {
        SelfTest.window.orderOut(nil)
        let interval = 4.0
        for host in BenchmarkHost.allCases {
            guard let hosted = await HostedBenchmarkBrowser(host, url: URL(string: "selftest://bench/animated.html")!) else {
                print("bench error: \(host) did not open")
                continue
            }
            _ = await SelfTest.waitUntil { hosted.browser.title == "animated" }
            let cover = NSWindow(
                contentRect: hosted.window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless],
                backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.backgroundColor = .gray
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

            let states: [(String, enter: @MainActor () -> Void, leave: @MainActor () -> Void)] = [
                ("visible", { hosted.window.makeKeyAndOrderFront(nil) }, {}),
                ("occluded", { cover.orderFrontRegardless() }, { cover.orderOut(nil) }),
                ("minimized", { hosted.window.miniaturize(nil) }, { hosted.window.deminiaturize(nil) }),
                ("app hidden", { NSApp.hide(nil) }, { NSApp.unhide(nil); hosted.window.makeKeyAndOrderFront(nil) }),
            ]
            for (name, enter, leave) in states {
                enter()
                try? await Task.sleep(for: .seconds(1.5))
                _ = try? await hosted.browser.evaluateJavaScript("window.__raf = 0")
                let start = ProcessCPU.sample()
                try? await Task.sleep(for: .seconds(interval))
                let end = ProcessCPU.sample()
                let page = try? await hosted.browser.evaluateJavaScript("[document.visibilityState, window.__raf, document.hasFocus()]")
                let used = ProcessCPU.used(from: start, to: end)
                print(String(
                    format: "bench lifecycle %@ %@: CPU %.1f%% (app %.1f%%), page %@, rAF %.0f/s, focus %@",
                    host.rawValue, name, used.total / interval * 100, used.app / interval * 100,
                    page?[0].stringValue ?? "?", (page?[1].doubleValue ?? 0) / interval,
                    page?[2].boolValue == true ? "yes" : "no"))
                leave()
                try? await Task.sleep(for: .seconds(1.5))
            }
            cover.close()
            await hosted.close()
        }
        SelfTest.window.orderFront(nil)
    }

    /// `frames`: an offscreen page's animation frames (rate and the spread
    /// of their intervals), the spread of the intervals between painted
    /// frames, how soon a mouse move reaches a painted frame, and CPU use.
    static func frames() async {
        SelfTest.window.orderOut(nil)
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 640, height: 480), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating
        let probe = FrameProbeView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(probe)
        window.makeKeyAndOrderFront(nil)
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        print("bench frames display \(fps) Hz")

        var options = CefBrowserOptions()
        options.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "selftest://bench/frames.html")!, options: options)
        browser.host(offscreenIn: probe, size: probe.bounds.size)
        browser.hostViewDidUnhide()
        _ = await SelfTest.waitUntil { browser.title == "frames" }
        try? await Task.sleep(for: .seconds(1))

        for run in 1...3 {
            // Animation frames for 3 s.
            probe.paints = []
            let start = ProcessCPU.sample()
            let page = try? await browser.evaluateJavaScript("""
                new Promise(resolve => {
                  const times = []; const tick = t => { times.push(t); times.length < 2 || t - times[0] < 3000 ? requestAnimationFrame(tick) : resolve(times); };
                  window.__animate = true; requestAnimationFrame(tick);
                })
                """)
            let end = ProcessCPU.sample()
            _ = try? await browser.evaluateJavaScript("window.__animate = false")
            let rafTimes = page?.arrayValue?.compactMap(\.doubleValue) ?? []
            let rafIntervals = zip(rafTimes.dropFirst(), rafTimes).map { $0 - $1 }
            let paintIntervals = zip(probe.paints.dropFirst(), probe.paints).map { ($0 - $1) * 1000 }
            let seconds = (rafTimes.last ?? 0) - (rafTimes.first ?? 0)
            let used = ProcessCPU.used(from: start, to: end)

            // Mouse moves to a painted frame, with nothing else animating.
            try? await Task.sleep(for: .milliseconds(300))
            var latencies: [Double] = []
            for index in 0..<40 {
                let paintsBefore = probe.paints.count
                let sent = CACurrentMediaTime()
                browser.sendMouseMove(to: CGPoint(x: 20 + index * 13, y: 40 + (index % 7) * 30), modifiers: [])
                _ = await SelfTest.waitUntil(timeout: .milliseconds(500)) { probe.paints.count > paintsBefore }
                if probe.paints.count > paintsBefore { latencies.append((probe.paints[paintsBefore] - sent) * 1000) }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 40...90)))
            }
            latencies.sort()
            print(String(
                format: "bench frames run %d: rAF %.1f/s (interval sd %.2f ms), paints %.1f/s (interval sd %.2f ms), CPU %.1f%%; mouse to paint median %.1f ms, p90 %.1f ms (%d of 40)",
                run, Double(max(rafTimes.count - 1, 0)) / max(seconds / 1000, 0.001), standardDeviation(rafIntervals),
                Double(paintIntervals.count) / max(seconds / 1000, 0.001), standardDeviation(paintIntervals),
                used.total / max(seconds / 1000, 0.001) * 100,
                latencies.isEmpty ? 0 : latencies[latencies.count / 2],
                latencies.isEmpty ? 0 : latencies[latencies.count * 9 / 10], latencies.count))
        }
        browser.close(force: true)
        _ = await SelfTest.waitUntil { browser.state == .closed }
        window.close()
        SelfTest.window.orderFront(nil)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
    }
}

/// An offscreen host that shows frames and records when each arrives.
@MainActor
final class FrameProbeView: NSView, CefOffscreenHost {
    var paints: [CFTimeInterval] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var offscreenViewInfo: CefOffscreenViewInfo {
        CefOffscreenViewInfo(size: bounds.size, deviceScaleFactor: window?.backingScaleFactor ?? 2)
    }

    func offscreenDidPaint(_ frame: CefOffscreenFrame, element: CefOffscreenPaintElement) {
        guard element == .view, case let .accelerated(surface, _) = frame else { return }
        paints.append(CACurrentMediaTime())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    func offscreenDidChangeCursor(_ cursor: CefCursorType) {}
    func offscreenPopupDidChangeVisibility(_ visible: Bool) {}
    func offscreenPopupDidResize(_ rect: CGRect) {}
    func offscreenDidChangeCompositionRange(_ range: NSRange, characterBounds: [CGRect]) {}
    func offscreenDidChangeSelection(_ selectedText: String, selectedRange: NSRange) {}
    func offscreenShowContextMenu(_ menu: CefMenuModel, at point: CGPoint, completion: CefContextMenuCompletion) {}
}

extension BenchmarkPages {
    static let animatedPage = """
        <title>animated</title>
        <style>
          body { margin: 0; background: #fff; }
          .box { position: absolute; width: 80px; height: 80px; background: #36c; animation: spin 1s linear infinite; }
          @keyframes spin { to { transform: translateX(400px) rotate(360deg); } }
        </style>
        <div class="box" style="top: 20px"></div><div class="box" style="top: 140px; animation-duration: 0.7s"></div>
        <canvas id="c" width="600" height="200" style="position: absolute; top: 260px"></canvas>
        <script>
          window.__raf = 0;
          const c = document.getElementById('c').getContext('2d');
          const draw = t => {
            window.__raf++;
            c.clearRect(0, 0, 600, 200);
            for (let i = 0; i < 200; i++) { c.fillStyle = `hsl(${(t / 5 + i * 7) % 360} 70% 50%)`; c.fillRect((i * 37 + t / 3) % 600, (i * 13) % 200, 12, 12); }
            requestAnimationFrame(draw);
          };
          requestAnimationFrame(draw);
        </script>
        """

    static let framesPage = """
        <title>frames</title>
        <style>body { margin: 0; background: #fff; } #dot { position: absolute; width: 20px; height: 20px; background: #c33; }
        #spin { position: absolute; left: 300px; top: 300px; width: 40px; height: 40px; background: #36c; }</style>
        <div id="dot"></div><div id="spin"></div>
        <script>
          const dot = document.getElementById('dot'), spin = document.getElementById('spin');
          addEventListener('mousemove', e => { dot.style.left = e.clientX + 'px'; dot.style.top = e.clientY + 'px'; });
          const tick = t => { if (window.__animate) spin.style.transform = `rotate(${t / 4}deg)`; requestAnimationFrame(tick); };
          requestAnimationFrame(tick);
        </script>
        """
}

extension Benchmarks {
    /// `visibility`: what a windowed page reports as its window is shown,
    /// covered, minimized and hidden, for a browser hosted before and after
    /// its window is shown.
    static func windowedVisibility() async {
        SelfTest.window.orderOut(nil)
        for showFirst in [true, false] {
            let window = NSWindow(
                contentRect: CGRect(x: 200, y: 200, width: 640, height: 480),
                styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .floating
            if showFirst { window.makeKeyAndOrderFront(nil) }
            let view = CefWindowedBrowserView()
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
            let browser = CefBrowser(url: URL(string: "selftest://bench/animated.html")!)
            view.browser = browser
            if !showFirst { window.makeKeyAndOrderFront(nil) }
            _ = await SelfTest.waitUntil { browser.title == "animated" }
            func report(_ label: String) async {
                try? await Task.sleep(for: .seconds(1))
                let page = try? await browser.evaluateJavaScript("[document.visibilityState, window.__raf]")
                print("bench visibility showFirst=\(showFirst) \(label): page \(page?[0].stringValue ?? "?") raf \(page?[1].intValue ?? -1), window occlusion visible \(window.occlusionState.contains(.visible))")
            }
            await report("shown")
            let cover = NSWindow(
                contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            cover.orderFrontRegardless()
            await report("covered")
            cover.orderOut(nil)
            await report("uncovered")
            window.miniaturize(nil)
            await report("minimized")
            window.deminiaturize(nil)
            await report("restored")
            NSApp.hide(nil)
            await report("app hidden")
            NSApp.unhide(nil)
            await report("app unhidden")
            window.orderOut(nil)
            await report("ordered out")
            window.makeKeyAndOrderFront(nil)
            await report("ordered in")
            browser.hostViewDidHide()
            await report("was_hidden(1)")
            browser.hostViewDidUnhide()
            await report("was_hidden(0)")
            let native = view.subviews.first
            native?.isHidden = true
            await report("native view hidden")
            native?.isHidden = false
            await report("native view shown")
            window.miniaturize(nil)
            try? await Task.sleep(for: .seconds(1))
            native?.isHidden = true
            await report("minimized, native view hidden")
            native?.isHidden = false
            window.deminiaturize(nil)
            await report("restored, native view shown")
            browser.close(force: true)
            _ = await SelfTest.waitUntil { browser.state == .closed }
            cover.close()
            window.close()
        }
    }
}
