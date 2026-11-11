import CCef
import Foundation
import UniformTypeIdentifiers

/// A request for a URL served by a ``CefSchemeHandler``.
public struct CefSchemeRequest: Sendable {
    /// The request URL, or `nil` when ``urlString`` does not parse.
    public let url: URL?
    /// The request URL as Chromium reported it.
    public let urlString: String
    /// The HTTP method, such as `"GET"`.
    public let method: String
    /// The request headers. Repeated headers are joined with `", "`.
    public let headers: [String: String]
    /// The request body, or `nil` when there is none.
    public let body: Data?

    public init(url: URL?, urlString: String, method: String, headers: [String: String], body: Data?) {
        self.url = url
        self.urlString = urlString
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A response from a ``CefSchemeHandler``.
public struct CefSchemeResponse: Sendable {
    /// The HTTP status code.
    public var status: Int
    /// Response headers.
    public var headers: [String: String]
    /// The MIME type, such as `"text/html"`. Text and JSON types are sent
    /// as UTF-8.
    public var mimeType: String
    /// The complete response body.
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

/// Serves the URLs of a scheme registered with
/// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
///
/// Requests arrive off the main thread, so handlers must be `Sendable`.
public protocol CefSchemeHandler: Sendable {
    /// The response for `request`.
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse
}

/// A ``CefSchemeHandler`` that serves files from a directory, such as your
/// app's bundled web content.
///
/// ```swift
/// CefRuntime.shared.registerSchemeHandler(
///     scheme: "myapp",
///     handler: CefDirectorySchemeHandler(directory: Bundle.main.resourceURL!.appending(path: "web")))
/// ```
///
/// Request paths map to files under ``directory``; directory paths serve
/// ``indexFile``. Paths that lead outside ``directory`` are not found. The
/// MIME type comes from the file extension.
public struct CefDirectorySchemeHandler: CefSchemeHandler {
    /// The directory served.
    public let directory: URL
    /// The file served for directory paths.
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

    /// The file under ``directory`` for a request path, or `nil`.
    func resolveFile(forRequestPath path: String) -> URL? {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = indexFile }

        let root = directory.standardizedFileURL
        var candidate = root.appendingPathComponent(relative).standardizedFileURL
        // The resolved file must stay under the root.
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

    /// The MIME type for a file extension.
    static func mimeType(forPathExtension pathExtension: String) -> String {
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}

// MARK: - CEF structs

/// Owner of a `cef_scheme_handler_factory_t`, which creates a
/// ``SchemeResourceHandler`` for each request on the IO thread.
final class SchemeHandlerFactory: @unchecked Sendable {
    private let handler: any CefSchemeHandler

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    /// Builds the factory. The returned pointer carries one reference for
    /// the caller, which registration hands to CEF.
    func makeFactory() -> UnsafeMutablePointer<cef_scheme_handler_factory_t> {
        let factory = cefAllocate(cef_scheme_handler_factory_t.self, owner: self)
        factory.pointee.create = { factorySelf, browser, frame, _, request in
            // The resource handler reads the request in `open`.
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(request)
            guard let owner = cefOwner(SchemeHandlerFactory.self, factorySelf) else { return nil }
            return SchemeResourceHandler(handler: owner.handler).makeHandler()
        }
        return factory
    }
}

/// Owner of the `cef_resource_handler_t` for one request. CEF calls it in
/// sequence but not on a fixed thread, hence the lock.
final class SchemeResourceHandler: @unchecked Sendable {
    private let handler: any CefSchemeHandler
    private let lock = NSLock()
    private var response: CefSchemeResponse?
    private var offset = 0

    init(handler: any CefSchemeHandler) {
        self.handler = handler
    }

    private var currentResponse: CefSchemeResponse? {
        lock.withLock { response }
    }

    private func store(_ response: CefSchemeResponse) {
        lock.withLock {
            self.response = response
            offset = 0
        }
    }

    private func skipBytes(_ count: Int64) -> Int64 {
        lock.withLock {
            guard let response else { return -2 }  // ERR_FAILED
            let skipped = min(count, Int64(response.body.count - offset))
            offset += Int(skipped)
            return skipped
        }
    }

    private func readBytes(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> Int {
        lock.withLock {
            guard let response else { return 0 }
            let count = min(maxLength, response.body.count - offset)
            guard count > 0 else { return 0 }
            response.body.withUnsafeBytes { bytes in
                buffer.copyMemory(from: bytes.baseAddress! + offset, byteCount: count)
            }
            offset += count
            return count
        }
    }

    /// Builds the handler. The returned pointer carries one reference for the
    /// caller.
    func makeHandler() -> UnsafeMutablePointer<cef_resource_handler_t> {
        let resource = cefAllocate(cef_resource_handler_t.self, owner: self)

        resource.pointee.open = { handlerSelf, request, handleRequest, callback in
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let request, let handleRequest, let callback
            else {
                cefRelease(request)
                cefRelease(callback)
                handleRequest?.pointee = 1
                return 0  // cancel
            }
            // The request must not outlive this call, so copy what is needed.
            let captured = SchemeResourceHandler.capture(request)
            cefRelease(request)

            // Answer asynchronously, continuing the callback once the
            // response is ready.
            handleRequest.pointee = 0
            let pending = CefRef(adopting: callback)
            Task.detached {
                me.store(await me.handler.response(for: captured))
                pending.pointer.pointee.cont(pending.pointer)
            }
            return 1
        }

        resource.pointee.get_response_headers = { handlerSelf, cefResponse, responseLength, _ in
            defer { cefRelease(cefResponse) }
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let cefResponse,
                let response = me.currentResponse
            else {
                responseLength?.pointee = 0
                return
            }
            cefResponse.pointee.set_status(cefResponse, Int32(response.status))
            CefStringUtil.withCefString(response.mimeType) { mime in
                cefResponse.pointee.set_mime_type(cefResponse, mime)
            }
            // Swift strings are UTF-8; say so, or Chromium guesses Latin-1.
            if response.mimeType.hasPrefix("text/") || response.mimeType.hasSuffix("json") {
                CefStringUtil.withCefString("utf-8") { cefResponse.pointee.set_charset(cefResponse, $0) }
            }
            if !response.headers.isEmpty, let map = cef_string_multimap_alloc() {
                for (name, value) in response.headers {
                    CefStringUtil.withCefString(name) { cefName in
                        CefStringUtil.withCefString(value) { cefValue in
                            _ = cef_string_multimap_append(map, cefName, cefValue)
                        }
                    }
                }
                cefResponse.pointee.set_header_map(cefResponse, map)
                cef_string_multimap_free(map)
            }
            responseLength?.pointee = Int64(response.body.count)
        }

        resource.pointee.skip = { handlerSelf, bytesToSkip, bytesSkipped, callback in
            // Answered synchronously; the callback is unused.
            cefRelease(callback)
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let bytesSkipped
            else { return 0 }
            let skipped = me.skipBytes(bytesToSkip)
            bytesSkipped.pointee = skipped
            return skipped >= 0 ? 1 : 0
        }

        resource.pointee.read = { handlerSelf, dataOut, bytesToRead, bytesRead, callback in
            // Answered synchronously; the callback is unused.
            cefRelease(callback)
            guard
                let me = cefOwner(SchemeResourceHandler.self, handlerSelf),
                let dataOut, let bytesRead
            else { return 0 }
            let count = me.readBytes(into: dataOut, maxLength: Int(bytesToRead))
            bytesRead.pointee = Int32(count)
            return count > 0 ? 1 : 0  // returning 0 with no bytes ends the response
        }

        resource.pointee.cancel = { _ in }

        return resource
    }

    /// Copies the URL, method, headers and body of a borrowed `cef_request_t`.
    private static func capture(_ request: UnsafeMutablePointer<cef_request_t>) -> CefSchemeRequest {
        let urlString = CefStringUtil.takingUserFree(request.pointee.get_url(request)) ?? ""
        let method = CefStringUtil.takingUserFree(request.pointee.get_method(request)) ?? "GET"

        var headers: [String: String] = [:]
        if let map = cef_string_multimap_alloc() {
            request.pointee.get_header_map(request, map)
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
        if let postData = request.pointee.get_post_data(request) {
            defer { cefRelease(postData) }
            let count = postData.pointee.get_element_count(postData)
            if count > 0 {
                var elements = [UnsafeMutablePointer<cef_post_data_element_t>?](repeating: nil, count: count)
                var actualCount = count
                elements.withUnsafeMutableBufferPointer { buffer in
                    postData.pointee.get_elements(postData, &actualCount, buffer.baseAddress)
                }
                var collected = Data()
                for element in elements.prefix(actualCount).compactMap({ $0 }) {
                    defer { cefRelease(element) }
                    guard element.pointee.get_type(element) == PDE_TYPE_BYTES else { continue }
                    let byteCount = element.pointee.get_bytes_count(element)
                    guard byteCount > 0 else { continue }
                    var chunk = Data(count: byteCount)
                    chunk.withUnsafeMutableBytes { bytes in
                        _ = element.pointee.get_bytes(element, byteCount, bytes.baseAddress)
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
