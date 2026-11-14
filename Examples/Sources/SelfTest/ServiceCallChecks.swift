import AppKit
@_spi(Testing) import CefChromium
@_spi(Testing) import CefKit

/// Service calls under the conditions an app puts them in: cancelled,
/// superseded, in flight while their host dies, by the thousand. Each
/// check bounds time only to tell "promptly" from "never": the timings
/// themselves are `-benchmark services`'s, on an idle Mac.
extension SelfTest {
    static func serviceCallChecks() async {
        let profile = CefProfile.default
        let idleTimeout = CefProfile.serviceIdleTimeout
        CefProfile.serviceIdleTimeout = .seconds(60)
        defer { CefProfile.serviceIdleTimeout = idleTimeout }
        await cancelledStartUpChecks(profile)
        // Warm: the checks are about calls, not start-ups.
        _ = try? await profile.history.search(limit: 1)
        _ = try? await profile.autocomplete.suggestions(for: "selftest")

        await cancellationChecks(profile)
        await supersedingChecks(profile)
        await faviconChecks(profile)
        await midFlightChecks(profile)
        await loadChecks(profile)
    }

    private static var pendingOperations: Int { CefDiagnostics.census()["pending operations"] ?? 0 }

    private static func statistics(_ profile: CefProfile, _ host: String) async -> (inFlight: Int, aborts: Int, heap: Double) {
        let json = await profile.serviceHostStatistics(named: host)
        return (json?["inFlight"].intValue ?? -1, json?["aborts"].intValue ?? -1, json?["heap"].doubleValue ?? 0)
    }

    // MARK: Cancellation

    /// The very first call to a host, cancelled while the host starts: the
    /// start-up goes on, and the next call finds a host it can use, its
    /// runtime installed.
    private static func cancelledStartUpChecks(_ profile: CefProfile) async {
        profile.stopServiceHosts()
        _ = await waitUntil { !profile.runningServiceHosts.contains("history") }
        let first = Task { @MainActor in try await profile.history.search(limit: 1) }
        let starting = await waitUntil(timeout: .seconds(5)) { profile.runningServiceHosts.contains("history") }
        first.cancel()
        let result = await first.result
        var isCancellation = false
        if case .failure(let error) = result { isCancellation = error is CancellationError }
        check("service calls: the first call, cancelled while its host starts, throws CancellationError",
              starting && isCancellation, detail: "\(result)")
        // The caller resumed at once; the start-up, and what the cancelled
        // call does after it, go on. The next call comes after both.
        try? await Task.sleep(for: .seconds(2))
        await expect("service calls: … and the next call on that host answers") {
            _ = try await profile.history.search(limit: 1)
            return (true, "")
        }
        await expect("service calls: … and so does a call of another module") {
            _ = try await profile.history.favicon(for: URL(string: "https://cefswift.test/never-visited.html")!)
            return (true, "")
        }
    }

    private static func cancellationChecks(_ profile: CefProfile) async {
        let pendingBefore = pendingOperations
        let abortsBefore = await statistics(profile, "history").aborts
        let call = Task { @MainActor in try await profile.slowHistoryCall(lasting: .seconds(20), isIdempotent: true) }
        let started = await waitUntilAsync { await statistics(profile, "history").inFlight == 1 }
        let cancelledAt = ContinuousClock.now
        call.cancel()
        let result = await call.result
        let resumedAfter = ContinuousClock.now - cancelledAt
        var isCancellation = false
        if case .failure(let error) = result { isCancellation = error is CancellationError }
        check("service calls: a cancelled call resumes promptly with CancellationError",
              started && isCancellation && resumedAfter < .seconds(1), detail: "\(result), after \(resumedAfter)")
        let aborted = await waitUntilAsync {
            let stats = await statistics(profile, "history")
            return stats.inFlight == 0 && stats.aborts == abortsBefore + 1
        }
        let stats = await statistics(profile, "history")
        check("service calls: cancelling aborts the call's work in the host and leaves nothing pending",
              aborted && pendingOperations == pendingBefore,
              detail: "in flight \(stats.inFlight), aborts \(stats.aborts - abortsBefore), pending \(pendingOperations - pendingBefore)")

        let query = Task { @MainActor in try await profile.autocomplete.suggestions(for: "selftest edge") }
        await Task.yield()
        let queryCancelledAt = ContinuousClock.now
        query.cancel()
        let queryResult = await query.result
        var queryCancelled = false
        if case .failure(let error) = queryResult { queryCancelled = error is CancellationError }
        let queryResumedAfter = ContinuousClock.now - queryCancelledAt
        let settled = await waitUntilAsync { await statistics(profile, "omnibox").inFlight == 0 }
        check("autocomplete: a cancelled query stops promptly and leaves no pending operation",
              queryCancelled && queryResumedAfter < .seconds(1) && settled && pendingOperations == pendingBefore,
              detail: "\(queryResult), after \(queryResumedAfter), pending \(pendingOperations - pendingBefore)")
    }

    // MARK: Latest wins

    private static func supersedingChecks(_ profile: CefProfile) async {
        let first = Task { @MainActor in try await profile.autocomplete.suggestions(for: "self") }
        await Task.yield()
        let secondCount = (try? await profile.autocomplete.suggestions(for: "selftest"))?.count ?? -1
        let firstResult = await first.result
        var firstCancelled = false
        if case .failure(let error) = firstResult { firstCancelled = error is CancellationError }
        check("autocomplete: a newer query supersedes the one before, which throws CancellationError",
              firstCancelled && secondCount > 0, detail: "first \(firstResult), second \(secondCount) suggestions")

        // Typed back to back: only the last text's results arrive.
        let (texts, typed) = AsyncStream.makeStream(of: String.self)
        let typedTexts = ["s", "se", "sel", "self", "selft", "selfte", "selftes", "selftest"]
        for text in typedTexts { typed.yield(text) }
        typed.finish()
        var seen: [CefAutocomplete.Result] = []
        do {
            for try await result in profile.autocomplete.results(following: texts) { seen.append(result) }
        } catch {
            check("autocomplete: superseded queries deliver nothing", false, detail: "\(error)")
            return
        }
        check("autocomplete: superseded queries deliver nothing; the last ends complete",
              !seen.isEmpty && seen.allSatisfy { $0.text == "selftest" } && seen.last?.isComplete == true
                  && seen.last?.suggestions.isEmpty == false,
              detail: seen.map { "\($0.text)\($0.isComplete ? " (complete)" : "") \($0.suggestions.count)" }.joined(separator: ", "))

        // A stream ends as soon as a newer query starts.
        let stream = profile.autocomplete.results(for: "selftest edge")
        _ = profile.autocomplete.results(for: "selftest")
        var ended = false
        var count = 0
        let consumer = Task { @MainActor in
            for try await _ in stream { count += 1 }
            ended = true
        }
        check("autocomplete: a superseded stream ends", await waitUntil(timeout: .seconds(5)) { ended },
              detail: "\(count) results")
        consumer.cancel()
        _ = await waitUntilAsync { await statistics(profile, "omnibox").inFlight == 0 }
    }

    // MARK: Favicons

    private static func faviconChecks(_ profile: CefProfile) async {
        let page = URL(string: "selftest://edge/favicon.html")!
        // The page shows a solid red 32-pixel icon (`EdgePages.iconPNG`).
        let visited = CefWindow(browser: CefBrowser(url: page))
        _ = await waitUntil { visited.browser.favicon != nil }
        visited.close()
        _ = await waitUntil { visited.isClosed }
        await expect("favicons: the icon's pixels arrive intact") {
            let icon = try await profile.history.favicon(for: page, size: 16)
            guard let image = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return (false, "no icon")
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.interpolationQuality = .none
                // The image's centre pixel, drawn into the 1 × 1 context.
                context?.draw(image, in: CGRect(
                    x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                    width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            let red = pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60 && pixel[3] > 200
            return (red && image.width == image.height && icon?.size == NSSize(width: 16, height: 16),
                    "\(image.width) × \(image.height), centre \(pixel)")
        }
        await expect("favicons: one call answers for a list, leaving out pages without an icon") {
            let unknown = URL(string: "https://never-visited.invalid/icon-check")!
            let icons = try await profile.history.favicons(for: [page, unknown], size: 16)
            return (icons[page] != nil && icons[unknown] == nil, "\(icons.keys.map(\.absoluteString))")
        }
    }

    // MARK: A host that stops mid-call

    private static func midFlightChecks(_ profile: CefProfile) async {
        _ = try? await profile.history.search(limit: 1)
        let idempotent = Task { @MainActor in try await profile.slowHistoryCall(lasting: .seconds(2), isIdempotent: true) }
        _ = await waitUntilAsync { await statistics(profile, "history").inFlight == 1 }
        await profile.crashServiceHost(named: "history")
        let retried = await idempotent.result
        var retriedOK = false
        if case .success = retried { retriedOK = true }
        check("service calls: an idempotent call whose host crashes mid-call is made again on a new host",
              retriedOK && profile.runningServiceHosts.contains("history"), detail: "\(retried)")

        let change = Task { @MainActor in try await profile.slowHistoryCall(lasting: .seconds(2), isIdempotent: false) }
        _ = await waitUntilAsync { await statistics(profile, "history").inFlight == 1 }
        await profile.crashServiceHost(named: "history")
        let failed = await change.result
        var message = ""
        if case .failure(let error) = failed { message = "\(error)" }
        check("service calls: a call that may not run twice fails with a clear error when its host crashes",
              message.contains("stopped responding"), detail: message.isEmpty ? "\(failed)" : message)

        profile.stopServiceHosts()
        _ = await waitUntil { profile.runningServiceHosts.isEmpty }
        await expect("service calls: the next call after a host stopped starts a new one") {
            _ = try await profile.history.search(limit: 1)
            return profile.runningServiceHosts.contains("history")
        }
    }

    // MARK: Load

    /// 1 000 calls at once, then 2 000 one after another: everything
    /// answers, nothing stays pending, and the host's heap does not grow
    /// with the calls.
    private static func loadChecks(_ profile: CefProfile) async {
        let pendingBefore = pendingOperations
        let page = URL(string: "selftest://edge/favicon.html")!
        let start = ContinuousClock.now
        var failures: [String] = []
        let calls = (0..<1000).map { i in
            Task { @MainActor () -> String? in
                do {
                    switch i % 4 {
                    case 0: _ = try await profile.bookmarks.search("CefSwift")
                    case 1: _ = try await profile.history.search(limit: 20)
                    case 2: _ = try await profile.history.favicon(for: page)
                    default: _ = try await profile.bookmarks.recent(limit: 10)
                    }
                    return nil
                } catch {
                    return "\(error)"
                }
            }
        }
        for call in calls { if let failure = await call.value { failures.append(failure) } }
        let elapsed = ContinuousClock.now - start
        check("service calls: 1 000 concurrent calls all answer and leave nothing pending",
              failures.isEmpty && pendingOperations == pendingBefore && elapsed < .seconds(60),
              detail: "\(elapsed), \(failures.count) failures \(failures.prefix(2)), pending \(pendingOperations - pendingBefore)")

        let host = profile.bookmarks.readSource
        profile.bookmarks.readSource = .service
        defer { profile.bookmarks.readSource = host }
        _ = try? await profile.bookmarks.search("CefSwift")
        try? await Task.sleep(for: .seconds(1))
        let heapBefore = await statistics(profile, "bookmarks").heap
        for i in 0..<2000 { _ = try? await profile.bookmarks.search(i % 2 == 0 ? "CefSwift" : "selftest") }
        try? await Task.sleep(for: .seconds(2))
        let after = await statistics(profile, "bookmarks")
        let growthMB = (after.heap - heapBefore) / 1_048_576
        check("service calls: 2 000 calls leave the host's JavaScript heap as it was",
              heapBefore > 0 && growthMB < 16 && after.inFlight == 0 && pendingOperations == pendingBefore,
              detail: String(format: "%.1f MB before, %+.1f MB after, %d in flight", heapBefore / 1_048_576, growthMB, after.inFlight))
    }
}
