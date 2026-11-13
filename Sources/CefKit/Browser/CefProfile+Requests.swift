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
        let loader = try makeLoader(for: request, configuration: configuration, mode: .collect)
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
    /// `cef_urlrequest_t` pushes chunks and cannot be paused, so the body
    /// holds at most ``RequestConfiguration/streamBufferLimit`` bytes the loop
    /// has not taken yet: a loop that falls further behind ends the request
    /// with ``CefLoadError`` `ERR_INSUFFICIENT_RESOURCES`. Read the body
    /// off the main actor when it is large and the network fast. Leaving
    /// the loop early, or dropping the body, cancels the request;
    /// cancelling the loop's task does too, and the loop throws
    /// `CancellationError`.
    ///
    /// Chromium reports headers with the first part of the body, so this
    /// returns when the first chunk arrives or the body turns out empty.
    public func bytes(for request: URLRequest, configuration: RequestConfiguration = RequestConfiguration()) async throws -> (ResponseBody, HTTPURLResponse) {
        let loader = try makeLoader(for: request, configuration: configuration, mode: .stream(limit: max(configuration.streamBufferLimit, 1)))
        return try await loader.stream()
    }

    /// Loads `request` into a file at `destination`, replacing what is
    /// there, and returns the response. The body is written as it arrives,
    /// so a large one is never in memory whole.
    ///
    /// A failed or cancelled download removes the partial file.
    public func download(for request: URLRequest, to destination: URL, configuration: RequestConfiguration = RequestConfiguration()) async throws -> HTTPURLResponse {
        let (body, response) = try await bytes(for: request, configuration: configuration)
        try await Self.write(body, to: destination)
        return response
    }

    /// Writes `body` to `destination`, off the main actor.
    private nonisolated static func write(_ body: ResponseBody, to destination: URL) async throws {
        let manager = FileManager.default
        _ = manager.createFile(atPath: destination.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            for try await chunk in body {
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    private func makeLoader(for request: URLRequest, configuration: RequestConfiguration, mode: URLRequestLoader.Mode) throws -> URLRequestLoader {
        let plan = try URLRequestPlan(request, configuration: configuration)
        guard let context = requestContext() else { throw CefError.notInitialized }
        return URLRequestLoader(plan: plan, configuration: configuration, context: context, mode: mode)
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
        /// bytes the loop may leave unread before the request fails.
        /// 16 MB by default.
        public var streamBufferLimit = 16 << 20

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

        let chunks: AsyncThrowingStream<Data, any Error>
        let buffer: URLRequestStreamBuffer
        /// Cancels the request unless it has finished.
        let cancel: @Sendable () -> Void

        /// The most received bytes that were waiting for the loop at once.
        @_spi(Testing) public var peakUnreadBytes: Int { buffer.peak }

        /// The body is read once; a second iterator finds it consumed.
        public func makeAsyncIterator() -> Iterator {
            Iterator(chunks: chunks.makeAsyncIterator(), buffer: buffer, iteration: Iteration(cancel: cancel))
        }

        public struct Iterator: AsyncIteratorProtocol {
            var chunks: AsyncThrowingStream<Data, any Error>.AsyncIterator
            let buffer: URLRequestStreamBuffer
            let iteration: Iteration

            /// The next chunk; `nil` at the end of the body. Throws the
            /// request's error, or `CancellationError` when the task is
            /// cancelled.
            public mutating func next() async throws -> Data? {
                guard let chunk = try await chunks.next() else {
                    // The stream ends quietly when the task is cancelled.
                    try Task.checkCancellation()
                    return nil
                }
                buffer.consumed(chunk.count)
                return chunk
            }
        }

        /// One loop over the body: leaving it early, which drops the
        /// iterator, cancels the request.
        final class Iteration: Sendable {
            private let cancel: @Sendable () -> Void
            init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
            deinit { cancel() }
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

// MARK: - Stream buffer

/// How many bytes of a streamed body have arrived and not been read.
final class URLRequestStreamBuffer: Sendable {
    private let unread = OSAllocatedUnfairLock(initialState: 0)
    private let highWater = OSAllocatedUnfairLock(initialState: 0)

    /// Adds `count` received bytes; returns the unread total.
    func received(_ count: Int) -> Int {
        let total = unread.withLock { unread in
            unread += count
            return unread
        }
        highWater.withLock { $0 = max($0, total) }
        return total
    }

    func consumed(_ count: Int) {
        unread.withLock { $0 -= count }
    }

    /// The most bytes that were unread at once.
    var peak: Int { highWater.withLock { $0 } }
}
