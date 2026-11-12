import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import Darwin

/// `-benchmark <name>`: instead of the checks, runs one measurement and
/// prints `bench …` lines. Run it under the GUI lock, one at a time.
///
/// - `requests`: 500 small responses and one 200 MB response through a
///   scheme handler, with a request filter on every request.
/// - `lifecycle`: CPU use of an animated page in each host and state.
/// - `frames`: offscreen animation frames, pacing, input latency and CPU.
/// - `compositor`: what `CefOffscreenBrowserView` presents, at three sizes.
@MainActor
enum Benchmarks {
    static var requested: String? { UserDefaults.standard.string(forKey: "benchmark") }

    static func run(_ name: String) async {
        switch name {
        case "requests": await requests()
        case "lifecycle":
            CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
            await lifecycleCPU()
        case "visibility":
            CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
            await windowedVisibility()
        case "probes":
            CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
            await probes()
        case "frames":
            CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
            await frames()
        case "compositor": await compositor()
        case "bridge", "evaluate", "codec", "axingest", "devtools": await transport(name)
        default: print("bench error: unknown benchmark \(name)")
        }
    }

    // MARK: Requests

    static func requests() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-bench-\(getpid()).bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: file) {
            for _ in 0..<(BenchmarkPages.bigSize >> 20) { handle.write(Data(count: 1 << 20)) }
            try? handle.close()
        }
        BenchmarkPages.bigFile = file
        defer { try? FileManager.default.removeItem(at: file) }
        let kinds = ["data", "stream", "file"]
        for run in 1...(3 * kinds.count) {
            let kind = kinds[(run - 1) % kinds.count]
            var options = CefBrowserOptions()
            options.requestFilter = { request in
                if request.url?.path == "/blocked" { return .block }
                return .setHeaders(["X-Bench": "1"])
            }
            let browser = CefBrowser(url: URL(string: "selftest://bench/page.html?big=/big-\(kind)")!, options: options)
            let view = CefWindowedBrowserView()
            view.frame = SelfTest.window.contentView!.bounds
            SelfTest.window.contentView!.addSubview(view)
            let meter = MainThreadMeter()
            let memory = MemorySampler()
            CefDiagnostics.isEnabled = true
            CefDiagnostics.reset()
            let cpu = ProcessCPU.sample()
            let start = ContinuousClock.now
            meter.start()
            memory.start()
            view.browser = browser
            _ = await SelfTest.waitUntil(timeout: .seconds(120)) { browser.title.hasPrefix("done") }
            let elapsed = ContinuousClock.now - start
            meter.stop()
            memory.stop()
            let overhead = CefDiagnostics.counter(.requestFilterOverhead)
            print(String(
                format: "bench requests run %d (%@): %@; total %.0f ms; main thread busy %.1f%% (%.0f ms); peak footprint %.0f MB (+%.0f MB); app CPU %.0f ms; request filter overhead %.2f µs each (%d)",
                run, kind, browser.title, elapsed.benchMilliseconds, meter.busyFraction * 100, meter.busy.benchMilliseconds,
                memory.peakMB, memory.peakMB - memory.startMB, ProcessCPU.used(from: cpu, to: ProcessCPU.sample()).app * 1000,
                overhead.microsecondsEach, overhead.count))
            browser.close(force: true)
            _ = await SelfTest.waitUntil { browser.state == .closed }
            view.removeFromSuperview()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The benchmark's pages: 500 small responses and one of 200 MB.
struct BenchmarkPages: CefSchemeHandler {
    static let bigSize = 200 << 20
    nonisolated(unsafe) static var bigFile: URL?

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch request.url?.path {
        case "/page.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data("""
                <title>loading</title>
                <script>
                (async () => {
                  const t0 = performance.now();
                  await Promise.all(Array.from({ length: 500 }, (_, i) => fetch('/small/' + i).then(r => r.arrayBuffer())));
                  const t1 = performance.now();
                  const reader = (await fetch(new URLSearchParams(location.search).get('big') ?? '/big-data')).body.getReader();
                  let n = 0;
                  for (;;) { const { done, value } = await reader.read(); if (done) break; n += value.length; }
                  const t2 = performance.now();
                  document.title = `done small ${Math.round(t1 - t0)} ms, big ${Math.round(t2 - t1)} ms, ${n} bytes`;
                })();
                </script>
                """.utf8))
        case "/animated.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(Self.animatedPage.utf8))
        case "/timers.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(Self.timersPage.utf8))
        case "/frames.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(Self.framesPage.utf8))
        case "/bridge.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(TransportBench.page.utf8))
        case "/axlarge.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(TransportBench.largeAccessibilityPage.utf8))
        case "/damage.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(CompositorStage.damagePage.utf8))
        case "/compositor.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data(CompositorStage.page.utf8))
        case "/big-data":
            return CefSchemeResponse(mimeType: "application/octet-stream", body: Data(count: Self.bigSize))
        case "/big-stream":
            return CefSchemeResponse(
                mimeType: "application/octet-stream",
                body: .stream(GeneratedChunks(count: Self.bigSize >> 20, size: 1 << 20), length: Self.bigSize))
        case "/big-file":
            guard let file = Self.bigFile else { return .notFound() }
            return CefSchemeResponse(mimeType: "application/octet-stream", body: .file(file))
        default:
            return CefSchemeResponse(mimeType: "text/plain", body: Data(repeating: 0x61, count: 1024))
        }
    }
}

/// `count` chunks of `size` zero bytes, made as they are read.
struct GeneratedChunks: AsyncSequence, Sendable {
    let count: Int
    let size: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: Int
        let size: Int

        mutating func next() async -> Data? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            return Data(count: size)
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: count, size: size) }
}

// MARK: - Meters

/// Time the main run loop spends awake, from a run-loop observer.
@MainActor
final class MainThreadMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt: UInt64 = 0
    private(set) var busy: Duration = .zero
    private var startedAt: ContinuousClock.Instant = .now
    private var stoppedAt: ContinuousClock.Instant = .now

    func start() {
        busy = .zero
        startedAt = .now
        wokeAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if activity == .afterWaiting {
            wokeAt = now
        } else if activity == .beforeWaiting, wokeAt != 0 {
            busy += .nanoseconds(Int64(now - wokeAt))
            wokeAt = 0
        }
    }

    func stop() {
        stoppedAt = .now
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    var busyFraction: Double { busy.seconds / max((stoppedAt - startedAt).seconds, 0.001) }
}

/// The app process's physical footprint, sampled every 20 ms.
@MainActor
final class MemorySampler {
    private var timer: Timer?
    private(set) var peakMB = 0.0
    private(set) var startMB = 0.0

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func start() {
        startMB = Self.footprintMB()
        peakMB = startMB
        // Sampled off the main thread, so a busy main thread cannot hide a peak.
        let sampler = Thread {
            while !Thread.current.isCancelled {
                let value = MemorySampler.footprintMB()
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                    if let self, value > self.peakMB { self.peakMB = value }
                } }
                usleep(20_000)
            }
        }
        sampler.start()
        samplerThread = sampler
    }

    private var samplerThread: Thread?

    func stop() {
        samplerThread?.cancel()
        samplerThread = nil
        let value = Self.footprintMB()
        if value > peakMB { peakMB = value }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    var benchMilliseconds: Double { seconds * 1000 }
}
