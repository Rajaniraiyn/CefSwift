import AppKit
import CefChromium
import CefKit

/// `-benchmarkServices YES`: instead of the checks, calls each internal-page
/// service once cold and five times warm, through the public API only, and
/// pauses after each step for `Scripts/measure-services.py` to read the
/// footprint of every process.
///
/// Each step prints `bench <step> cold <ms> warm <ms>`, then
/// `bench-measure <step>`, and waits for a line on standard input.
@MainActor
enum ServiceBenchmark {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "benchmarkServices") }

    static func run() async {
        let profile = CefProfile.default
        // A page for history, most-visited and favicons to know about, and a
        // hidden Chrome-style tab for the discard queries.
        let visited = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/favicon.html")!))
        _ = await SelfTest.waitUntil { visited.browser.favicon != nil }
        visited.close()
        _ = await SelfTest.waitUntil { visited.isClosed }
        let tab = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://app/second.html")!))
        _ = await SelfTest.waitUntil { tab.browser.title == "second" }
        try? await Task.sleep(for: .seconds(3))
        await pause("idle")

        await step("bookmarks.tree") { _ = try await profile.bookmarks.tree() }
        await step("history.search") { _ = try await profile.history.search(limit: 20) }
        await step("history.mostVisited") { _ = try await profile.history.mostVisited() }
        await step("history.favicon") {
            _ = try await profile.history.favicon(for: URL(string: "selftest://edge/favicon.html")!, size: 32)
        }
        await step("autocomplete.suggestions") { _ = try await profile.autocomplete.suggestions(for: "selftest") }
        await step("discardBlockers") { _ = await tab.browser.discardBlockers() }
        await step("all, concurrently") {
            async let a = profile.bookmarks.recent(limit: 5)
            async let b = profile.history.search(limit: 5)
            async let c = profile.history.mostVisited()
            async let d = profile.autocomplete.suggestions(for: "selftest")
            async let e = tab.browser.discardBlockers()
            _ = try await (a, b, c, d, e)
        }
        let idle = Double(ProcessInfo.processInfo.environment["CEFSWIFT_BENCH_IDLE"] ?? "") ?? 0
        if idle > 0 {
            try? await Task.sleep(for: .seconds(idle))
            await pause("after \(Int(idle)) s without calls")
            await step("bookmarks.tree after idle") { _ = try await profile.bookmarks.tree() }
        }
        tab.close()
        _ = await SelfTest.waitUntil { tab.isClosed }
    }

    private static func step(_ name: String, _ body: () async throws -> Void) async {
        let cold = await time(body)
        var warm: [Double] = []
        for _ in 0..<5 { warm.append(await time(body)) }
        warm.sort()
        print(String(format: "bench %@ cold %.0f warm %.0f", name, cold, warm[2]))
        try? await Task.sleep(for: .seconds(2))
        await pause(name)
    }

    private static func time(_ body: () async throws -> Void) async -> Double {
        let start = ContinuousClock.now
        do { try await body() } catch { print("bench error \(error)") }
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func pause(_ name: String) async {
        print("bench-measure \(name)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                _ = readLine()
                continuation.resume()
            }
        }
    }
}
