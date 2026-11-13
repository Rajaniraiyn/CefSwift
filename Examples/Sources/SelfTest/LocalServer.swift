import Foundation
import Network
import os

/// A local HTTP/1.1 server on 127.0.0.1. One request per connection, read
/// whole (headers and `Content-Length` body):
///
/// - `/echo`: the request body back, with the method, `Cookie`,
///   `Content-Type`, `Referer` and `Accept-Language` in `X-Echo-*` headers,
///   and `X-Multi` twice.
/// - `/status?<code>`: that status, body `teapot`.
/// - `/set-cookie`: sets `fromRequest=yes`.
/// - `/page`: a page titled `page`, with a link to itself.
/// - `/ping-page`: a link that pings `/ping`, which answers 204.
/// - `/accept-language`: a page titled with the request's `Accept-Language`.
/// - `/passkeys…`: `PasskeyChecks.page`.
/// - `….txt`: an attachment.
/// - `/redirect`: 302 to `/echo?redirected`.
/// - `/redirect-page`: 302 to `/page`.
/// - `/private`: wants Basic `ada:lovelace` (realm `selftest`); titled
///   `authorized` or `denied`.
/// - `/large?<bytes>`: that many bytes, sent as the client takes them.
/// - `/slow`: headers and 1 KB of a 1 MB body, then nothing until the
///   client closes the connection.
/// - As a proxy (an absolute target), it wants Basic `grace:hopper` (realm
///   `selftest-proxy`), then answers a page titled `proxied`.
final class LocalServer: Sendable {
    /// What `/private` answers with the right credentials.
    static let authorized = "<title>authorized</title>ok"

    private struct Log {
        var requestLines: [String] = []
        var slowRequests: [String] = []
        var closedSlowConnections = 0
    }

    private let listener: NWListener
    let port: UInt16
    private let log: OSAllocatedUnfairLock<Log>

    private init(listener: NWListener, port: UInt16, log: OSAllocatedUnfairLock<Log>) {
        self.listener = listener
        self.port = port
        self.log = log
    }

    /// The first line of each request received, such as `POST /ping HTTP/1.1`.
    var requestLines: [String] { log.withLock { $0.requestLines } }
    /// The paths of `/slow` requests received.
    var slowRequests: [String] { log.withLock { $0.slowRequests } }
    /// How many `/slow` connections the client has closed.
    var closedSlowConnections: Int { log.withLock { $0.closedSlowConnections } }

    static func start() async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let log = OSAllocatedUnfairLock(initialState: Log())
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            receive(on: connection, buffer: Data(), log: log)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let value: Result<UInt16, any Error>?
                switch state {
                case .ready: value = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): value = .failure(error)
                default: value = nil
                }
                guard let value, resumed.withLock({ resumed in defer { resumed = true }; return !resumed }) else { return }
                continuation.resume(with: value)
            }
            listener.start(queue: .global())
        }
        return LocalServer(listener: listener, port: port, log: log)
    }

    func stop() {
        listener.cancel()
    }

    private struct Request {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data

        var path: String { String(target.prefix { $0 != "?" }) }
        var query: String { target.firstIndex(of: "?").map { String(target[target.index(after: $0)...]) } ?? "" }

        /// The request in `data`, once all of it has arrived.
        init?(_ data: Data) {
            guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard data.count - (end.upperBound - data.startIndex) >= length else { return nil }
            method = String(parts[0])
            target = String(parts[1])
            self.headers = headers
            body = Data(data[end.upperBound..<(end.upperBound + length)])
        }
    }

    private static func receive(on connection: NWConnection, buffer: Data, log: OSAllocatedUnfairLock<Log>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                log.withLock { $0.requestLines.append("\(request.method) \(request.target) HTTP/1.1") }
                respond(to: request, on: connection, log: log)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer, log: log)
            }
        }
    }

    private static func respond(to request: Request, on connection: NWConnection, log: OSAllocatedUnfairLock<Log>) {
        var status = "200 OK"
        var headers: [(String, String)] = []
        var body = Data()
        func html(_ text: String) {
            headers = [("Content-Type", "text/html")]
            body = Data(text.utf8)
        }
        func basic(_ credentials: String) -> String { "Basic \(Data(credentials.utf8).base64EncodedString())" }
        if request.target.hasPrefix("http://") {
            if request.headers["proxy-authorization"] == basic("grace:hopper") {
                html("<title>proxied</title>ok")
            } else {
                status = "407 Proxy Authentication Required"
                html("<title>proxy denied</title>denied")
                headers.append(("Proxy-Authenticate", "Basic realm=\"selftest-proxy\""))
            }
            return send(status: status, headers: headers, body: body, on: connection)
        }
        switch request.path {
        case "/echo":
            headers = [
                ("Content-Type", "application/octet-stream"),
                ("X-Echo-Method", request.method),
                ("X-Echo-Cookie", request.headers["cookie"] ?? ""),
                ("X-Echo-Content-Type", request.headers["content-type"] ?? ""),
                ("X-Echo-Referer", request.headers["referer"] ?? ""),
                ("X-Echo-Accept-Language", request.headers["accept-language"] ?? ""),
                ("X-Multi", "a"), ("X-Multi", "b"),
            ]
            body = request.body
        case "/status":
            status = "\(request.query) Status"
            body = Data("teapot".utf8)
        case "/set-cookie":
            headers = [("Set-Cookie", "fromRequest=yes; Path=/")]
            body = Data("set".utf8)
        case "/page":
            html("<title>page</title><p>A page on http, which Chrome's QR code generator accepts.</p>"
                 + "<p>Another page, then a third page.</p><p><a id=link href=/page>A link</a></p>")
        case "/ping-page":
            html("<title>ping-page</title><a id=link ping=/ping href=/page>A link that pings</a>")
        case "/ping":
            status = "204 No Content"
        case "/accept-language":
            html("<title>accept-language \(request.headers["accept-language"] ?? "")</title>")
        case let path where path.hasPrefix("/passkeys"):
            html(PasskeyChecks.page)
        case let path where path.hasSuffix(".txt"):
            headers = [("Content-Type", "text/plain"),
                       ("Content-Disposition", "attachment; filename=\"\(path.dropFirst())\"")]
            body = Data(String(repeating: "CefSwift\n", count: 2048).utf8)
        case "/redirect":
            status = "302 Found"
            headers = [("Location", "/echo?redirected")]
        case "/redirect-page":
            status = "302 Found"
            headers = [("Location", "/page")]
        case "/private":
            if request.headers["authorization"] == basic("ada:lovelace") {
                html(authorized)
            } else {
                status = "401 Unauthorized"
                html("<title>denied</title>denied")
                headers.append(("WWW-Authenticate", "Basic realm=\"selftest\""))
            }
        case "/large":
            let size = Int(request.query) ?? 0
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                sendLarge(remaining: size, on: connection)
            })
            return
        case "/slow":
            log.withLock { $0.slowRequests.append(request.target) }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + Data(count: 1024), completion: .contentProcessed { _ in })
            // Counts the client closing the connection.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                if isComplete || error != nil { log.withLock { $0.closedSlowConnections += 1 } }
                connection.cancel()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { connection.cancel() }
            return
        default:
            status = "404 Not Found"
        }
        send(status: status, headers: headers, body: body, on: connection)
    }

    private static func send(status: String, headers: [(String, String)], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        // Close the write side after the response; the client closes the rest.
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in
                            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { connection.cancel() }
                        })
    }

    private static let chunk = Data((0..<(256 << 10)).map { UInt8($0 % 251) })

    /// Sends the next part of a `/large` body once the last one has gone.
    private static func sendLarge(remaining: Int, on connection: NWConnection) {
        guard remaining > 0 else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { connection.cancel() }
            })
            return
        }
        let part = remaining >= chunk.count ? chunk : chunk.prefix(remaining)
        connection.send(content: part, completion: .contentProcessed { error in
            guard error == nil else { return connection.cancel() }
            sendLarge(remaining: remaining - part.count, on: connection)
        })
    }
}
