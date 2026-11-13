import AppKit
import CefKit
import CefSwiftUI

/// State the thread checks keep on Chromium's IO thread.
@CefIOActor var ioFilteredRequests = 0
@CefIOActor var ioOrder: [Int] = []

/// The name of the calling thread, as Chromium names its threads.
func currentThreadName() -> String {
    var name = [CChar](repeating: 0, count: 64)
    pthread_getname_np(pthread_self(), &name, name.count)
    return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The label of the dispatch queue running the caller.
func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// Checks of the thread actors and of scheme handlers off the main thread:
/// which thread each runs on, isolation inside CEF callbacks, ordering,
/// streamed and range responses, and work sent before start-up and after
/// shutdown.
extension SelfTest {
    /// Where a job sent to ``CefIOActor`` before `initialize()` ran.
    nonisolated(unsafe) static var preStartJobQueue: String?

    /// Sends a job to ``CefIOActor`` before Chromium starts. Called from
    /// `main` before `initialize()`.
    static func sendJobBeforeStartUp() {
        Task { @CefIOActor in SelfTest.preStartJobQueue = currentQueueLabel() }
    }

    static func threadChecks() async {
        check("threads: a job sent before start-up ran on the actor's own queue",
              await waitUntil { preStartJobQueue != nil } && preStartJobQueue == "CefSwift.io-fallback",
              detail: preStartJobQueue ?? "did not run")

        let ioThread = await Task { @CefIOActor in currentThreadName() }.value
        check("threads: CefIOActor runs on Chromium's IO thread", ioThread == "Chrome_IOThread", detail: ioThread)
        let fileThread = await Task { @CefFileActor in currentThreadName() }.value
        check("threads: CefFileActor runs on Chromium's thread pool", fileThread.hasPrefix("ThreadPool"), detail: fileThread)

        for index in 0..<200 {
            Task { @CefIOActor in ioOrder.append(index) }
        }
        let order = await waitUntilAsync { await Task { @CefIOActor in ioOrder.count }.value == 200 }
        let inOrder = await Task { @CefIOActor in ioOrder == Array(0..<200) }.value
        check("threads: CefIOActor runs jobs in the order they were sent", order && inOrder)

        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "threads", handler: ThreadPages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "main-actor", handler: MainActorPages(title: "from the main actor"))

        var configuration = CefBrowser.Configuration()
        configuration.requestFilter = { request in
            // On macOS 15 and later this asks the executor's checkIsolated(),
            // since the filter runs inside a CEF callback, not an actor job.
            CefIOActor.preconditionIsolated()
            ioFilteredRequests += 1
            return request.url?.path == "/blocked" ? .block : .allow
        }
        let browser = CefBrowser(url: URL(string: "selftest://threads/page.html")!, configuration: configuration)
        let view = hostWindowed(browser)
        _ = await loaded(browser, title: "threads")

        let filtered = await Task { @CefIOActor in ioFilteredRequests }.value
        check("threads: a request filter keeps state on CefIOActor without a lock", filtered >= 1, detail: "\(filtered)")
        await expect("threads: a request filter blocks on the IO thread") {
            try await browser.evaluateJavaScript("fetch('/blocked').then(() => 'loaded', () => 'blocked')").stringValue == "blocked"
        }
        await expect("threads: a streamed body arrives whole") {
            try await browser.evaluateJavaScript("""
                fetch('/stream').then(r => r.arrayBuffer()).then(b => b.byteLength)
                """).intValue == ThreadPages.streamSize
        }
        await expect("threads: a streamed body without a length arrives whole") {
            try await browser.evaluateJavaScript("""
                fetch('/stream-unsized').then(r => r.arrayBuffer()).then(b => b.byteLength)
                """).intValue == ThreadPages.streamSize
        }
        let size = ThreadPages.streamSize
        let ranges: [(path: String, header: String, expected: ClosedRange<Int>)] = [
            ("/bytes", "bytes=1000-1999", 1000...1999),
            ("/file", "bytes=1000-1999", 1000...1999),
            ("/stream", "bytes=1000-1999", 1000...1999),
            ("/file", "bytes=-500", (size - 500)...(size - 1)),
            ("/bytes", "bytes=\(size - 300)-", (size - 300)...(size - 1)),
        ]
        for (path, header, expected) in ranges {
            await expect("threads: \(header) on \(path) gets 206 and those bytes") {
                let reply = try await browser.evaluateJavaScript("""
                    fetch('\(path)', { headers: { Range: '\(header)' } })
                      .then(async r => [r.status, r.headers.get('content-range'), [...new Uint8Array(await r.arrayBuffer())]])
                    """)
                let bytes = reply[2].arrayValue?.compactMap(\.intValue) ?? []
                let wanted = expected.map { $0 % 251 }
                let range = "bytes \(expected.lowerBound)-\(expected.upperBound)/\(size)"
                let passed = reply[0].intValue == 206 && reply[1].stringValue == range && bytes == wanted
                if !passed { print("NOTE range \(path) \(header): status \(reply[0].text), \(reply[1].text), \(bytes.count) bytes") }
                return passed
            }
        }
        await expect("threads: an unsatisfiable range gets 416") {
            try await browser.evaluateJavaScript(
                "fetch('/file', { headers: { Range: 'bytes=\(size + 10)-' } }).then(r => r.status)").intValue == 416
        }
        await expect("threads: a file body arrives whole") {
            try await browser.evaluateJavaScript("fetch('/file').then(r => r.arrayBuffer()).then(b => b.byteLength)").intValue
                == ThreadPages.streamSize
        }
        await expect("threads: a main-actor scheme handler serves pages") {
            try await browser.evaluateJavaScript("fetch('selftest://main-actor/x').then(r => r.text())").stringValue
                == "from the main actor"
        }
        await closeHosted(browser, view)
    }

    /// Run while the app terminates, after `cef_shutdown()`: a job sent then
    /// runs on the actor's own queue instead of waiting forever.
    static func jobAfterShutdownRuns() -> Bool {
        let done = DispatchSemaphore(value: 0)
        Task { @CefIOActor in done.signal() }
        return done.wait(timeout: .now() + 2) == .success
    }
}

/// Pages for the thread checks, with a byte pattern ranges can be checked
/// against.
struct ThreadPages: CefSchemeHandler {
    static let streamSize = 3 << 20
    static let pattern = Data((0..<streamSize).map { UInt8($0 % 251) })
    static let file: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-threads-\(getpid()).bin")
        try? pattern.write(to: url)
        return url
    }()

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        switch request.url?.path {
        case "/page.html":
            return CefSchemeResponse(mimeType: "text/html", body: Data("<title>threads</title>".utf8))
        case "/bytes":
            return CefSchemeResponse(body: .data(Self.pattern))
        case "/file":
            return CefSchemeResponse(body: .file(Self.file))
        case "/stream", "/stream-unsized":
            let chunks = AsyncThrowingStream<Data, any Error> { continuation in
                // Uneven chunk sizes, delivered from another task.
                Task {
                    var offset = 0
                    while offset < Self.streamSize {
                        let end = min(offset + 70_001, Self.streamSize)
                        continuation.yield(Self.pattern[offset..<end])
                        offset = end
                    }
                    continuation.finish()
                }
            }
            return CefSchemeResponse(
                body: .stream(chunks, length: request.url?.path == "/stream" ? Self.streamSize : nil))
        default:
            return .notFound()
        }
    }
}

/// A scheme handler isolated to the main actor, reading app state.
@MainActor
final class MainActorPages: CefSchemeHandler {
    let title: String

    init(title: String) {
        self.title = title
    }

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        MainActor.preconditionIsolated()
        return CefSchemeResponse(
            headers: ["Access-Control-Allow-Origin": "*"], mimeType: "text/plain", body: Data(title.utf8))
    }
}
