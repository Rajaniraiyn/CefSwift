import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import os

/// Requests the app makes through a profile's network stack
/// (`CefProfile.data(for:)`, `bytes(for:)`, `download(for:to:)`), against
/// a local HTTP server of the group's own and the `selftest` scheme
/// handler: methods, bodies, headers, cookies shared with pages, redirects,
/// authentication, streaming with a bounded buffer, cancellation, timeouts,
/// errors, profile isolation, and that nothing is left alive.
extension SelfTest {
    static func urlRequestChecks() async {
        guard let server = try? await LocalServer.start() else {
            skip("urlRequest", because: "could not start a local HTTP server", .environment)
            return
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let profile = CefProfile.incognito()

        await basicRequestChecks(base: base, profile: profile)
        await cookieRequestChecks(base: base, profile: profile)
        await redirectAndAuthenticationChecks(base: base, profile: profile)
        await streamingRequestChecks(base: base, profile: profile, server: server)
        await failingRequestChecks(base: base, profile: profile)
        await isolationRequestChecks(base: base, profile: profile)

        let leftover = { () -> [String: Int] in
            CefDiagnostics.census().filter {
                $0.key.contains("URLRequestLoader") || $0.key.contains("urlrequest") || $0.key.contains("auth_callback")
            }
        }
        check("urlRequest: no request, client or callback is left alive",
              await waitUntil(timeout: .seconds(5)) { leftover().isEmpty }, detail: "\(leftover())")
    }

    // MARK: Methods, bodies, headers

    static func basicRequestChecks(base: String, profile: CefProfile) async {
        let threads = ThreadNames()
        var configuration = CefProfile.RequestConfiguration()
        configuration.downloadProgress = { _ in threads.record() }
        do {
            let (data, response) = try await profile.data(for: URLRequest(url: URL(string: "\(base)/echo?get")!), configuration: configuration)
            check("urlRequest: a GET returns the status, headers and body",
                  response.statusCode == 200 && data.isEmpty && response.value(forHTTPHeaderField: "X-Echo-Method") == "GET",
                  detail: "\(response.statusCode) \(response.allHeaderFields)")
            check("urlRequest: a repeated response header is joined",
                  response.value(forHTTPHeaderField: "X-Multi") == "a, b",
                  detail: "\(String(describing: response.value(forHTTPHeaderField: "X-Multi")))")
            check("urlRequest: the response URL is the request's", response.url?.absoluteString == "\(base)/echo?get",
                  detail: "\(String(describing: response.url))")
            let language = response.value(forHTTPHeaderField: "X-Echo-Accept-Language") ?? ""
            check("urlRequest: Chromium adds the profile's Accept-Language", !language.isEmpty, detail: language)
        } catch {
            check("urlRequest: a GET returns the status, headers and body", false, detail: "\(error)")
        }
        check("urlRequest: the client is called on Chromium's IO thread",
              !threads.names.isEmpty && threads.names.allSatisfy { $0 == "Chrome_IOThread" },
              detail: "\(Set(threads.names))")

        // POST with a body, echoed back, with upload progress.
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        var post = URLRequest(url: URL(string: "\(base)/echo?post")!)
        post.httpMethod = "POST"
        post.httpBody = payload
        post.setValue("application/x-selftest", forHTTPHeaderField: "Content-Type")
        post.setValue("\(base)/referrer-page", forHTTPHeaderField: "Referer")
        let uploads = ProgressLog()
        var postConfiguration = CefProfile.RequestConfiguration()
        postConfiguration.uploadProgress = { uploads.record($0) }
        do {
            let (data, response) = try await profile.data(for: post, configuration: postConfiguration)
            check("urlRequest: a POST body arrives and is echoed back",
                  data == payload && response.value(forHTTPHeaderField: "X-Echo-Method") == "POST",
                  detail: "\(data.count) bytes back, \(response.allHeaderFields)")
            check("urlRequest: the request's headers and referrer are sent",
                  response.value(forHTTPHeaderField: "X-Echo-Content-Type") == "application/x-selftest"
                      && response.value(forHTTPHeaderField: "X-Echo-Referer") == "\(base)/referrer-page",
                  detail: "\(response.allHeaderFields)")
            let last = uploads.values.last
            check("urlRequest: upload progress reaches the body's size",
                  last?.completed == Int64(payload.count) && last?.total == Int64(payload.count),
                  detail: "\(uploads.values.suffix(3))")
        } catch {
            check("urlRequest: a POST body arrives and is echoed back", false, detail: "\(error)")
        }

        // A file body, read by Chromium.
        let file = FileManager.default.temporaryDirectory.appending(path: "selftest-upload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        await expect("urlRequest: a file body is sent") {
            try payload.write(to: file)
            var fileConfiguration = CefProfile.RequestConfiguration()
            fileConfiguration.bodyFile = file
            var put = URLRequest(url: URL(string: "\(base)/echo?file")!)
            put.httpMethod = "PUT"
            let (data, _) = try await profile.data(for: put, configuration: fileConfiguration)
            return (data == payload, "\(data.count) bytes back")
        }

        // An HTTP error status is a response.
        do {
            let (data, response) = try await profile.data(from: URL(string: "\(base)/status?418")!)
            check("urlRequest: an error status is a response, not an error",
                  response.statusCode == 418 && String(decoding: data, as: UTF8.self) == "teapot",
                  detail: "\(response.statusCode)")
        } catch {
            check("urlRequest: an error status is a response, not an error", false, detail: "\(error)")
        }

        // The app's own scheme handler answers too.
        do {
            let (data, response) = try await profile.data(from: URL(string: "selftest://app/second.html")!)
            check("urlRequest: a registered scheme handler answers",
                  response.statusCode == 200 && String(decoding: data, as: UTF8.self).contains("<title>second</title>"),
                  detail: "\(response.statusCode) \(data.count) bytes")
        } catch {
            check("urlRequest: a registered scheme handler answers", false, detail: "\(error)")
        }

        // Into a file.
        let destination = FileManager.default.temporaryDirectory.appending(path: "selftest-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        await expect("urlRequest: a download is written to its file") {
            let response = try await profile.download(for: URLRequest(url: URL(string: "\(base)/large?3000000")!), to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (response.statusCode == 200 && size == 3_000_000, "\(size) bytes")
        }
    }

    // MARK: Cookies shared with pages

    static func cookieRequestChecks(base: String, profile: CefProfile) async {
        var browserConfiguration = CefBrowser.Configuration()
        browserConfiguration.profile = profile
        let browser = CefBrowser(url: URL(string: "\(base)/page")!, configuration: browserConfiguration)
        let view = hostWindowed(browser)
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(browser, title: "page") else {
            check("urlRequest: the cookie page loads", false, detail: "title '\(browser.title)'")
            return
        }
        do {
            _ = try await browser.evaluateJavaScript("document.cookie = 'fromPage=yes; path=/'; 0")
            let (_, response) = try await profile.data(from: URL(string: "\(base)/echo?cookies")!)
            let cookies = response.value(forHTTPHeaderField: "X-Echo-Cookie") ?? ""
            check("urlRequest: a cookie a page set is sent with the request", cookies.contains("fromPage=yes"),
                  detail: "Cookie: '\(cookies)'")

            _ = try await profile.data(from: URL(string: "\(base)/set-cookie")!)
            let seen = try await browser.evaluateJavaScript("document.cookie").stringValue ?? ""
            check("urlRequest: a cookie the request received is visible to the page", seen.contains("fromRequest=yes"),
                  detail: "document.cookie '\(seen)'")

            var withoutCookies = URLRequest(url: URL(string: "\(base)/echo?no-cookies")!)
            withoutCookies.httpShouldHandleCookies = false
            let (_, bare) = try await profile.data(for: withoutCookies)
            check("urlRequest: httpShouldHandleCookies = false sends none",
                  (bare.value(forHTTPHeaderField: "X-Echo-Cookie") ?? "").isEmpty,
                  detail: "\(String(describing: bare.value(forHTTPHeaderField: "X-Echo-Cookie")))")
        } catch {
            check("urlRequest: a cookie a page set is sent with the request", false, detail: "\(error)")
        }
    }

    // MARK: Redirects and authentication

    static func redirectAndAuthenticationChecks(base: String, profile: CefProfile) async {
        do {
            let (_, response) = try await profile.data(from: URL(string: "\(base)/redirect")!)
            check("urlRequest: a redirect is followed",
                  response.statusCode == 200 && response.url?.absoluteString == "\(base)/echo?redirected",
                  detail: "\(response.statusCode) \(String(describing: response.url))")
        } catch {
            check("urlRequest: a redirect is followed", false, detail: "\(error)")
        }
        do {
            var configuration = CefProfile.RequestConfiguration()
            configuration.stopsAtRedirects = true
            let (_, response) = try await profile.data(from: URL(string: "\(base)/redirect")!, configuration: configuration)
            check("urlRequest: stopsAtRedirects returns the redirect",
                  response.statusCode == 302 && response.value(forHTTPHeaderField: "Location") == "/echo?redirected",
                  detail: "\(response.statusCode) \(response.allHeaderFields)")
        } catch {
            check("urlRequest: stopsAtRedirects returns the redirect", false, detail: "\(error)")
        }

        await expect("urlRequest: without a credential the 401 is the response") {
            let (_, response) = try await profile.data(from: URL(string: "\(base)/private")!)
            return (response.statusCode == 401, "\(response.statusCode)")
        }
        do {
            let challenges = ChallengeLog()
            var configuration = CefProfile.RequestConfiguration()
            configuration.credential = { challenge in
                challenges.record(challenge)
                return CefCredential(username: "ada", password: "lovelace")
            }
            let (data, response) = try await profile.data(from: URL(string: "\(base)/private?answered")!, configuration: configuration)
            let challenge = challenges.values.first
            check("urlRequest: the credential closure answers a challenge",
                  response.statusCode == 200 && String(decoding: data, as: UTF8.self) == LocalServer.authorized
                      && challenge?.realm == "selftest" && challenge?.isProxy == false && challenge?.host == "127.0.0.1",
                  detail: "\(response.statusCode) \(challenges.values)")
        } catch {
            check("urlRequest: the credential closure answers a challenge", false, detail: "\(error)")
        }
    }

    // MARK: Streaming, cancellation, timeouts

    static func streamingRequestChecks(base: String, profile: CefProfile, server: LocalServer) async {
        let size = 64 << 20
        let sampler = MemorySampler()
        sampler.start()
        do {
            let limit = CefProfile.RequestConfiguration().streamMemoryLimit
            let (body, response) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/large?\(size)")!))
            // Read off the main actor, as a parser would.
            let read = try await readLarge(body)
            sampler.stop()
            let growth = sampler.peakMB - sampler.startMB
            print(String(format: "NOTE urlRequest: 64 MB streamed in %d chunks, at most %d bytes unread in memory, %lld on disk and %d waiting for the disk, footprint +%.0f MB",
                         read.chunks, body.peakUnreadBytesInMemory, body.peakUnreadBytesOnDisk, body.peakUnwrittenBytes, growth))
            check("urlRequest: a 64 MB body streams whole",
                  response.statusCode == 200 && response.expectedContentLength == Int64(size) && read.bytes == size && read.isExact,
                  detail: "\(read.bytes) bytes in \(read.chunks) chunks, exact \(read.isExact)")
            check("urlRequest: the stream's unread bytes in memory stay under its limit", body.peakUnreadBytesInMemory <= limit,
                  detail: "peak \(body.peakUnreadBytesInMemory) bytes")
            let unwrittenMB = Double(body.peakUnwrittenBytes) / 1_048_576
            check("urlRequest: streaming 64 MB does not hold the body in memory", growth - unwrittenMB < 40,
                  detail: String(format: "footprint +%.0f MB, at most %.0f MB waiting for the disk", growth, unwrittenMB))
        } catch {
            sampler.stop()
            check("urlRequest: a 64 MB body streams whole", false, detail: "\(error)")
        }

        // A reader far slower than the network: the rest waits on disk, and
        // it still gets every byte.
        let slowSampler = MemorySampler()
        slowSampler.start()
        do {
            var configuration = CefProfile.RequestConfiguration()
            configuration.streamMemoryLimit = 1 << 20
            let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/large?\(size)")!), configuration: configuration)
            let read = try await readLarge(body, pause: .milliseconds(100), every: 1, delay: .milliseconds(1))
            slowSampler.stop()
            let growth = slowSampler.peakMB - slowSampler.startMB
            print(String(format: "NOTE urlRequest: a slow reader took 64 MB in %d chunks; %lld bytes went through disk, at most %lld at once and %d waiting for the disk; footprint +%.0f MB",
                         read.chunks, body.spilledBytes, body.peakUnreadBytesOnDisk, body.peakUnwrittenBytes, growth))
            check("urlRequest: a slow reader gets every byte of a 64 MB body, in order",
                  read.bytes == size && read.isExact, detail: "\(read.bytes) bytes, exact \(read.isExact)")
            check("urlRequest: a slow reader's stream spills to disk, keeping memory under its limit",
                  body.spilledBytes > 0 && body.peakUnreadBytesInMemory <= configuration.streamMemoryLimit,
                  detail: "\(body.spilledBytes) spilled, peak \(body.peakUnreadBytesInMemory) in memory")
            // Chunks wait in memory only until the disk takes them: from a
            // local server the network can outrun the disk for a while.
            let unwrittenMB = Double(body.peakUnwrittenBytes) / 1_048_576
            check("urlRequest: a slow reader's 64 MB do not stay in memory once written", growth - unwrittenMB < 24,
                  detail: String(format: "footprint +%.0f MB, at most %.0f MB waiting for the disk", growth, unwrittenMB))
        } catch {
            slowSampler.stop()
            check("urlRequest: a slow reader gets every byte of a 64 MB body, in order", false, detail: "\(error)")
        }

        // The same reader on the main actor, against the default profile's
        // directory.
        await expect("urlRequest: a stream spills into a persistent profile's directory and leaves nothing there") {
            var configuration = CefProfile.RequestConfiguration()
            configuration.streamMemoryLimit = 256 << 10
            let persistent = CefProfile.default
            let (body, _) = try await persistent.bytes(for: URLRequest(url: URL(string: "\(base)/large?\(8 << 20)")!), configuration: configuration)
            try await Task.sleep(for: .milliseconds(300))
            var check = LargeBodyCheck()
            for try await chunk in body { check.feed(chunk) }
            let leftovers = spillFiles(in: persistent.spillDirectory)
            return (check.bytes == 8 << 20 && check.isExact && body.spilledBytes > 0 && leftovers.isEmpty,
                    "\(check.bytes) bytes, exact \(check.isExact), \(body.spilledBytes) spilled into \(persistent.spillDirectory.path), left \(leftovers)")
        }

        // Without spilling, a reader that falls behind ends the request.
        await expect("urlRequest: with .fail, a reader past the stream's memory limit gets ERR_INSUFFICIENT_RESOURCES") {
            var configuration = CefProfile.RequestConfiguration()
            configuration.streamMemoryLimit = 256 << 10
            configuration.streamOverflow = .fail
            let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/large?\(32 << 20)")!), configuration: configuration)
            var outcome = "finished"
            do {
                for try await _ in body { try await Task.sleep(for: .milliseconds(20)) }
            } catch let error as CefLoadError {
                outcome = "\(error.code)"
            }
            return (outcome == "-12" && body.spilledBytes == 0, "\(outcome), \(body.spilledBytes) spilled")
        }

        // A capped spill fails the same way once the file is full.
        await expect("urlRequest: a reader past the spill limit gets ERR_INSUFFICIENT_RESOURCES after the bytes before it") {
            var configuration = CefProfile.RequestConfiguration()
            configuration.streamMemoryLimit = 256 << 10
            configuration.streamOverflow = .spillToDisk(limit: 1 << 20)
            let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/large?\(32 << 20)")!), configuration: configuration)
            try await Task.sleep(for: .milliseconds(300))
            var check = LargeBodyCheck()
            var outcome = "finished"
            do {
                for try await chunk in body { check.feed(chunk) }
            } catch let error as CefLoadError {
                outcome = "\(error.code)"
            }
            return (outcome == "-12" && check.isExact && check.bytes >= 1 << 20 && body.peakUnreadBytesOnDisk <= 1 << 20,
                    "\(outcome) after \(check.bytes) bytes (exact \(check.isExact)), peak \(body.peakUnreadBytesOnDisk) on disk")
        }

        // Cancelling while the reader is behind and the rest is on disk.
        let closedBeforeSpill = server.closedSlowConnections
        let spilling = SpillProbe()
        let spillTask = Task { @MainActor () -> String in
            do {
                var configuration = CefProfile.RequestConfiguration()
                configuration.streamMemoryLimit = 256 << 10
                let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/burst?\(8 << 20)")!), configuration: configuration)
                spilling.body = body
                for try await _ in body { try await Task.sleep(for: .seconds(30)) }
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }
        let spilled = await waitUntil(timeout: .seconds(5)) { (spilling.body?.spilledBytes ?? 0) >= 4 << 20 }
        let hadFile = spilling.body?.hasSpillFile == true && CefProfile.ResponseBody.openSpillFileCount > 0
        spillTask.cancel()
        let spillOutcome = await spillTask.value
        check("urlRequest: cancelling mid-spill throws CancellationError", spilled && hadFile && spillOutcome == "cancelled",
              detail: "\(spillOutcome), \(spilling.body?.spilledBytes ?? -1) spilled, file \(hadFile)")
        check("urlRequest: cancelling mid-spill closes the spill file and the connection",
              await waitUntil(timeout: .seconds(5)) {
                  CefProfile.ResponseBody.openSpillFileCount == 0 && spilling.body?.hasSpillFile == false
                      && server.closedSlowConnections > closedBeforeSpill
              },
              detail: "\(CefProfile.ResponseBody.openSpillFileCount) open")
        spilling.body = nil

        check("urlRequest: no spill file is left open or on disk",
              await waitUntil(timeout: .seconds(5)) { CefProfile.ResponseBody.openSpillFileCount == 0 }
                  && spillFiles(in: profile.spillDirectory).isEmpty,
              detail: "\(CefProfile.ResponseBody.openSpillFileCount) open, \(spillFiles(in: profile.spillDirectory)) in \(profile.spillDirectory.path)")

        // A download goes straight to its file, however large.
        let bigDownload = FileManager.default.temporaryDirectory.appending(path: "selftest-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: bigDownload) }
        await expect("urlRequest: a 64 MB download is written whole") {
            let response = try await profile.download(for: URLRequest(url: URL(string: "\(base)/large?\(size)")!), to: bigDownload)
            var check = LargeBodyCheck()
            check.feed(try Data(contentsOf: bigDownload, options: .alwaysMapped))
            return (response.statusCode == 200 && check.bytes == size && check.isExact, "\(check.bytes) bytes, exact \(check.isExact)")
        }

        // Cancelling the task mid-body.
        let closedBefore = server.closedSlowConnections
        let task = Task { @MainActor () -> String in
            do {
                let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/slow?cancel")!))
                for try await _ in body {}
                return "finished"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }
        _ = await waitUntil(timeout: .seconds(5)) { server.slowRequests.contains("/slow?cancel") }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let outcome = await task.value
        check("urlRequest: cancelling the task mid-body throws CancellationError", outcome == "cancelled", detail: outcome)
        check("urlRequest: cancelling closes the connection",
              await waitUntil(timeout: .seconds(5)) { server.closedSlowConnections > closedBefore })

        // Leaving the loop early.
        do {
            let before = server.closedSlowConnections
            let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/slow?break")!))
            for try await _ in body { break }
            check("urlRequest: leaving the loop early cancels the request",
                  await waitUntil(timeout: .seconds(5)) { server.closedSlowConnections > before })
        } catch {
            check("urlRequest: leaving the loop early cancels the request", false, detail: "\(error)")
        }

        // No progress within timeoutInterval.
        var slow = URLRequest(url: URL(string: "\(base)/slow?timeout")!)
        slow.timeoutInterval = 1
        let started = ContinuousClock.now
        do {
            _ = try await profile.data(for: slow)
            check("urlRequest: a stalled response times out", false, detail: "it finished")
        } catch let error as CefLoadError {
            let elapsed = (ContinuousClock.now - started).seconds
            check("urlRequest: a stalled response times out", error.code == -7 && error.urlError.code == .timedOut && elapsed < 5,
                  detail: "\(error) after \(elapsed) s")
        } catch {
            check("urlRequest: a stalled response times out", false, detail: "\(error)")
        }
    }

    /// Reads a `/large` body on Swift's concurrent executor, checking each
    /// byte: after `pause`, then waiting `delay` every `every` chunks.
    nonisolated static func readLarge(_ body: CefProfile.ResponseBody, pause: Duration = .zero, every: Int = 0, delay: Duration = .zero)
        async throws -> (bytes: Int, chunks: Int, isExact: Bool)
    {
        if pause > .zero { try await Task.sleep(for: pause) }
        var check = LargeBodyCheck()
        var chunks = 0
        for try await chunk in body {
            check.feed(chunk)
            chunks += 1
            if every > 0, chunks % every == 0 { try await Task.sleep(for: delay) }
        }
        return (check.bytes, chunks, check.isExact)
    }

    /// Spill files CefKit left by name in `directory`; they are unlinked
    /// as soon as they are made, so there should be none.
    static func spillFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".cefswift-response-") }
    }

    // MARK: Errors

    static func failingRequestChecks(base: String, profile: CefProfile) async {
        do {
            _ = try await profile.data(from: URL(string: "http://cefswift-selftest.invalid/")!)
            check("urlRequest: an unknown host fails", false, detail: "it loaded")
        } catch let error as CefLoadError {
            check("urlRequest: an unknown host fails with ERR_NAME_NOT_RESOLVED",
                  error.code == -105 && error.message == "net::ERR_NAME_NOT_RESOLVED" && error.urlError.code == .cannotFindHost,
                  detail: "\(error)")
        } catch {
            check("urlRequest: an unknown host fails with ERR_NAME_NOT_RESOLVED", false, detail: "\(error)")
        }
        // A port nothing listens on any more.
        let closed = try? await LocalServer.start()
        closed?.stop()
        do {
            _ = try await profile.data(from: URL(string: "http://127.0.0.1:\(closed?.port ?? 1)/")!)
            check("urlRequest: a closed port fails", false, detail: "it loaded")
        } catch let error as CefLoadError {
            check("urlRequest: a closed port fails with ERR_CONNECTION_REFUSED", error.code == -102, detail: "\(error)")
        } catch {
            check("urlRequest: a closed port fails with ERR_CONNECTION_REFUSED", false, detail: "\(error)")
        }
        do {
            var request = URLRequest(url: URL(string: "\(base)/echo?only-cache")!)
            request.cachePolicy = .returnCacheDataDontLoad
            _ = try await profile.data(for: request)
            check("urlRequest: returnCacheDataDontLoad fails for an uncached URL", false, detail: "it loaded")
        } catch let error as CefLoadError {
            check("urlRequest: returnCacheDataDontLoad fails for an uncached URL", error.code == -400, detail: "\(error)")
        } catch {
            check("urlRequest: returnCacheDataDontLoad fails for an uncached URL", false, detail: "\(error)")
        }
    }

    // MARK: Profiles

    static func isolationRequestChecks(base: String, profile: CefProfile) async {
        let other = CefProfile.incognito()
        do {
            let (_, response) = try await other.data(from: URL(string: "\(base)/echo?other")!)
            let cookies = response.value(forHTTPHeaderField: "X-Echo-Cookie") ?? ""
            check("urlRequest: another incognito profile sends none of the first one's cookies", cookies.isEmpty,
                  detail: "Cookie: '\(cookies)'")
            _ = try await other.data(from: URL(string: "\(base)/set-cookie?other")!)
            let otherCookies = await other.cookies(for: URL(string: base)!)
            let defaultCookies = await CefProfile.default.cookies(for: URL(string: base)!)
            check("urlRequest: a cookie a request received stays in its profile",
                  otherCookies.contains { $0.name == "fromRequest" } && !defaultCookies.contains { $0.name == "fromRequest" },
                  detail: "other \(otherCookies.map(\.name)), default \(defaultCookies.map(\.name))")
        } catch {
            check("urlRequest: another incognito profile sends none of the first one's cookies", false, detail: "\(error)")
        }
    }
}

// MARK: - Recorders

/// Compares a `/large` body with what the server sends, as it arrives.
struct LargeBodyCheck {
    private(set) var bytes = 0
    private(set) var isExact = true

    mutating func feed(_ chunk: Data) {
        let pattern = LocalServer.chunk
        chunk.withUnsafeBytes { received in
            pattern.withUnsafeBytes { expected in
                var offset = 0
                while offset < received.count, isExact {
                    let position = (bytes + offset) % expected.count
                    let count = min(received.count - offset, expected.count - position)
                    if memcmp(received.baseAddress! + offset, expected.baseAddress! + position, count) != 0 { isExact = false }
                    offset += count
                }
            }
        }
        bytes += chunk.count
    }
}

/// The body of a request a check cancels from outside.
@MainActor private final class SpillProbe {
    var body: CefProfile.ResponseBody?
}

/// The names of the threads a callback ran on.
private final class ThreadNames: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [String]())

    func record() {
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread_self(), &buffer, buffer.count)
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        recorded.withLock { $0.append(name) }
    }

    var names: [String] { recorded.withLock { $0 } }
}

private final class ProgressLog: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [CefProfile.TransferProgress]())
    func record(_ progress: CefProfile.TransferProgress) { recorded.withLock { $0.append(progress) } }
    var values: [CefProfile.TransferProgress] { recorded.withLock { $0 } }
}

private final class ChallengeLog: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [CefAuthenticationChallenge]())
    func record(_ challenge: CefAuthenticationChallenge) { recorded.withLock { $0.append(challenge) } }
    var values: [CefAuthenticationChallenge] { recorded.withLock { $0 } }
}

// MARK: Quitting with requests in flight

extension SelfTest {
    /// How the requests left running for the quit ended: the error, and
    /// the runtime's state when their callers heard of it.
    static var stalledRequestEndings: [String: (error: String, isShutDown: Bool, state: CefRuntime.State)] = [:]
    static var stalledRequestServer: LocalServer?
    /// Kept, unread, so that its request is in flight with a spill file.
    static var stalledSpillingBody: CefProfile.ResponseBody?

    /// Leaves two profile requests running for the quit: one stalled before
    /// its headers, one in the middle of its body. Quitting must end both
    /// on the IO thread before Chromium starts shutting down.
    static func requestsStalledForQuitting() async {
        SelfTestResults.shared.group = "quit"
        guard let server = try? await LocalServer.start() else {
            check("quit: a local server starts for stalled requests", false)
            return
        }
        stalledRequestServer = server
        let base = "http://127.0.0.1:\(server.port)"
        let profile = CefProfile.default
        func record(_ name: String, _ error: any Error) {
            var isShutDown = false
            if case .shutDown? = error as? CefError { isShutDown = true }
            stalledRequestEndings[name] = ("\(error)", isShutDown, CefRuntime.shared.state)
        }
        Task { @MainActor in
            do {
                _ = try await profile.data(for: URLRequest(url: URL(string: "\(base)/stall?quit")!))
                record("before headers", CefError.operationFailed("it finished"))
            } catch { record("before headers", error) }
        }
        Task { @MainActor in
            do {
                let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/slow?quit")!))
                for try await _ in body {}
                record("mid-stream", CefError.operationFailed("it finished"))
            } catch { record("mid-stream", error) }
        }
        // A stream whose reader is behind, with the rest in a spill file.
        Task { @MainActor in
            do {
                var configuration = CefProfile.RequestConfiguration()
                configuration.streamMemoryLimit = 256 << 10
                let (body, _) = try await profile.bytes(for: URLRequest(url: URL(string: "\(base)/burst?\(4 << 20)")!), configuration: configuration)
                stalledSpillingBody = body
            } catch { record("spilling", error) }
        }
        let started = await waitUntil(timeout: .seconds(5)) {
            server.slowRequests.contains("/stall?quit") && server.slowRequests.contains("/slow?quit")
                && (stalledSpillingBody?.spilledBytes ?? 0) >= 2 << 20
        }
        check("quit: requests stalled before headers, mid-stream and mid-spill are running", started,
              detail: "\(server.slowRequests), \(stalledSpillingBody?.spilledBytes ?? -1) spilled")
    }

    /// Checks made once Chromium has shut down.
    static func quitChecksAfterShutdown() {
        quitWhilePendingChecksAfterShutdown()
        if stalledRequestServer != nil {
            // Each loader released its CEF references on the IO thread
            // before shutdown began. A caller may hear of it after (its
            // resumption can be queued behind the quit); one that heard
            // before heard shutDown.
            let endings = stalledRequestEndings
            let inFlight = CefRuntime.shared.requestsInFlightAtShutdown
            check("quit: stalled requests are cancelled on the IO thread before shutdown begins",
                  inFlight == 0 && endings.values.allSatisfy { $0.isShutDown && $0.state == .running },
                  detail: "\(String(describing: inFlight)) in flight, \(endings)")
            let census = CefDiagnostics.census().filter { $0.key.localizedCaseInsensitiveContains("urlrequest") }
            check("quit: no request objects are left after shutdown", census.isEmpty, detail: "\(census)")
            check("quit: quitting closed the spill file of a stream in flight",
                  stalledSpillingBody?.hasSpillFile == false && CefProfile.ResponseBody.openSpillFileCount == 0,
                  detail: "\(CefProfile.ResponseBody.openSpillFileCount) open")
            stalledSpillingBody = nil
            stalledRequestServer?.stop()
        }
        // Without Chromium, observing a preference makes no observer to leak.
        let observers = { CefDiagnostics.census()["implemented PreferenceObserver"] ?? 0 }
        let before = observers()
        for _ in 0..<3 {
            _ = CefRuntime.shared.preferences.observe(named: "browser.confirm_to_quit")
            _ = CefProfile.default.preferences.observe(named: "webkit.webprefs.default_font_size")
        }
        check("quit: observing a preference after shutdown keeps no observer", observers() == before,
              detail: "\(before) before, \(observers()) after")
    }
}
