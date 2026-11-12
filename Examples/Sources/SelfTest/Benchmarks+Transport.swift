import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import Darwin
import os

/// Benchmarks of CefKit's data paths: bridge calls, `evaluateJavaScript`,
/// the in-process codecs, accessibility updates and DevTools events.
///
/// - `bridge`: round trips a second for a call returning an `Int`, a
///   20-field struct, a 10 000-element array and 16 MB of binary data
///   each way, with main-thread allocations per call.
/// - `evaluate`: `evaluateJavaScript` returning an `Int`, a 20-field
///   object and a 10 000-element array.
/// - `codec`: encoding and decoding the bridge's values in this process,
///   with allocations per value.
/// - `axingest`: taking a 15 000-node accessibility tree from CEF.
/// - `devtools`: 20 000 DevTools events nobody listens to.
extension Benchmarks {
    static func transport(_ name: String) async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "bench", handler: BenchmarkPages())
        CefDiagnostics.isEnabled = true
        switch name {
        case "bridge": await bridge()
        case "evaluate": await evaluate()
        case "codec": codec()
        case "axingest": await accessibilityIngest()
        case "devtools": await devToolsEvents()
        default: break
        }
    }

    // MARK: Bridge

    static func bridge() async {
        let bridge = TransportBench.makeBridge()
        var options = CefBrowserOptions()
        options.bridges = [bridge]
        let browser = CefBrowser(url: URL(string: "selftest://bench/bridge.html")!, options: options)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await SelfTest.waitUntil({ browser.title == "bridge" }) else {
            print("bench error: bridge page did not load")
            return
        }
        let cases: [(String, Int)] = [
            ("ping", 3000), ("twenty", 2000), ("many", 20), ("binIn", 10), ("binOut", 10), ("b64In", 10), ("b64Out", 10),
        ]
        for run in 1...2 {
            for (kind, count) in cases {
                let meter = MainThreadMeter()
                let memory = MemorySampler()
                memory.start()
                meter.start()
                MallocCounter.start()
                let result = try? await browser.evaluateJavaScript("runBench('\(kind)', \(count))", as: BenchResult.self)
                let allocations = MallocCounter.stop()
                meter.stop()
                memory.stop()
                guard let result else {
                    print("bench bridge run \(run) \(kind): failed")
                    continue
                }
                print(String(
                    format: "bench bridge run %d %@: %d calls in %.1f ms, %.0f calls/s, %.3f ms each; main thread busy %.0f ms; main-thread allocations %.0f per call; peak footprint +%.0f MB%@",
                    run, kind, count, result.ms, Double(count) / result.ms * 1000, result.ms / Double(count),
                    meter.busy.benchMilliseconds, Double(allocations) / Double(count), memory.peakMB - memory.startMB,
                    result.error.map { "; error: \($0)" } ?? ""))
            }
        }
    }

    // MARK: Evaluation

    static func evaluate() async {
        let browser = CefBrowser(url: URL(string: "selftest://bench/bridge.html")!)
        let view = CefWindowedBrowserView()
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await SelfTest.waitUntil({ browser.title == "bridge" }) else {
            print("bench error: page did not load")
            return
        }
        for run in 1...2 {
            await measureEvaluation("int", run: run, count: 2000) {
                _ = try await browser.evaluateJavaScript("41 + 1", as: Int.self)
            }
            await measureEvaluation("twenty", run: run, count: 1000) {
                _ = try await browser.evaluateJavaScript("makeTwenty(1)", as: TransportBench.Twenty.self)
            }
            await measureEvaluation("many", run: run, count: 20) {
                _ = try await browser.evaluateJavaScript("makeMany(10000)", as: [TransportBench.Small].self)
            }
            await measureEvaluation("json-many", run: run, count: 20) {
                _ = try await browser.evaluateJavaScript("makeMany(10000)")
            }
        }
    }

    private static func measureEvaluation(_ label: String, run: Int, count: Int, _ body: () async throws -> Void) async {
        let meter = MainThreadMeter()
        meter.start()
        MallocCounter.start()
        let start = ContinuousClock.now
        var failure: Error?
        for _ in 0..<count {
            do { try await body() } catch { failure = error; break }
        }
        let elapsed = (ContinuousClock.now - start).benchMilliseconds
        let allocations = MallocCounter.stop()
        meter.stop()
        print(String(
            format: "bench evaluate run %d %@: %d calls in %.1f ms, %.0f calls/s, %.3f ms each; main thread busy %.0f ms; main-thread allocations %.0f per call%@",
            run, label, count, elapsed, Double(count) / elapsed * 1000, elapsed / Double(count), meter.busy.benchMilliseconds,
            Double(allocations) / Double(count), failure.map { "; error: \($0)" } ?? ""))
    }

    // MARK: Codecs

    static func codec() {
        let twenty = TransportBench.Twenty.sample(1)
        let many = (0..<10_000).map { TransportBench.Small(id: $0, name: "item \($0)", ok: $0 % 2 == 0) }
        func measure(_ label: String, count: Int, _ body: () throws -> Void) {
            MallocCounter.start()
            let start = ContinuousClock.now
            for _ in 0..<count { try? body() }
            let elapsed = (ContinuousClock.now - start).benchMilliseconds
            let allocations = MallocCounter.stop()
            print(String(format: "bench codec %@: %.2f µs each, %.1f allocations each", label,
                         elapsed * 1000 / Double(count), Double(allocations) / Double(count)))
        }
        for _ in 1...2 {
            // The JSON path: text → CefJSON → JSONEncoder → JSONDecoder → T.
            let intText = "42", twentyText = try! CefJSON(encoding: twenty).text, manyText = try! CefJSON(encoding: many).text
            measure("json decode int", count: 20000) { _ = try CefJSON(data: Data(intText.utf8)).decode(Int.self) }
            measure("json decode twenty", count: 5000) { _ = try CefJSON(data: Data(twentyText.utf8)).decode(TransportBench.Twenty.self) }
            measure("json decode many", count: 10) { _ = try CefJSON(data: Data(manyText.utf8)).decode([TransportBench.Small].self) }
            measure("json encode int", count: 20000) { _ = try CefJSON(encoding: 42).text }
            measure("json encode twenty", count: 5000) { _ = try CefJSON(encoding: twenty).text }
            measure("json encode many", count: 10) { _ = try CefJSON(encoding: many).text }
            TransportBench.wireCodec(twenty: twenty, many: many, measure: measure)
        }
    }

    // MARK: Accessibility

    static func accessibilityIngest() async {
        for run in 1...3 {
            var options = CefBrowserOptions()
            options.rendering = .offscreen
            options.offscreenAccessibility = .enabled
            let browser = CefBrowser(url: URL(string: "selftest://bench/axlarge.html")!, options: options)
            let view = CefOffscreenBrowserView()
            view.frame = SelfTest.window.contentView!.bounds
            SelfTest.window.contentView!.addSubview(view)
            CefDiagnostics.reset()
            let meter = MainThreadMeter()
            let memory = MemorySampler()
            memory.start()
            meter.start()
            let start = ContinuousClock.now
            view.browser = browser
            _ = await SelfTest.waitUntil(timeout: .seconds(60)) {
                browser.accessibilityTree.nodeCount > 15000 && browser.accessibilityTree.isLoaded
            }
            let ready = (ContinuousClock.now - start).benchMilliseconds
            meter.stop()
            memory.stop()
            let main = CefDiagnostics.counter(.accessibilityIngestMain)
            let background = CefDiagnostics.counter(.accessibilityIngestBackground)
            print(String(
                format: "bench axingest run %d: %d nodes ready at %.0f ms; ingest on main %.1f ms in %d updates (largest share of main busy %.0f ms); background %.1f ms; peak footprint +%.0f MB",
                run, browser.accessibilityTree.nodeCount, ready, Double(main.nanoseconds) / 1e6, main.count,
                meter.busy.benchMilliseconds, Double(background.nanoseconds) / 1e6, memory.peakMB - memory.startMB))
            browser.close(force: true)
            _ = await SelfTest.waitUntil { browser.state == .closed }
            view.removeFromSuperview()
        }
    }

    // MARK: DevTools

    static func devToolsEvents() async {
        for run in 1...2 {
            let browser = CefBrowser(url: URL(string: "selftest://bench/bridge.html")!)
            let view = CefWindowedBrowserView()
            view.frame = SelfTest.window.contentView!.bounds
            SelfTest.window.contentView!.addSubview(view)
            view.browser = browser
            _ = await SelfTest.waitUntil { browser.title == "bridge" }
            _ = try? await browser.devTools.send("Runtime.enable")
            CefDiagnostics.reset()
            let meter = MainThreadMeter()
            meter.start()
            MallocCounter.start()
            let start = ContinuousClock.now
            _ = try? await browser.evaluateJavaScript("for (let i = 0; i < 20000; i++) console.log('event', i, {a: i}); 1")
            // Wait for the events to drain.
            _ = await SelfTest.waitUntil(timeout: .seconds(30)) { CefDiagnostics.counter(.devToolsEvent).count >= 20000 }
            let elapsed = (ContinuousClock.now - start).benchMilliseconds
            let allocations = MallocCounter.stop()
            meter.stop()
            let events = CefDiagnostics.counter(.devToolsEvent)
            print(String(
                format: "bench devtools run %d: %d events in %.0f ms, CefKit %.2f µs each; main thread busy %.0f ms; main-thread allocations %.1f per event",
                run, events.count, elapsed, events.microsecondsEach, meter.busy.benchMilliseconds,
                Double(allocations) / Double(max(events.count, 1))))
            browser.close(force: true)
            _ = await SelfTest.waitUntil { browser.state == .closed }
            view.removeFromSuperview()
        }
    }
}

struct BenchResult: Codable {
    var ms: Double
    var error: String?
}

enum TransportBench {
    struct Twenty: Codable, Equatable {
        var i0, i1, i2, i3, i4, i5, i6, i7: Int
        var d0, d1, d2, d3: Double
        var s0, s1, s2, s3: String
        var b0, b1, b2, b3: Bool

        static func sample(_ seed: Int) -> Twenty {
            Twenty(i0: seed, i1: 1, i2: 2, i3: 3, i4: 4, i5: 5, i6: 6, i7: 7, d0: 0.5, d1: 1.5, d2: 2.5, d3: 3.5,
                   s0: "alpha", s1: "beta", s2: "gamma", s3: "a longer string value", b0: true, b1: false, b2: true, b3: false)
        }
    }

    struct Small: Codable, Equatable {
        var id: Int
        var name: String
        var ok: Bool
    }

    @MainActor
    static func makeBridge() -> CefBridge {
        let bridge = CefBridge(name: "bench")
        bridge.handle("ping") { (value: Int) in value + 1 }
        bridge.handle("twenty") { (value: Twenty) in value }
        bridge.handle("many") { (value: [Small]) in value }
        bridge.handle("binIn") { (value: Data) in value.count }
        bridge.handle("binOut") { (count: Int) in Data(count: count) }
        bridge.handle("b64In") { (value: String) in Data(base64Encoded: value)?.count ?? -1 }
        bridge.handle("b64Out") { (count: Int) in Data(count: count).base64EncodedString() }
        return bridge
    }

    /// The bridge benchmark's page.
    static let page = """
        <title>bridge</title>
        <script>
        const twenty = seed => ({ i0: seed, i1: 1, i2: 2, i3: 3, i4: 4, i5: 5, i6: 6, i7: 7, d0: 0.5, d1: 1.5, d2: 2.5, d3: 3.5,
          s0: 'alpha', s1: 'beta', s2: 'gamma', s3: 'a longer string value', b0: true, b1: false, b2: true, b3: false });
        window.makeTwenty = twenty;
        window.makeMany = n => Array.from({ length: n }, (_, i) => ({ id: i, name: 'item ' + i, ok: i % 2 === 0 }));
        const size = 16 << 20;
        let b64 = null;
        window.runBench = async (kind, n) => {
          try {
            const many = makeMany(10000);
            const buffer = new ArrayBuffer(size);
            if (kind === 'b64In' && !b64) {
              const bytes = new Uint8Array(size); let s = '';
              for (let i = 0; i < size; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
              b64 = btoa(s);
            }
            const t0 = performance.now();
            for (let i = 0; i < n; i++) {
              switch (kind) {
                case 'ping': if (await bench.ping(i) !== i + 1) throw new Error('bad ping'); break;
                case 'twenty': if ((await bench.twenty(twenty(i))).i0 !== i) throw new Error('bad twenty'); break;
                case 'many': if ((await bench.many(many)).length !== 10000) throw new Error('bad many'); break;
                case 'binIn': if (await bench.binIn(buffer) !== size) throw new Error('bad binIn'); break;
                case 'binOut': { const r = await bench.binOut(size); if ((r.byteLength ?? r.length) === undefined) throw new Error('bad binOut'); break; }
                case 'b64In': if (await bench.b64In(b64) !== size) throw new Error('bad b64In'); break;
                case 'b64Out': if ((await bench.b64Out(size)).length < size) throw new Error('bad b64Out'); break;
              }
            }
            return { ms: performance.now() - t0 };
          } catch (e) { return { ms: 1, error: String(e) }; }
        };
        </script>
        """

    /// A page of about 16 000 accessibility nodes.
    static let largeAccessibilityPage: String = {
        let rows = (0..<2000).map { "<li><a href='#\($0)'>Item \($0)</a> <span>detail \($0)</span> <b>x</b></li>" }.joined()
        return "<title>axlarge</title><h1>Large</h1><ul>\(rows)</ul>"
    }()
}

/// Counts allocations made on the main thread, through libmalloc's
/// `malloc_logger` hook, which it calls for every allocation while set.
enum MallocCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var thread: pthread_t?
    nonisolated(unsafe) private static let hook: UnsafeMutablePointer<Logger?>? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)
    }()
    private static let logger: Logger = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE
        guard type & 2 != 0, let thread = MallocCounter.thread, pthread_equal(pthread_self(), thread) != 0 else { return }
        MallocCounter.count += 1
    }

    static func start() {
        count = 0
        thread = pthread_self()
        hook?.pointee = logger
    }

    static func stop() -> Int {
        hook?.pointee = nil
        thread = nil
        return count
    }
}

extension TransportBench {
    /// The wire codec's share of ``Benchmarks/codec()``.
    static func wireCodec(twenty: Twenty, many: [Small], measure: (String, Int, () throws -> Void) -> Void) {}
}
