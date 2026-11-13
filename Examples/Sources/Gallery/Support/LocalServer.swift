import Foundation
import Network
import os

/// A small HTTP/1.1 server on 127.0.0.1, for demos that need real HTTP:
/// cookies, site permissions and passkeys belong to `http://localhost`
/// origins, which Chromium treats as secure. One request per connection.
///
/// - `/<path>`: the ``SamplePage`` at that path.
/// - `/echo.json`: the request's method and headers, as JSON.
/// - `/stream?bytes=<count>[&name=<file>]`: that many bytes, sent in parts
///   over about two seconds so that progress shows; with `name`, as an
///   attachment, which a browser downloads.
final class LocalServer: Sendable {
    /// Started on first use.
    static let shared = try! LocalServer()

    let port: UInt16
    private let listener: NWListener

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.receive(on: connection, buffer: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func url(path: String) -> URL {
        URL(string: "http://localhost:\(port)/\(path)")!
    }

    private static func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) {
                respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let target = URLComponents(string: String(parts[1])) else { return connection.cancel() }
        let query = Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
        switch target.path {
        case "/echo.json":
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let body = try! JSONSerialization.data(
                withJSONObject: ["method": String(parts[0]), "headers": headers], options: [.sortedKeys])
            send("200 OK", ["Content-Type": "application/json"], body, on: connection)
        case "/stream":
            let count = Int(query["bytes"] ?? "") ?? 1 << 20
            var headers = ["Content-Type": "application/octet-stream"]
            if let name = query["name"] { headers["Content-Disposition"] = "attachment; filename=\"\(name)\"" }
            send("200 OK", headers, length: count, on: connection)
            sendParts(remaining: count, part: max(1, count / 40), on: connection)
        default:
            if let page = SamplePages.page(at: String(target.path.dropFirst())) {
                send("200 OK", ["Content-Type": page.mimeType], page.body, on: connection)
            } else {
                send("404 Not Found", ["Content-Type": "text/plain"], Data("Not Found".utf8), on: connection)
            }
        }
    }

    private static func send(_ status: String, _ headers: [String: String], _ body: Data, on connection: NWConnection) {
        send(status, headers, length: body.count, on: connection)
        connection.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            close(connection)
        })
    }

    private static func send(_ status: String, _ headers: [String: String], length: Int, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(length)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    /// Closes the connection once the client has had time to read the
    /// response; the write side is closed already.
    private static func close(_ connection: NWConnection) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }

    /// The rest of a `/stream` body, a part every 50 ms.
    private static func sendParts(remaining: Int, part: Int, on connection: NWConnection) {
        guard remaining > 0 else {
            return connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { _ in close(connection) })
        }
        let size = min(part, remaining)
        connection.send(content: Data(repeating: 0x2A, count: size), completion: .contentProcessed { error in
            guard error == nil else { return connection.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                sendParts(remaining: remaining - size, part: part, on: connection)
            }
        })
    }
}
