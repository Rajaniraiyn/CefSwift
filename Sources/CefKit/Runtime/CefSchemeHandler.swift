import CCef
import Foundation
import UniformTypeIdentifiers
import CefBase
import os

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
    /// The response body.
    public var body: Body

    public init(status: Int = 200, headers: [String: String] = [:], mimeType: String = "application/octet-stream", body: Body) {
        self.status = status
        self.headers = headers
        self.mimeType = mimeType
        self.body = body
    }

    /// A response whose body is `data`.
    public init(status: Int = 200, headers: [String: String] = [:], mimeType: String = "application/octet-stream", body: Data = Data()) {
        self.init(status: status, headers: headers, mimeType: mimeType, body: .data(body))
    }

    /// A plain-text 404 response.
    public static func notFound(_ message: String = "Not Found") -> CefSchemeResponse {
        CefSchemeResponse(status: 404, mimeType: "text/plain", body: Data(message.utf8))
    }

    /// Where a response's bytes come from.
    ///
    /// Chromium reads a body as the page consumes it, so a file or a stream
    /// is never held in memory whole. For a request with a `Range` header,
    /// Chromium skips to the range's start and answers `206 Partial
    /// Content`; a ``data(_:)`` or ``file(_:)`` body skips without reading
    /// what it skips, which is what media elements seeking through a long
    /// file need.
    public struct Body: Sendable {
        enum Source: Sendable {
            case data(Data)
            case file(URL)
            case stream(length: Int?, pump: @Sendable (SchemeBodyWriter) async throws -> Void)
        }

        let source: Source

        /// Bytes in memory.
        public static func data(_ data: Data) -> Body {
            Body(source: .data(data))
        }

        /// The contents of a file, read as the page consumes them, straight
        /// into Chromium's buffer.
        public static func file(_ url: URL) -> Body {
            Body(source: .file(url))
        }

        /// Chunks of data, read from `chunks` as the page consumes them.
        /// Pass the total `length` when it is known, so the page can show
        /// progress and Chromium can answer range requests.
        ///
        /// ```swift
        /// // recording.chunks: an AsyncSequence of Data
        /// return CefSchemeResponse(mimeType: "video/mp4", body: .stream(recording.chunks, length: recording.size))
        /// ```
        ///
        /// The sequence is iterated in a task of its own, at most about a
        /// megabyte ahead of the page; cancelling the request cancels the
        /// task.
        public static func stream<Chunks: AsyncSequence & Sendable>(_ chunks: Chunks, length: Int? = nil) -> Body
        where Chunks.Element == Data {
            Body(source: .stream(length: length) { writer in
                for try await chunk in chunks {
                    try await writer.write(chunk)
                }
            })
        }

        /// The body's length in bytes, when it is known.
        var length: Int? {
            switch source {
            case .data(let data): data.count
            case .file(let url): (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            case .stream(let length, _): length
            }
        }
    }
}

/// Serves the URLs of a scheme registered with
/// ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``.
///
/// Chromium asks for responses on its IO thread; ``response(for:)`` runs
/// with the handler's own isolation, never blocking that thread:
///
/// - A plain `Sendable` handler runs on Swift's concurrent executor, where
///   many requests are answered at once. This suits handlers that compute
///   or look up a response.
/// - A handler isolated to ``CefIOActor`` runs on Chromium's IO thread
///   without a hop: for quick answers from state the handler keeps there,
///   such as an in-memory cache. It must not block.
/// - A handler isolated to the main actor can read your app's model:
///
/// ```swift
/// @MainActor
/// final class LibraryPages: CefSchemeHandler {
///     let library: Library
///     init(library: Library) { self.library = library }
///
///     func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
///         CefSchemeResponse(mimeType: "text/html", body: Data(library.html.utf8))
///     }
/// }
/// ```
///
/// Bodies are read as the page consumes them, wherever the handler runs:
/// files on ``CefFileActor``, streams in a task of their own.
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
/// ``indexFile``. Paths that lead outside ``directory`` are not found,
/// whether through `..`, ``indexFile`` or a symbolic link whose target
/// lies outside it; links within ``directory`` are followed. The
/// MIME type comes from the file extension. Files are read on
/// ``CefFileActor`` as the page consumes them, and range requests read only
/// the range, so large media files play and seek without being loaded.
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
        return CefSchemeResponse(
            status: 200,
            mimeType: Self.mimeType(forPathExtension: fileURL.pathExtension),
            body: .file(fileURL)
        )
    }

    /// The file under ``directory`` for a request path, or `nil`.
    ///
    /// The path is resolved completely, symbolic links and ``indexFile``
    /// included, before it is checked: a symbolic link may point anywhere
    /// inside ``directory``, and one whose target lies outside it is not
    /// found.
    func resolveFile(forRequestPath path: String) -> URL? {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = indexFile }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard var candidate = Self.resolve(root.appendingPathComponent(relative), within: root) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            guard let index = Self.resolve(candidate.appendingPathComponent(indexFile), within: root) else { return nil }
            candidate = index
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
        }
        return candidate
    }

    /// `url` with `.`, `..` and symbolic links resolved, when that is
    /// `root` or lies under it.
    private static func resolve(_ url: URL, within root: URL) -> URL? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { return nil }
        return resolved
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
