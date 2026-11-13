import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit
import Darwin

/// `-benchmark services`: latency, cost breakdown, allocations and load
/// behaviour of the internal-page service calls, on warm hosts.
///
/// Prints, per call type, `bench services <type>: p50/p95/p99`, the
/// breakdown (Swift encode, renderer time, Swift decode, the rest being
/// the two IPC hops and V8 compilation), bytes each way and main-thread
/// allocations per call; then the load runs. Local numbers only: run it
/// under the GUI lock on an idle Mac.
extension Benchmarks {
    static func services() async {
        CefDiagnostics.isEnabled = true
        let profile = CefProfile.default
        let bench = ServiceBench(profile: profile)
        await bench.prepare()
        await bench.perCallType()
        await bench.typing()
        await bench.concurrentMix()
        await bench.largeHistory()
        await bench.largeBookmarkTree()
        await bench.whileAnotherPageIsBusy()
        await bench.leaks()
        bench.finish()
    }
}

@MainActor
final class ServiceBench {
    let profile: CefProfile
    let faviconPage = URL(string: "selftest://edge/favicon.html")!
    private var hostBrowsers: [CefWindow] = []

    init(profile: CefProfile) {
        self.profile = profile
    }

    // MARK: Set-up

    func prepare() async {
        // A visited page with an icon, for history, top sites and favicons.
        let visited = CefWindow(browser: CefBrowser(url: faviconPage))
        _ = await SelfTest.waitUntil { visited.browser.favicon != nil }
        visited.close()
        _ = await SelfTest.waitUntil { visited.isClosed }
        CefProfile.serviceIdleTimeout = .seconds(600)
        profile.bookmarks.readSource = .service
        // Warm every host.
        _ = try? await profile.bookmarks.tree()
        _ = try? await profile.history.search(limit: 5)
        _ = try? await profile.history.topSites()
        _ = try? await profile.history.favicon(for: faviconPage, size: 32)
        _ = try? await profile.autocomplete.suggestions(for: "selftest")
        print("bench services hosts: \(profile.runningServiceHosts)")
        if ProcessInfo.processInfo.environment["SERVICE_BENCH_PROBE"] == "1" { await probeInterfaces() }
    }

    /// Prints the methods of the Mojo interfaces the services use.
    func probeInterfaces() async {
        let probes: [(String, String)] = [
            ("omnibox", "import('chrome://omnibox/omnibox_internals.mojom-webui.js').then(m => ({ handler: Object.getOwnPropertyNames(m.OmniboxPageHandlerRemote.prototype), router: Object.getOwnPropertyNames(new m.OmniboxPageCallbackRouter()), types: Object.keys(m.AutocompleteControllerType) }))"),
            ("history", "import('chrome://resources/cr_components/history/history.mojom-webui.js').then(m => ({ handler: Object.getOwnPropertyNames(m.PageHandlerRemote.prototype), src: m.PageHandlerRemote.prototype.queryHistory.toString().slice(0, 400) }))"),
            ("bookmarks", "Promise.resolve({ bookmarks: Object.keys(chrome.bookmarks), favicon: typeof chrome.favicon })"),
            ("bookmarks", "fetch('chrome://favicon2/?pageUrl=https%3A%2F%2Fexample.com&size=16').then(r => ({ ok: r.ok, type: r.type, ct: r.headers.get('content-type') }), e => String(e))"),
        ]
        for (host, script) in probes {
            let result = try? await profile.serviceHostBrowser(named: host)?.evaluateJavaScript(script)
            print("bench probe \(host): \(result.map { $0.text } ?? "failed")")
        }
    }

    func finish() {
        profile.bookmarks.readSource = .automatic
        CefProfile.serviceIdleTimeout = .seconds(30)
        profile.stopServiceHosts()
    }

    // MARK: Per call type

    func perCallType() async {
        // The floor: a trivial evaluation in a host, no engine.
        if let host = profile.serviceHostBrowser(named: "history") {
            await measure("floor (evaluate `1` in a host)", host: nil, count: 300) {
                _ = try await host.evaluateJavaScript("1")
            }
        }
        await measure("engine ping (history host)", host: "history", count: 300) {
            try await self.profile.pingHistoryService(timeout: .seconds(10))
        }
        await measure("autocomplete query", host: "omnibox", count: 60) {
            _ = try await self.profile.autocomplete.suggestions(for: "selftest edge")
        }
        var firstResults: [Double] = [], completeResults: [Double] = [], resultCounts: [Double] = []
        for _ in 0..<40 {
            let start = ContinuousClock.now
            var count = 0
            do {
                for try await result in profile.autocomplete.results(for: "selftest edge") {
                    count += 1
                    if count == 1 { firstResults.append((ContinuousClock.now - start).benchMilliseconds) }
                    if result.isComplete { completeResults.append((ContinuousClock.now - start).benchMilliseconds) }
                }
            } catch { print("bench error \(error)") }
            resultCounts.append(Double(count))
        }
        print("bench services autocomplete stream: first result \(Percentiles(firstResults)); complete \(Percentiles(completeResults)); results a query \(Percentiles(resultCounts))")
        await measure("history search (20)", host: "history", count: 100) {
            _ = try await self.profile.history.search(limit: 20)
        }
        await measure("top sites", host: "most-visited", count: 8) {
            _ = try await self.profile.history.topSites()
        }
        await measure("favicon (32 pt)", host: nil, count: 100) {
            _ = try await self.profile.history.favicon(for: self.faviconPage, size: 32)
        }
        let pages = (0..<50).map { URL(string: "selftest://edge/favicon.html?\($0 == 0 ? "" : "missing\($0)")")! }
        await measure("50 favicons in one call", host: nil, count: 20) {
            _ = try await self.profile.history.favicons(for: pages, size: 16)
        }
        await measure("history page (entries(matching:), 50 a page)", host: "history", count: 30) {
            for try await _ in self.profile.history.entries(matching: "", pageSize: 50) { break }
        }
        await measure("bookmark tree (service)", host: "bookmarks", count: 100) {
            _ = try await self.profile.bookmarks.tree()
        }
        await measure("bookmark search", host: "bookmarks", count: 100) {
            _ = try await self.profile.bookmarks.search("CefSwift")
        }
        await measure("bookmark add + remove", host: "bookmarks", count: 60, callsPerIteration: 2) {
            let made = try await self.profile.bookmarks.add(URL(string: "https://bench.invalid/m")!, title: "bench")
            try await self.profile.bookmarks.remove(made.id)
        }
        await eventDelivery()
    }

    /// From a change made through the API to the `changes` element.
    func eventDelivery() async {
        var yields = 0
        let watcher = Task { for await _ in profile.bookmarks.changes { yields += 1 } }
        defer { watcher.cancel() }
        try? await Task.sleep(for: .milliseconds(200))
        var latencies: [Double] = []
        for i in 0..<30 {
            let before = yields
            let start = ContinuousClock.now
            guard let made = try? await profile.bookmarks.add(URL(string: "https://bench.invalid/e\(i)")!, title: "e")
            else { continue }
            _ = await SelfTest.waitUntil(timeout: .seconds(5)) { yields > before }
            latencies.append((ContinuousClock.now - start).benchMilliseconds)
            try? await profile.bookmarks.remove(made.id)
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("bench services event delivery (add → changes): \(Percentiles(latencies))")
    }

    private func measure(
        _ label: String, host: String?, count: Int, callsPerIteration: Int = 1, _ body: () async throws -> Void
    ) async {
        let jsBefore = await jsStatistics(host)
        CefDiagnostics.reset()
        let meter = MainThreadMeter()
        var latencies: [Double] = []
        var failure: Error?
        meter.start()
        MallocCounter.start()
        for _ in 0..<count {
            let start = ContinuousClock.now
            do { try await body() } catch { failure = error }
            latencies.append((ContinuousClock.now - start).benchMilliseconds)
        }
        let allocations = MallocCounter.stop()
        meter.stop()
        let jsAfter = await jsStatistics(host)
        let calls = Double(count * callsPerIteration)
        let call = CefDiagnostics.counter(.serviceCall)
        let encode = CefDiagnostics.counter(.serviceEncode)
        let decode = CefDiagnostics.counter(.serviceDecode)
        let sent = CefDiagnostics.counter(.serviceRequestBytes)
        let received = CefDiagnostics.counter(.serviceReplyBytes)
        let rendererMs = host == nil ? 0 : (jsAfter.ms - jsBefore.ms) / max(1, Double(jsAfter.calls - jsBefore.calls))
        let engineMs = Double(call.nanoseconds) / 1e6 / max(1, Double(call.count))
        print(String(
            format: "bench services %@: %@; engine %.3f ms = encode %.3f + renderer (JS + mojom) %.3f + decode %.3f + IPC and compile %.3f; sent %.0f B, received %.0f B a call; main-thread allocations %.0f a call; main thread busy %.2f ms a call%@",
            label, Percentiles(latencies).description, engineMs, Double(encode.nanoseconds) / 1e6 / max(1, Double(encode.count)),
            rendererMs, Double(decode.nanoseconds) / 1e6 / max(1, Double(decode.count)),
            engineMs - rendererMs - Double(encode.nanoseconds) / 1e6 / max(1, Double(encode.count)),
            Double(sent.nanoseconds) / max(1, Double(sent.count)), Double(received.nanoseconds) / max(1, Double(received.count)),
            Double(allocations) / calls, meter.busy.benchMilliseconds / calls,
            failure.map { "; error: \($0)" } ?? ""))
    }

    private func jsStatistics(_ host: String?) async -> (calls: Int, ms: Double, heap: Double, inFlight: Int) {
        guard let host, let json = await profile.serviceHostStatistics(named: host) else { return (0, 0, 0, 0) }
        return (json["calls"].intValue ?? 0, json["ms"].doubleValue ?? 0, json["heap"].doubleValue ?? 0,
                json["inFlight"].intValue ?? 0)
    }

    // MARK: Typing

    /// 200 queries 20 ms apart, each superseding the one before, as typing
    /// fast does: the text typed, deleted and typed again.
    func typing() async {
        let phrase = "selftest edge favicon page"
        var texts: [String] = []
        while texts.count < 200 {
            for length in 1...phrase.count where texts.count < 200 { texts.append(String(phrase.prefix(length))) }
            for length in stride(from: phrase.count - 1, through: 1, by: -1) where texts.count < 200 {
                texts.append(String(phrase.prefix(length)))
            }
        }
        await typingRun(texts, label: "200 queries at 20 ms, each cancelling the one before (Task per query)")
        await typingStream(texts)
    }

    /// The same typing through `results(following:)`, the latest-wins API.
    func typingStream(_ texts: [String]) async {
        let (stream, typed) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        let meter = MainThreadMeter()
        let jsBefore = await jsStatistics("omnibox")
        CefDiagnostics.reset()
        meter.start()
        MallocCounter.start()
        var yielded: [CefAutocomplete.Result] = []
        // Texts issued and not yet answered, and how long each first answer took.
        var awaiting: [String: ContinuousClock.Instant] = [:]
        var firstResults: [Double] = []
        let consumer = Task { @MainActor in
            do {
                for try await result in self.profile.autocomplete.results(following: stream) {
                    yielded.append(result)
                    if let at = awaiting.removeValue(forKey: result.text) {
                        firstResults.append((ContinuousClock.now - at).benchMilliseconds)
                    }
                }
            } catch { print("bench error \(error)") }
        }
        var lastIssued = ContinuousClock.now
        for text in texts {
            lastIssued = ContinuousClock.now
            awaiting = [text: lastIssued]
            typed.yield(text)
            try? await Task.sleep(for: .milliseconds(20))
        }
        typed.finish()
        await consumer.value
        let finalLatency = (ContinuousClock.now - lastIssued).benchMilliseconds
        let allocations = MallocCounter.stop()
        meter.stop()
        try? await Task.sleep(for: .milliseconds(500))
        let jsAfter = await jsStatistics("omnibox")
        let last = texts.last ?? ""
        let finalComplete = yielded.last.map { $0.text == last && $0.isComplete } ?? false
        let stale = yielded.indices.dropLast().filter { yielded[$0].isComplete && yielded[$0].text == last }.count
        print(String(
            format: "bench services typing (results(following:), 200 texts at 20 ms): stream ended %.0f ms after the last text, last element complete for the last text: %@; %d results yielded for %d distinct texts; first result within the text's 20 ms p50 %.1f ms (for %d of the texts); result decodes %d; renderer calls %d, %.0f ms renderer time; main thread busy %.0f ms (%.1f%%); main-thread allocations %d; pending operations after: %@; in flight in the host after: %d; extra complete results for the last text %d",
            finalLatency, finalComplete ? "yes" : "NO", yielded.count, Set(yielded.map(\.text)).count,
            Percentiles(firstResults).percentile(0.5), firstResults.count, CefDiagnostics.counter(.serviceDecode).count,
            jsAfter.calls - jsBefore.calls, jsAfter.ms - jsBefore.ms, meter.busy.benchMilliseconds, meter.busyFraction * 100,
            allocations, pendingOperations, jsAfter.inFlight, stale))
    }

    func typingRun(_ texts: [String], label: String) async {
        var outcomes: [(text: String, result: Int?, cancelled: Bool, ms: Double)] = []
        var current: Task<Void, Never>?
        let meter = MainThreadMeter()
        let jsBefore = await jsStatistics("omnibox")
        CefDiagnostics.reset()
        meter.start()
        MallocCounter.start()
        var lastIssued = ContinuousClock.now
        var cancelledAt: [String: ContinuousClock.Instant] = [:]
        var cancellationLatencies: [Double] = []
        var previousText: String?
        for text in texts {
            if let previousText { cancelledAt[previousText] = ContinuousClock.now }
            current?.cancel()
            previousText = text
            let start = ContinuousClock.now
            lastIssued = start
            current = Task { @MainActor in
                do {
                    let suggestions = try await self.profile.autocomplete.suggestions(for: text)
                    outcomes.append((text, suggestions.count, Task.isCancelled, (ContinuousClock.now - start).benchMilliseconds))
                } catch {
                    if error is CancellationError, let at = cancelledAt[text] {
                        cancellationLatencies.append((ContinuousClock.now - at).benchMilliseconds)
                    }
                    outcomes.append((text, nil, error is CancellationError, (ContinuousClock.now - start).benchMilliseconds))
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await current?.value
        let finalLatency = (ContinuousClock.now - lastIssued).benchMilliseconds
        let allocations = MallocCounter.stop()
        meter.stop()
        try? await Task.sleep(for: .milliseconds(500))
        let jsAfter = await jsStatistics("omnibox")
        let delivered = outcomes.filter { ($0.result ?? 0) > 0 }
        let cancelled = outcomes.filter { $0.cancelled }
        let cancelledTimes = cancellationLatencies
        let decoded = CefDiagnostics.counter(.serviceDecode).count
        print(String(
            format: "bench services typing (%@): last query's result %.0f ms after it was issued; %d of %d queries delivered suggestions, %d ended cancelled (cancellation took %@); results decoded %d; renderer calls %d, %.0f ms renderer time; main thread busy %.0f ms (%.1f%%); main-thread allocations %d; pending operations after: %@; in flight in the host after: %d",
            label, finalLatency, delivered.count, texts.count, cancelled.count, Percentiles(cancelledTimes).description, decoded,
            jsAfter.calls - jsBefore.calls, jsAfter.ms - jsBefore.ms, meter.busy.benchMilliseconds, meter.busyFraction * 100,
            allocations, pendingOperations, jsAfter.inFlight))
    }

    var pendingOperations: String {
        "\(CefDiagnostics.census()["pending operations"] ?? 0)"
    }

    // MARK: Concurrent mix

    /// 1 000 calls at once across the hosts.
    func concurrentMix() async {
        let meter = MainThreadMeter()
        let memory = MemorySampler()
        CefDiagnostics.reset()
        memory.start()
        meter.start()
        let start = ContinuousClock.now
        var latencies: [String: [Double]] = [:]
        var failures: [String: Int] = [:]
        var firstFailure: [String: String] = [:]
        var tasks: [Task<(String, Double, String?), Never>] = []
        for i in 0..<1000 {
            tasks.append(Task { @MainActor in
                let kind: String
                let started = ContinuousClock.now
                do {
                    switch i % 5 {
                    case 0:
                        kind = "bookmarks.search"
                        _ = try await self.profile.bookmarks.search("CefSwift")
                    case 1:
                        kind = "history.search"
                        _ = try await self.profile.history.search(limit: 20)
                    case 2:
                        kind = "favicon"
                        _ = try await self.profile.history.favicon(for: self.faviconPage, size: 16)
                    case 3:
                        kind = "bookmarks.tree"
                        _ = try await self.profile.bookmarks.tree()
                    default:
                        kind = i % 50 == 4 ? "topSites" : "bookmarks.recent"
                        if kind == "topSites" {
                            _ = try await self.profile.history.topSites()
                        } else {
                            _ = try await self.profile.bookmarks.recent(limit: 10)
                        }
                    }
                } catch {
                    return ("\(i % 5)", (ContinuousClock.now - started).benchMilliseconds, "\(error)")
                }
                return (kind, (ContinuousClock.now - started).benchMilliseconds, nil)
            })
        }
        for task in tasks {
            let (kind, ms, error) = await task.value
            latencies[kind, default: []].append(ms)
            if let error {
                failures[kind, default: 0] += 1
                firstFailure[kind] = firstFailure[kind] ?? error
            }
        }
        let total = (ContinuousClock.now - start).benchMilliseconds
        meter.stop()
        memory.stop()
        print(String(
            format: "bench services 1000 concurrent mixed calls: all done in %.0f ms; main thread busy %.0f ms (%.0f%%); peak footprint +%.0f MB; failures %@; pending operations after: %@",
            total, meter.busy.benchMilliseconds, meter.busyFraction * 100, memory.peakMB - memory.startMB,
            failures.isEmpty ? "none" : "\(failures) \(firstFailure)", pendingOperations))
        for (kind, values) in latencies.sorted(by: { $0.key < $1.key }) {
            print("bench services   \(kind) (\(values.count)): \(Percentiles(values))")
        }
    }

    // MARK: Large results

    func largeHistory() async {
        _ = try? await profile.history.syntheticEntries(10)
        await measure("history page of 5 000 entries (synthetic records, history host)", host: "history", count: 10) {
            let entries = try await self.profile.history.syntheticEntries(5000)
            guard entries.count == 5000 else { throw CefError.operationFailed("got \(entries.count)") }
        }
    }

    func largeBookmarkTree() async {
        guard let folder = try? await profile.bookmarks.addFolder("CefSwift Benchmark 10k") else {
            print("bench services 10k tree: could not add the folder")
            return
        }
        defer { Task { try? await self.profile.bookmarks.remove(folder.id) } }
        var yields = 0
        let watcher = Task { for await _ in profile.bookmarks.changes { yields += 1 } }
        CefDiagnostics.reset()
        let meter = MainThreadMeter()
        meter.start()
        let start = ContinuousClock.now
        var made = 0
        // 32 adds in flight at a time.
        var next = 0
        func worker() async {
            while next < 10_000 {
                let i = next
                next += 1
                if (try? await profile.bookmarks.add(
                    URL(string: "https://bench.invalid/tree/\(i)/a-typical-address")!,
                    title: "Benchmark bookmark \(i)", in: folder.id)) != nil { made += 1 }
            }
        }
        let workers = (0..<32).map { _ in Task { @MainActor in await worker() } }
        for task in workers { await task.value }
        let addMs = (ContinuousClock.now - start).benchMilliseconds
        meter.stop()
        try? await Task.sleep(for: .milliseconds(500))
        watcher.cancel()
        print(String(
            format: "bench services 10 000 bookmark adds, 32 in flight: %.0f ms (%.0f adds/s); main thread busy %.0f ms; `changes` yields seen %d",
            addMs, Double(made) / addMs * 1000, meter.busy.benchMilliseconds, yields))
        await measure("bookmark tree with 10 000 more (service)", host: "bookmarks", count: 10) {
            _ = try await self.profile.bookmarks.tree()
        }
        profile.bookmarks.readSource = .file
        // Chromium saves the file 2.5 s after a change while a page is shown.
        _ = await SelfTest.withVisiblePage {
            await SelfTest.waitUntilAsync(timeout: .seconds(20)) {
                ((try? await self.profile.bookmarks.children(of: folder.id))?.count ?? 0) >= 10_000
            }
        }
        await measure("bookmark tree with 10 000 more (Bookmarks file)", host: nil, count: 10) {
            _ = try await self.profile.bookmarks.tree()
        }
        profile.bookmarks.readSource = .service
        try? await profile.bookmarks.remove(folder.id)
    }

    // MARK: Another page busy

    func whileAnotherPageIsBusy() async {
        let busy = CefBrowser(url: URL(string: "selftest://bench/bridge.html")!)
        let view = CefWindowedBrowserView(browser: busy)
        view.frame = SelfTest.window.contentView!.bounds
        SelfTest.window.contentView!.addSubview(view)
        defer {
            busy.close(force: true)
            view.removeFromSuperview()
        }
        guard await SelfTest.waitUntil({ busy.title == "bridge" }) else { return }
        // Busy for 20 s in 50 ms slices, with a frame drawn in between.
        _ = try? await busy.evaluateJavaScript("""
            (() => { const end = performance.now() + 20000;
              const spin = () => { const t = performance.now() + 50; while (performance.now() < t) {} if (performance.now() < end) setTimeout(spin, 0); };
              spin(); return 1; })()
            """)
        await measure("autocomplete query, another page busy", host: "omnibox", count: 40) {
            _ = try await self.profile.autocomplete.suggestions(for: "selftest edge")
        }
        await measure("history search (20), another page busy", host: "history", count: 60) {
            _ = try await self.profile.history.search(limit: 20)
        }
    }

    // MARK: Leaks

    /// 10 000 calls, then the host's JavaScript heap and the census.
    func leaks() async {
        try? await Task.sleep(for: .seconds(2))
        let before = await jsStatistics("bookmarks")
        let start = ContinuousClock.now
        for i in 0..<10_000 {
            _ = try? await profile.bookmarks.search(i % 2 == 0 ? "CefSwift" : "bench")
        }
        let elapsed = (ContinuousClock.now - start).benchMilliseconds
        try? await Task.sleep(for: .seconds(3))
        let after = await jsStatistics("bookmarks")
        print(String(
            format: "bench services leaks: 10 000 bookmark searches in %.0f ms; host JS heap %.1f MB before, %.1f MB after; in flight in the host %d; pending operations %@; census %@",
            elapsed, before.heap / 1_048_576, after.heap / 1_048_576, after.inFlight, pendingOperations,
            "\(CefDiagnostics.census().filter { $0.key.contains("pending") || $0.key.contains("payload") || $0.key.contains("shared") })"))
    }
}

/// p50, p95 and p99 of a set of milliseconds.
struct Percentiles: CustomStringConvertible {
    let values: [Double]

    init(_ values: [Double]) { self.values = values.sorted() }

    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        return values[min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))]
    }

    var description: String {
        values.isEmpty ? "no samples"
            : String(format: "p50 %.2f ms, p95 %.2f ms, p99 %.2f ms (n %d)", percentile(0.5), percentile(0.95), percentile(0.99), values.count)
    }
}
