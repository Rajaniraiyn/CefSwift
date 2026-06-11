import CCef
import Foundation
import UniformTypeIdentifiers

// MARK: - Public surface

/// A request CEF routed to a custom scheme handler.
public struct CefSchemeRequest: Sendable {
    /// The full request URL (`nil` when it failed to parse; see ``urlString``).
    public let url: URL?
    /// The raw request URL string as CEF reported it.
    public let urlString: String
    /// HTTP method (GET, POST, …).
    public let method: String
    /// Request headers. Duplicate header names are joined with `", "`.
    public let headers: [String: String]
    /// Concatenated POST body bytes, or `nil` when the request has no body.
    public let body: Data?

    public init(url: URL?, urlString: String, method: String, headers: [String: String], body: Data?) {
        self.url = url
        self.urlString = urlString
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A fully-buffered response produced by a ``CefSchemeHandler``.
public struct CefSchemeResponse: Sendable {
    /// HTTP status code (200, 404, …).
    public var status: Int
    /// Additional response headers.
    public var headers: [String: String]
    /// MIME type, e.g. `"text/html"`.
    public var mimeType: String
    /// The complete response body. v1 buffers responses whole; for large
    /// payloads prefer slicing content into multiple requests.
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], mimeType: String = "application/octet-stream", body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.mimeType = mimeType
        self.body = body
    }

    /// A plain-text 404 response.
    public static func notFound(_ message: String = "Not Found") -> CefSchemeResponse {
        CefSchemeResponse(status: 404, mimeType: "text/plain", body: Data(message.utf8))
    }
}

/// Produces responses for requests on a custom scheme registered via
/// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
///
/// `response(for:)` is invoked off the main thread (CEF's IO thread starts
/// the request; your async work runs wherever its executor puts it), so the
/// handler must be `Sendable` and self-contained.
public protocol CefSchemeHandler: Sendable {
    /// Returns the response for `request`. The whole body is buffered.
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse
}

/// A ``CefSchemeHandler`` serving static files from a local directory —
/// point a custom scheme at your app's bundled web resources.
///
/// ```swift
/// CefRuntime.shared.registerSchemeHandler(
///     scheme: "myapp",
///     handler: CefBundleSchemeHandler(directory: Bundle.main.resourceURL!.appending(path: "web")))
/// ```
///
/// Request paths map to files under `directory`; `/` (and directory paths)
/// serve `indexFile`; path traversal outside `directory` is rejected. MIME
/// types come from the file extension via UniformTypeIdentifiers.
public struct CefBundleSchemeHandler: CefSchemeHandler {
    /// Root directory served by this handler.
    public let directory: URL
    /// File served for `/` and directory paths.
    public let indexFile: String

    public init(directory: URL, indexFile: String = "index.html") {
        self.directory = directory
        self.indexFile = indexFile
    }

    public func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        guard let url = request.url else { return .notFound() }
        guard let fileURL = resolveFile(forRequestPath: url.path) else {
            return .notFound("No such file: \(url.path)")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .notFound("No such file: \(url.path)")
        }
        return CefSchemeResponse(
            status: 200,
            mimeType: Self.mimeType(forPathExtension: fileURL.pathExtension),
            body: data
        )
    }

    /// Maps a request path onto a file inside ``directory`` (nil = reject).
    /// Internal for testability.
    func resolveFile(forRequestPath path: String) -> URL? {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = indexFile }

        let root = directory.standardizedFileURL
        var candidate = root.appendingPathComponent(relative).standardizedFileURL
        // Path-traversal guard: the resolved file must stay under the root.
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            candidate = candidate.appendingPathComponent(indexFile)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        }
        return candidate
    }

    /// MIME type for a file extension (UTType-based, octet-stream fallback).
    static func mimeType(forPathExtension pathExtension: String) -> String {
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}

// MARK: - CEF bridge internals

/// Swift owner behind a `cef_scheme_handler_factory_t`. Creates one
/// ``SchemeResourceHandler`` per request. `create` runs on the IO thread.
final class SchemeHandlerFactory: @unchecked Sendable {
    private let handler: any CefSchemeHandler

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    /// Builds the factory struct. The returned pointer carries one reference
    /// owned by the caller (transferred to CEF at registration).
    func makeFactory() -> UnsafeMutablePointer<cef_scheme_handler_factory_t> {
        let factory = cefAllocate(cef_scheme_handler_factory_t.self, owner: self)
        factory.pointee.create = { factorySelf, browser, frame, _, request in
            // Callback object arguments arrive +1; we read the request inside
            // the resource handler's open() instead, so release everything.
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            cefRelease(request.map(UnsafeMutableRawPointer.init))
            guard let owner = cefOwner(SchemeHandlerFactory.self, factorySelf.map(UnsafeMutableRawPointer.init))
            else { return nil }
            // The returned handler carries a +1 reference for the caller.
            return SchemeResourceHandler(handler: owner.handler).makeHandler()
        }
        return factory
    }
}

/// Swift owner behind one `cef_resource_handler_t` (one request). Implements
/// the modern open/get_response_headers/skip/read callback flow, buffering
/// the whole response. Callbacks arrive "in sequence but not from a
/// dedicated thread", hence the lock.
final class SchemeResourceHandler: @unchecked Sendable {
    private let handler: any CefSchemeHandler
    private let lock = NSLock()
    private var response: CefSchemeResponse?
    private var offset = 0

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    private var currentResponse: CefSchemeResponse? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }

    private func store(_ response: CefSchemeResponse) {
        lock.lock()
        defer { lock.unlock() }
        self.response = response
        offset = 0
    }

    private func skipBytes(_ count: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let response else { return -2 }  // ERR_FAILED
        let skipped = min(count, Int64(response.body.count - offset))
        offset += Int(skipped)
        return skipped
    }

    private func readBytes(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let response else { return 0 }
        let remaining = response.body.count - offset
        let count = min(maxLength, remaining)
        guard count > 0 else { return 0 }
        response.body.withUnsafeBytes { bytes in
            buffer.copyMemory(from: bytes.baseAddress! + offset, byteCount: count)
        }
        offset += count
        return count
    }

    /// Builds the resource handler struct (+1 reference for the caller).
    func makeHandler() -> UnsafeMutablePointer<cef_resource_handler_t> {
        let resource = cefAllocate(cef_resource_handler_t.self, owner: self)

        resource.pointee.open = { handlerSelf, request, handleRequest, callback in
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                let request, let handleRequest, let callback
            else {
                cefRelease(request.map(UnsafeMutableRawPointer.init))
                cefRelease(callback.map(UnsafeMutableRawPointer.init))
                handleRequest?.pointee = 1
                return 0  // cancel
            }
            // Capture everything we need from the request synchronously, then
            // release it (callback args arrive +1; requests must not be
            // retained past this call).
            let captured = SchemeResourceHandler.capture(request)
            cefRelease(UnsafeMutableRawPointer(request))

            // Decide later: keep the callback's +1 reference alive across the
            // async hop, produce the response, then continue.
            handleRequest.pointee = 0
            let pendingCallback = CefUnsafeSendable(callback)
            let schemeHandler = me.handler
            let owner = me
            Task.detached {
                let response = await schemeHandler.response(for: captured)
                owner.store(response)
                let cb = pendingCallback.value
                cb.pointee.cont?(cb)
                cefRelease(UnsafeMutableRawPointer(cb))
            }
            return 1
        }

        resource.pointee.get_response_headers = { handlerSelf, cefResponse, responseLength, _ in
            // Response argument arrives +1.
            defer { cefRelease(cefResponse.map(UnsafeMutableRawPointer.init)) }
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                let cefResponse,
                let response = me.currentResponse
            else {
                responseLength?.pointee = 0
                return
            }
            cefResponse.pointee.set_status?(cefResponse, Int32(response.status))
            CefStringUtil.withCefString(response.mimeType) { mime in
                cefResponse.pointee.set_mime_type?(cefResponse, mime)
            }
            if !response.headers.isEmpty, let map = cef_string_multimap_alloc() {
                for (name, value) in response.headers {
                    CefStringUtil.withCefString(name) { cefName in
                        CefStringUtil.withCefString(value) { cefValue in
                            _ = cef_string_multimap_append(map, cefName, cefValue)
                        }
                    }
                }
                cefResponse.pointee.set_header_map?(cefResponse, map)
                cef_string_multimap_free(map)
            }
            responseLength?.pointee = Int64(response.body.count)
        }

        resource.pointee.skip = { handlerSelf, bytesToSkip, bytesSkipped, callback in
            // Synchronous answer; the async continuation callback is unused.
            cefRelease(callback.map(UnsafeMutableRawPointer.init))
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                let bytesSkipped
            else { return 0 }
            let skipped = me.skipBytes(bytesToSkip)
            bytesSkipped.pointee = skipped
            return skipped >= 0 ? 1 : 0
        }

        resource.pointee.read = { handlerSelf, dataOut, bytesToRead, bytesRead, callback in
            // Synchronous answer; the async continuation callback is unused.
            cefRelease(callback.map(UnsafeMutableRawPointer.init))
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                let dataOut, let bytesRead
            else { return 0 }
            let count = me.readBytes(into: dataOut, maxLength: Int(bytesToRead))
            bytesRead.pointee = Int32(count)
            return count > 0 ? 1 : 0  // 0 bytes + return 0 = response complete
        }

        resource.pointee.cancel = { _ in }

        return resource
    }

    /// Reads url/method/headers/body out of a borrowed `cef_request_t`.
    private static func capture(_ request: UnsafeMutablePointer<cef_request_t>) -> CefSchemeRequest {
        let urlString = CefStringUtil.takingUserFree(request.pointee.get_url?(request)) ?? ""
        let method = CefStringUtil.takingUserFree(request.pointee.get_method?(request)) ?? "GET"

        var headers: [String: String] = [:]
        if let map = cef_string_multimap_alloc() {
            request.pointee.get_header_map?(request, map)
            for index in 0..<cef_string_multimap_size(map) {
                var key = cef_string_t()
                var value = cef_string_t()
                if cef_string_multimap_key(map, index, &key) != 0,
                   cef_string_multimap_value(map, index, &value) != 0
                {
                    let name = CefStringUtil.string(from: key)
                    let headerValue = CefStringUtil.string(from: value)
                    headers[name] = headers[name].map { "\($0), \(headerValue)" } ?? headerValue
                }
                cef_string_utf16_clear(&key)
                cef_string_utf16_clear(&value)
            }
            cef_string_multimap_free(map)
        }

        var body: Data?
        if let postData = request.pointee.get_post_data?(request) {
            defer { cefRelease(UnsafeMutableRawPointer(postData)) }
            let count = postData.pointee.get_element_count?(postData) ?? 0
            if count > 0 {
                var elements = [UnsafeMutablePointer<cef_post_data_element_t>?](repeating: nil, count: count)
                var actualCount = count
                elements.withUnsafeMutableBufferPointer { buffer in
                    postData.pointee.get_elements?(postData, &actualCount, buffer.baseAddress)
                }
                var collected = Data()
                for element in elements.prefix(actualCount).compactMap({ $0 }) {
                    defer { cefRelease(UnsafeMutableRawPointer(element)) }
                    guard element.pointee.get_type?(element) == PDE_TYPE_BYTES else { continue }
                    let byteCount = element.pointee.get_bytes_count?(element) ?? 0
                    guard byteCount > 0 else { continue }
                    var chunk = Data(count: byteCount)
                    chunk.withUnsafeMutableBytes { bytes in
                        _ = element.pointee.get_bytes?(element, byteCount, bytes.baseAddress)
                    }
                    collected.append(chunk)
                }
                if !collected.isEmpty { body = collected }
            }
        }

        return CefSchemeRequest(
            url: URL(string: urlString),
            urlString: urlString,
            method: method,
            headers: headers,
            body: body
        )
    }
}

/// Moves a non-Sendable pointer across a structured-concurrency boundary.
/// Sound here because CEF callback objects are thread-safe refcounted
/// objects designed to be continued from any thread.
struct CefUnsafeSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
