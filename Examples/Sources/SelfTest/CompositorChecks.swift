import AppKit
import CefKit
import CefSwiftUI
import IOSurface
import QuartzCore

/// Checks and a benchmark of what `CefOffscreenBrowserView` presents: the
/// page paints a frame number into its background colour on every
/// animation frame. Each surface the view presents is read as it becomes
/// the layer's contents, and a 2 ms timer reads the presented surface again,
/// at the top and the bottom edge.
///
/// - A surface whose number changes while it stays the layer's contents
///   was written while the window server could show it.
/// - Different numbers at the top and the bottom are a torn frame.
extension SelfTest {
    static func compositorChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefRuntime.shared.energySaver = .off
        defer { CefRuntime.shared.energySaver = .automatic }
        guard let stage = await CompositorStage(points: CGSize(width: 640, height: 400)) else {
            check("compositor: the page loads", false)
            return
        }
        defer { stage.close() }
        guard stage.window.occlusionState.contains(.visible) else {
            skip("compositor", because: "the test window is not visible (screen locked or asleep?)", .environment)
            return
        }
        let animated = await stage.animate(for: .seconds(2), resizing: false)
        check("compositor: the view presents its own copy of each frame",
              animated.ownedSurfaces && animated.presented > 20,
              detail: animated.summary)
        check("compositor: a presented frame never changes on screen",
              animated.mutated == 0 && animated.torn == 0, detail: animated.summary)
        let resized = await stage.animate(for: .seconds(2), resizing: true)
        // While the size changes, a frame can legitimately differ between
        // its top and bottom (Chromium letterboxes a frame smaller than its
        // surface), so only changes on screen count.
        check("compositor: a presented frame never changes on screen while the view resizes",
              resized.mutated == 0 && resized.presented > 10, detail: resized.summary)
    }
}

extension Benchmarks {
    /// `compositor`: presented frames a second, CPU, mouse-to-screen
    /// latency and memory of `CefOffscreenBrowserView`, for 1280×800,
    /// 2560×1600 and 5120×3200 pixel surfaces (1280×800 and 2560×1600 views
    /// at 1× and 2×; the screen is 2×, so the 1× sizes are views of half
    /// the size).
    static func compositor() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefRuntime.shared.energySaver = .off
        defer { CefRuntime.shared.energySaver = .automatic }
        SelfTest.window.orderOut(nil)
        let sizes: [(String, CGSize)] = [
            ("1280x800 @1x", CGSize(width: 640, height: 400)),
            ("1280x800 @2x / 2560x1600 @1x", CGSize(width: 1280, height: 800)),
            ("2560x1600 @2x", CGSize(width: 2560, height: 1600)),
        ]
        let only = UserDefaults.standard.string(forKey: "compositorSize")
        for (label, points) in sizes where only == nil || label.hasPrefix(only!) {
            for run in 1...2 {
                let memory = MemorySampler()
                memory.start()
                guard let stage = await CompositorStage(points: points) else {
                    print("bench error: \(label) did not load")
                    continue
                }
                try? await Task.sleep(for: .milliseconds(500))
                let cpuStart = ProcessCPU.sample()
                let animated = await stage.animate(for: .seconds(3), resizing: false)
                let used = ProcessCPU.used(from: cpuStart, to: ProcessCPU.sample())
                memory.stop()
                let latencies = await stage.mouseLatencies(count: 30)
                let resized = await stage.animate(for: .seconds(2), resizing: true)
                print(String(
                    format: "bench compositor %@ run %d (%.0fx%.0f px): presented %.1f/s, rAF %.1f/s, app CPU %.1f%%, all CPU %.1f%%; mouse to screen median %.1f ms, p90 %.1f ms (%d); peak footprint while animating +%.0f MB; changed on screen %d, torn %d; while resizing changed %d, torn %d of %d",
                    label, run, animated.pixelSize.width, animated.pixelSize.height,
                    animated.presentedPerSecond, animated.rafPerSecond,
                    used.app / animated.seconds * 100, used.total / animated.seconds * 100,
                    latencies.isEmpty ? 0 : latencies[latencies.count / 2],
                    latencies.isEmpty ? 0 : latencies[latencies.count * 9 / 10], latencies.count,
                    memory.peakMB - memory.startMB, animated.mutated, animated.torn,
                    resized.mutated, resized.torn, resized.presented))
                stage.close()
                _ = await SelfTest.waitUntil { CefRuntime.shared.browsers.isEmpty }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        SelfTest.window.orderFront(nil)
    }
}

/// An offscreen browser showing the frame-number page in a window of its
/// own. Key-value observation of the layer's `contents` notes each frame
/// the view presents and the number in it; a timer reads the number in the
/// presented surface back, so a surface written while the layer shows it
/// is seen as a different number without a new presentation.
@MainActor
final class CompositorStage {
    let window: NSWindow
    let view = CefOffscreenBrowserView()
    let browser: CefBrowser
    private var timer: Timer?
    private var observation: NSKeyValueObservation?
    private var samples: [Sample] = []
    private var recording = false
    /// The surface the layer shows and the number it held when presented.
    private var shown: (surface: IOSurfaceRef, code: Int)?
    private var presentations = 0

    struct Sample {
        /// The number differs from the one the surface held when presented.
        var changedOnScreen: Bool
        var top: Int
        var bottom: Int
        var time: CFTimeInterval
    }

    struct Result {
        var presented = 0
        var mutated = 0
        var torn = 0
        var ownedSurfaces = false
        var seconds = 1.0
        var rafPerSecond = 0.0
        var pixelSize = CGSize.zero
        var presentedPerSecond: Double { Double(presented) / seconds }
        var summary: String {
            "\(presented) frames presented, \(mutated) changed on screen, \(torn) torn, own surfaces: \(ownedSurfaces)"
        }
    }

    init?(points: CGSize) async {
        let screen = NSScreen.main?.frame ?? .zero
        // Borderless, so a view larger than the screen keeps its size.
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: screen.minX, y: screen.maxY - points.height), size: points),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        var options = CefBrowserOptions()
        options.rendering = .offscreen(frameRate: 120)
        browser = CefBrowser(url: URL(string: "selftest://bench/compositor.html")!, options: options)
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.browser = browser
        window.orderFrontRegardless()
        guard await SelfTest.waitUntil({ browser.title == "compositor" }) else { return nil }
        observation = view.layer?.sublayers?.first?.observe(\.contents, options: [.new]) { [weak self] _, _ in
            // Set on the main thread, in the view's paint callback.
            MainActor.assumeIsolated { self?.presented(self?.contentLayer?.contents) }
        }
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        observation = nil
        browser.close(force: true)
        view.removeFromSuperview()
        window.close()
    }

    private var contentLayer: CALayer? { view.layer?.sublayers?.first }

    private func presented(_ contents: Any?) {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
            shown = nil
            return
        }
        let surface = contents as! IOSurfaceRef
        shown = Self.readCodes(surface).map { (surface, $0.0) }
        if recording { presentations += 1 }
    }

    private func refresh() {
        guard recording, let shown, let contents = contentLayer?.contents,
              (contents as CFTypeRef) === shown.surface,
              let (top, bottom) = Self.readCodes(shown.surface)
        else { return }
        samples.append(Sample(changedOnScreen: top != shown.code, top: top, bottom: bottom, time: CACurrentMediaTime()))
    }

    /// The frame numbers at the top and bottom edge of `surface`.
    nonisolated static func readCodes(_ surface: IOSurfaceRef) -> (Int, Int)? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let row = IOSurfaceGetBytesPerRow(surface)
        guard width > 4, height > 4 else { return nil }
        let base = IOSurfaceGetBaseAddress(surface)
        func code(_ y: Int) -> Int {
            // BGRA: the page puts the frame number in red and green.
            let pixel = base.advanced(by: y * row + (width / 2) * 4).assumingMemoryBound(to: UInt8.self)
            return decode(Int(pixel[2])) + decode(Int(pixel[1])) * 8
        }
        return (code(2), code(height - 3))
    }

    private nonisolated static func decode(_ value: Int) -> Int { max(0, min(7, Int((Double(value - 16) / 32).rounded()))) }

    /// Animates the page for `duration`, resizing the window every 40 ms
    /// when `resizing`, and reports what the readings saw.
    func animate(for duration: Duration, resizing: Bool) async -> Result {
        samples = []
        presentations = 0
        let original = window.frame
        _ = try? await browser.evaluateJavaScript("window.__animate = true; window.__rafs = 0")
        recording = true
        let start = ContinuousClock.now
        var step = 0
        while ContinuousClock.now - start < duration {
            if resizing {
                step += 1
                var frame = original
                frame.size.width -= CGFloat((step % 6) * 24)
                frame.size.height -= CGFloat((step % 4) * 18)
                frame.origin.y = original.maxY - frame.height
                window.setFrame(frame, display: true)
            }
            try? await Task.sleep(for: .milliseconds(resizing ? 40 : 100))
        }
        recording = false
        let rafs = (try? await browser.evaluateJavaScript("window.__animate = false; window.__rafs"))?.doubleValue ?? 0
        if resizing { window.setFrame(original, display: true) }
        var result = Result()
        result.seconds = (ContinuousClock.now - start).seconds
        result.rafPerSecond = rafs / result.seconds
        if let contents = contentLayer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            let surface = contents as! IOSurfaceRef
            result.pixelSize = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            // CEF's pooled surfaces carry Chromium's shared-image properties;
            // the view's own carry its marker.
            result.ownedSurfaces = IOSurfaceCopyValue(surface, "CefSwiftOffscreenCopy" as CFString) != nil
        }
        result.presented = presentations
        result.torn = samples.filter { $0.top != $0.bottom }.count
        result.mutated = samples.filter(\.changedOnScreen).count
        return result
    }

    /// Milliseconds from a mouse move to the reading that shows the page's
    /// answer to it, sorted.
    func mouseLatencies(count: Int) async -> [Double] {
        var latencies: [Double] = []
        for index in 0..<count {
            // The page shows the code of the mouse's x position, x / 10 % 64.
            let code = (index * 5 + 1) % 64
            let x = CGFloat(code * 10 + 5)
            samples = []
            recording = true
            let sent = CACurrentMediaTime()
            browser.sendMouseMove(to: CGPoint(x: x, y: 60), modifiers: [])
            _ = await SelfTest.waitUntil(timeout: .milliseconds(500)) { self.samples.contains { $0.top == code } }
            recording = false
            if let seen = samples.first(where: { $0.top == code }) { latencies.append((seen.time - sent) * 1000) }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 40...90)))
        }
        return latencies.sorted()
    }

    /// The page: on each animation frame the background shows the frame
    /// number modulo 64; with the animation off, a mouse move shows the
    /// mouse's x position.
    nonisolated static let page = """
        <title>compositor</title>
        <style>html, body { margin: 0; height: 100%; }</style>
        <script>
          window.__animate = false; window.__rafs = 0;
          const show = code => {
            const r = (code % 8) * 32 + 16, g = (Math.floor(code / 8) % 8) * 32 + 16;
            document.body.style.background = `rgb(${r}, ${g}, 128)`;
          };
          let frame = 0;
          const tick = () => { if (window.__animate) { window.__rafs++; show(++frame % 64); } requestAnimationFrame(tick); };
          requestAnimationFrame(tick);
          addEventListener('mousemove', e => { if (!window.__animate) show(Math.floor(e.clientX / 10) % 64); });
          addEventListener('DOMContentLoaded', () => show(0));
        </script>
        """
}
