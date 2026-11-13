import CCef
import CefBase
import Foundation
import os

// Requests an app makes through a profile's network stack: Chromium's
// `cef_urlrequest_t`, shaped like `URLSession`. The CEF side is in
// CefURLRequestLoader.swift.

extension CefProfile {
    /// Loads `request` through this profile's network stack and returns the
    /// whole body with the response.
    ///
    /// The request goes where the profile's pages go: it sends and stores
    /// the profile's cookies, uses its HTTP cache, proxy settings, client
    /// certificates, Secure DNS and `Accept-Language`, and is answered by
    /// scheme handlers registered with ``CefRuntime``. `URLSession` shares
    /// none of that with Chromium.
    ///
    /// ```swift
    /// var request = URLRequest(url: URL(string: "https://intranet.example/api/me")!)
    /// request.setValue("application/json", forHTTPHeaderField: "Accept")
    /// let (data, response) = try await profile.data(for: request)
    /// ```
    ///
    /// An HTTP error status is a response, not an error, as with
    /// `URLSession`. The request fails with a ``CefLoadError`` carrying
    /// Chromium's network error (``CefLoadError/urlError`` converts it),
    /// throws `CancellationError` when its task is cancelled, and
    /// ``CefError/notInitialized`` before Chromium has started.
    public func data(for request: URLRequest, configuration: RequestConfiguration = RequestConfiguration()) async throws -> (Data, HTTPURLResponse) {
        let loader = try await makeLoader(for: URLRequestPlan(request, configuration: configuration), configuration: configuration, mode: .collect)
        return try await loader.collect()
    }

    /// Loads `url` through this profile's network stack; see
    /// ``data(for:configuration:)``.
    public func data(from url: URL, configuration: RequestConfiguration = RequestConfiguration()) async throws -> (Data, HTTPURLResponse) {
        try await data(for: URLRequest(url: url), configuration: configuration)
    }

    /// Starts `request` and returns the response once its headers have
    /// arrived, with its body as a sequence of chunks as Chromium reads
    /// them.
    ///
    /// ```swift
    /// let (body, response) = try await profile.bytes(for: URLRequest(url: feed))
    /// for try await chunk in body {
    ///     parser.feed(chunk)
    /// }
    /// ```
    ///
    /// Each chunk is copied once, from Chromium's buffer into its `Data`.
    /// `cef_urlrequest_t` pushes chunks and cannot be paused, so chunks the
    /// loop has not taken yet wait in memory, up to
    /// ``RequestConfiguration/streamMemoryLimit`` bytes, and then, by
    /// default, in a temporary file the loop reads next
    /// (``RequestConfiguration/StreamOverflowPolicy/spillToDisk(limit:)``).
    /// However slowly it reads, the loop gets every byte, in order, and
    /// then the end or the request's error. The file is unlinked as soon
    /// as it is made and closed when the body ends, is cancelled or the
    /// app quits; see ``RequestConfiguration/streamOverflow`` for where it
    /// is made, and for ``RequestConfiguration/StreamOverflowPolicy/fail``,
    /// which keeps the body off disk and fails a loop that falls behind.
    ///
    /// Leaving the loop early, or dropping the body, cancels the request;
    /// cancelling the loop's task does too, and the loop throws
    /// `CancellationError`. Either way unread bytes are dropped.
    ///
    /// Chromium reports headers with the first part of the body, so this
    /// returns when the first chunk arrives or the body turns out empty.
    public func bytes(for request: URLRequest, configuration: RequestConfiguration = RequestConfiguration()) async throws -> (ResponseBody, HTTPURLResponse) {
        let plan = try URLRequestPlan(request, configuration: configuration)
        let limits = URLRequestStreamBuffer.Limits(
            memory: configuration.streamMemoryLimit, overflow: configuration.streamOverflow,
            spillDirectory: spillDirectory, url: plan.url)
        let loader = try await makeLoader(for: plan, configuration: configuration, mode: .stream(limits))
        return try await loader.stream()
    }

    /// Loads `request` into a file at `destination`, replacing what is
    /// there, and returns the response once the whole body is written.
    ///
    /// Chunks go straight from Chromium's IO thread to a queue that writes
    /// them, each copied once, so a large body is never in memory whole
    /// and the download cannot fall behind; the stream settings of
    /// `configuration` do not apply. A failed or cancelled download
    /// removes the partial file; one that cannot be written fails with
    /// the `CocoaError`.
    public func download(for request: URLRequest, to destination: URL, configuration: RequestConfiguration = RequestConfiguration()) async throws -> HTTPURLResponse {
        let loader = try await makeLoader(for: URLRequestPlan(request, configuration: configuration), configuration: configuration, mode: .file(destination))
        return try await loader.download()
    }

    /// Where a streamed body spills: the profile's directory, or for an
    /// incognito profile (which has none) the temporary directory.
    @_spi(Testing) public var spillDirectory: URL {
        if kind == .incognito { return FileManager.default.temporaryDirectory }
        return directory ?? FileManager.default.temporaryDirectory
    }

    /// Waits for the profile first: a request started on a profile
    /// Chromium cannot load would go out with an in-memory one's cookies.
    private func makeLoader(for plan: URLRequestPlan, configuration: RequestConfiguration, mode: URLRequestLoader.Mode) async throws -> URLRequestLoader {
        try await ready()
        guard let context = requestContext() else { throw CefError.notInitialized }
        let loader = URLRequestLoader(plan: plan, configuration: configuration, context: context, mode: mode)
        // Registered while it holds the context reference, so that quitting
        // waits for it; a loader refused here releases it at once, while
        // Chromium still runs.
        guard URLRequestRegistry.shared.insert(loader) else { throw CefError.shutDown }
        return loader
    }

    /// What a request made with ``CefProfile/data(for:configuration:)`` and
    /// ``CefProfile/bytes(for:configuration:)`` does that `URLRequest` cannot say.
    ///
    /// Everything else comes from the `URLRequest`: its method, headers,
    /// `httpBody`, `cachePolicy`, `timeoutInterval` (the longest wait for
    /// the next part of the response), and `httpShouldHandleCookies`, which
    /// also decides whether stored HTTP credentials may be used. A
    /// `Referer` header becomes the request's referrer.
    public struct RequestConfiguration: Sendable {
        /// Whether a redirect is returned as the response (status 3xx,
        /// with its `Location` header) instead of followed. Chromium does
        /// not report the redirects it follows.
        public var stopsAtRedirects = false

        /// Whether Chromium may send the request again when the server
        /// answers 5xx. Off, as with `URLSession`.
        public var retriesOnServerError = false

        /// The site the request is made for, which decides which
        /// `SameSite` cookies it sends. `nil`, the default, makes the
        /// request's own URL the site, as for a page loaded in a tab.
        public var siteForCookies: URL?

        /// Sends the file's contents as the request body instead of the
        /// `URLRequest`'s `httpBody`; Chromium reads the file itself.
        /// (`httpBodyStream` cannot be sent: Chromium's request body is
        /// bytes or a file.)
        public var bodyFile: URL?

        /// Answers an HTTP authentication challenge from the server or a
        /// proxy. `nil`, the default, sends no credentials, and the
        /// challenge's response (such as a 401) is the response. Runs on
        /// Swift's concurrent executor.
        public var credential: (@Sendable (CefAuthenticationChallenge) async -> CefCredential?)?

        /// Called as the request body is sent, on Chromium's IO thread.
        public var uploadProgress: (@CefIOActor @Sendable (TransferProgress) -> Void)?

        /// Called as the response body arrives, on Chromium's IO thread.
        public var downloadProgress: (@CefIOActor @Sendable (TransferProgress) -> Void)?

        /// For ``CefProfile/bytes(for:configuration:)``: how many received
        /// bytes the loop has not read are kept in memory before
        /// ``streamOverflow`` decides what happens to the next ones.
        /// 16 MB by default. A chunk is always kept when none is waiting,
        /// so memory can pass this by one chunk's size when it is smaller.
        public var streamMemoryLimit = 16 << 20

        /// For ``CefProfile/bytes(for:configuration:)``: what happens to
        /// received bytes once ``streamMemoryLimit`` of them wait for the
        /// loop. ``StreamOverflowPolicy/spillToDisk(limit:)`` without a
        /// limit by default, so a loop that reads slowly still gets every
        /// byte.
        ///
        /// A spilled body goes to a file in the profile's directory, or for
        /// an incognito profile in `FileManager.default.temporaryDirectory`
        /// (never in a profile's directory, which an incognito profile
        /// does not have). The file is unlinked as soon as it is opened,
        /// so it has no name on disk and a crash leaves nothing behind,
        /// but its bytes are on disk until it closes. A request whose body
        /// must not touch disk, such as one in an incognito profile with
        /// sensitive data, uses ``StreamOverflowPolicy/fail``.
        public var streamOverflow = StreamOverflowPolicy.spillToDisk(limit: nil)

        /// What a streamed body does with bytes its loop has not read once
        /// ``RequestConfiguration/streamMemoryLimit`` of them are in memory.
        /// Chromium cannot pause a body, so they are either kept on disk
        /// or the request ends.
        public enum StreamOverflowPolicy: Sendable, Equatable {
            /// Further bytes go to a temporary file, which the loop reads
            /// once it has taken those in memory; when it has read the file
            /// to its end, bytes are kept in memory again. `limit` is the
            /// most bytes the file may hold at once: past it the request
            /// fails with ``CefLoadError`` `ERR_INSUFFICIENT_RESOURCES`,
            /// after the loop has read what arrived before. `nil`, the
            /// default, sets none.
            ///
            /// Chunks are written as they are, in batches, on a queue of
            /// their own; until written they are in memory, which matters
            /// only while the network is faster than the disk (a local
            /// server can be). `limit` bounds those bytes too.
            case spillToDisk(limit: Int64?)
            /// The request fails with ``CefLoadError``
            /// `ERR_INSUFFICIENT_RESOURCES`, after the loop has read what
            /// arrived before: the body never touches disk, and a loop
            /// that falls further behind than the memory limit (the main
            /// actor during a fast download, say) loses the rest.
            case fail
        }

        public init() {}
    }

    /// How much of a request or response body has gone.
    public struct TransferProgress: Sendable, Equatable {
        /// Bytes sent or received so far.
        public var completed: Int64
        /// The body's length, when it is known.
        public var total: Int64?

        public init(completed: Int64, total: Int64?) {
            self.completed = completed
            self.total = total
        }

        /// `completed` over `total`, when the total is known and not zero.
        public var fractionCompleted: Double? {
            guard let total, total > 0 else { return nil }
            return Double(completed) / Double(total)
        }
    }

    /// The body of a response from ``CefProfile/bytes(for:configuration:)``: its
    /// chunks, in order, as Chromium reads them.
    public struct ResponseBody: AsyncSequence, Sendable {
        public typealias Element = Data

        let buffer: URLRequestStreamBuffer
        /// Cancels the body and the request when the last copy of the body
        /// and its iterators goes.
        let lifetime: Cancellation

        init(buffer: URLRequestStreamBuffer, cancelRequest: @escaping @Sendable () -> Void) {
            self.buffer = buffer
            lifetime = Cancellation(buffer: buffer, request: cancelRequest)
        }

        /// The most received bytes that waited for the loop in memory at once.
        @_spi(Testing) public var peakUnreadBytesInMemory: Int { buffer.statistics.peakMemoryBytes }

        /// The most received bytes that waited for the loop in the spill
        /// file at once; 0 when the body never spilled.
        @_spi(Testing) public var peakUnreadBytesOnDisk: Int64 { buffer.statistics.peakSpilledBytes }

        /// The most spilled bytes that waited in memory for the disk at once.
        @_spi(Testing) public var peakUnwrittenBytes: Int { buffer.statistics.peakUnwrittenBytes }

        /// All the bytes that went through the spill file.
        @_spi(Testing) public var spilledBytes: Int64 { buffer.statistics.spilledBytes }

        /// Whether the body has a spill file open.
        @_spi(Testing) public var hasSpillFile: Bool { buffer.hasSpillFile }

        /// Spill files open in the process, for checks that none is left.
        @_spi(Testing) public static var openSpillFileCount: Int { URLRequestStreamBuffer.openFileCount }

        /// The body is read once; a second iterator finds it consumed.
        public func makeAsyncIterator() -> Iterator {
            Iterator(buffer: buffer, lifetime: lifetime, iteration: Iteration(lifetime))
        }

        public struct Iterator: AsyncIteratorProtocol {
            let buffer: URLRequestStreamBuffer
            let lifetime: Cancellation
            let iteration: Iteration

            /// The next chunk; `nil` at the end of the body. Throws the
            /// request's error, or `CancellationError` when the task is
            /// cancelled.
            public mutating func next() async throws -> Data? {
                let chunk = try await withTaskCancellationHandler {
                    try await buffer.next()
                } onCancel: { [lifetime] in
                    lifetime.cancel()
                }
                guard let chunk else {
                    // A cancelled body ends quietly.
                    try Task.checkCancellation()
                    return nil
                }
                return chunk
            }
        }

        /// Ends the body, dropping what is unread, and cancels the request
        /// unless it has finished; when it is called, or when it goes.
        final class Cancellation: Sendable {
            private let buffer: URLRequestStreamBuffer
            private let request: @Sendable () -> Void
            init(buffer: URLRequestStreamBuffer, request: @escaping @Sendable () -> Void) {
                self.buffer = buffer
                self.request = request
            }
            func cancel() {
                buffer.cancel()
                request()
            }
            deinit { cancel() }
        }

        /// One loop over the body: leaving it early, which drops the
        /// iterator, cancels the body.
        final class Iteration: Sendable {
            private let lifetime: Cancellation
            init(_ lifetime: Cancellation) { self.lifetime = lifetime }
            deinit { lifetime.cancel() }
        }
    }
}

extension CefLoadError {
    /// The `URLError` closest to Chromium's network error, for code that
    /// handles `URLSession`'s errors.
    public var urlError: URLError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let url {
            info[NSURLErrorFailingURLErrorKey] = url
            info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        return URLError(Self.urlErrorCode(forNetError: code), userInfo: info)
    }

    /// The `URLError` code for one of Chromium's `net::Error` codes.
    static func urlErrorCode(forNetError code: Int) -> URLError.Code {
        switch code {
        case -3: .cancelled                                      // ABORTED
        case -6: .fileDoesNotExist                               // FILE_NOT_FOUND
        case -7, -118: .timedOut                                 // TIMED_OUT, CONNECTION_TIMED_OUT
        case -20, -27: .cancelled                                // BLOCKED_BY_CLIENT, BLOCKED_BY_RESPONSE
        case -21, -100, -101, -103: .networkConnectionLost       // NETWORK_CHANGED, CONNECTION_CLOSED/RESET/ABORTED
        case -102, -104, -109: .cannotConnectToHost              // CONNECTION_REFUSED/FAILED, ADDRESS_UNREACHABLE
        case -105, -137: .cannotFindHost                         // NAME_NOT_RESOLVED, NAME_RESOLUTION_FAILED
        case -106: .notConnectedToInternet                       // INTERNET_DISCONNECTED
        case -107, -113, -123: .secureConnectionFailed           // SSL_PROTOCOL_ERROR, SSL_VERSION_OR_CIPHER_MISMATCH, SSL_NO_RENEGOTIATION
        case -110: .clientCertificateRequired                    // SSL_CLIENT_AUTH_CERT_NEEDED
        case -130, -111: .cannotConnectToHost                    // PROXY_CONNECTION_FAILED, TUNNEL_CONNECTION_FAILED
        case -201: .serverCertificateHasBadDate                  // CERT_DATE_INVALID
        case -202: .serverCertificateHasUnknownRoot              // CERT_AUTHORITY_INVALID
        case -299 ... -200: .serverCertificateUntrusted          // other CERT_* errors
        case -300: .badURL                                       // INVALID_URL
        case -301, -302: .unsupportedURL                         // DISALLOWED_URL_SCHEME, UNKNOWN_URL_SCHEME
        case -310: .httpTooManyRedirects                         // TOO_MANY_REDIRECTS
        case -311: .redirectToNonExistentLocation                // UNSAFE_REDIRECT
        case -320, -321, -322: .badServerResponse                // INVALID_RESPONSE, INVALID_CHUNKED_ENCODING, METHOD_NOT_SUPPORTED
        case -324: .zeroByteResource                             // EMPTY_RESPONSE
        case -338: .userAuthenticationRequired                   // INVALID_AUTH_CREDENTIALS
        case -400: .resourceUnavailable                          // CACHE_MISS
        default: .unknown
        }
    }

    /// A load error for one of Chromium's `net::Error` codes, named as
    /// Chromium names it (`net::ERR_NAME_NOT_RESOLVED`).
    init(netError code: Int, url: URL?, detail: String? = nil) {
        let name = ccef_net_error_name(Int32(code)).map { "net::ERR_" + String(cString: $0) } ?? "net error \(code)"
        self.init(code: code, message: detail.map { "\(name): \($0)" } ?? name, url: url)
    }
}

// MARK: - Mapping

/// What a `URLRequest` and ``CefProfile/RequestConfiguration`` ask of a
/// `cef_request_t`: worked out before anything touches CEF, so it can be
/// tested without Chromium.
struct URLRequestPlan: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case bytes(Data)
        case file(URL)
    }

    var url: URL
    var method: String
    /// Header fields in a fixed order, `Referer` excluded.
    var headers: [Header]
    var referrer: URL?
    var siteForCookies: URL
    var body: Body?
    /// `cef_urlrequest_flags_t` values.
    var flags: Int32
    /// The longest wait for the next sign of progress; `nil` for none.
    var idleTimeout: Duration?

    struct Header: Equatable, Sendable {
        var name: String
        var value: String
    }

    init(_ request: URLRequest, configuration: CefProfile.RequestConfiguration) throws {
        guard let url = request.url, let scheme = url.scheme, !scheme.isEmpty else {
            throw CefLoadError(netError: -300, url: request.url, detail: "the request has no absolute URL")  // INVALID_URL
        }
        if request.httpBodyStream != nil {
            throw CefError.operationFailed(
                "A URLRequest's httpBodyStream cannot be sent through Chromium, whose request body is bytes or a file; "
                + "set httpBody, or RequestConfiguration.bodyFile.")
        }
        self.url = url
        method = request.httpMethod?.uppercased() ?? "GET"
        var headers: [Header] = []
        var referrer: URL?
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            if name.caseInsensitiveCompare("Referer") == .orderedSame {
                referrer = URL(string: value)
            } else {
                headers.append(Header(name: name, value: value))
            }
        }
        self.headers = headers
        self.referrer = referrer
        siteForCookies = configuration.siteForCookies ?? url
        if let file = configuration.bodyFile {
            body = .file(file)
        } else if let data = request.httpBody {
            body = .bytes(data)
        }
        flags = Self.flags(for: request, configuration: configuration)
        idleTimeout = request.timeoutInterval > 0 && request.timeoutInterval.isFinite
            ? .milliseconds(Int64(request.timeoutInterval * 1000)) : nil
    }

    static func flags(for request: URLRequest, configuration: CefProfile.RequestConfiguration) -> Int32 {
        var flags = cacheFlags(for: request.cachePolicy)
        if request.httpShouldHandleCookies { flags |= UR_FLAG_ALLOW_STORED_CREDENTIALS.rawValue }
        if configuration.stopsAtRedirects { flags |= UR_FLAG_STOP_ON_REDIRECT.rawValue }
        if !configuration.retriesOnServerError { flags |= UR_FLAG_NO_RETRY_ON_5XX.rawValue }
        if configuration.uploadProgress != nil { flags |= UR_FLAG_REPORT_UPLOAD_PROGRESS.rawValue }
        return Int32(bitPattern: flags)
    }

    /// The load flags closest to a cache policy. Chromium has no flag for
    /// "use stale cached data without revalidating", so
    /// `.returnCacheDataElseLoad` behaves as `.useProtocolCachePolicy`.
    static func cacheFlags(for policy: URLRequest.CachePolicy) -> UInt32 {
        switch policy {
        case .reloadIgnoringLocalCacheData, .reloadIgnoringLocalAndRemoteCacheData: UR_FLAG_SKIP_CACHE.rawValue
        case .returnCacheDataDontLoad: UR_FLAG_ONLY_FROM_CACHE.rawValue
        default: UR_FLAG_NONE.rawValue
        }
    }
}
