import CefSwiftUI
import SwiftUI

/// A profile makes the app's own requests the way its pages make theirs,
/// with its cookies, cache, proxy and Secure DNS: `data(for:)` for a whole
/// body, `bytes(for:)` for one that streams, `download(for:to:)` into a
/// file. `URLSession` shares none of that with Chromium.
struct RequestsDemo: Demo {
    let title = "Requests"
    let summary = "Requests from Swift through Chromium's network stack: JSON that shows the profile's cookie went along, a streamed body and a download to a file."
    let symbol = "network"
    let category = DemoCategory.network

    func makeView() -> some View { RequestsView() }
}

private struct Echo: Decodable {
    var method: String
    var headers: [String: String]
}

private struct RequestsView: View {
    @State private var log: [String] = []
    @State private var received: Int64 = 0
    private let profile = CefProfile.default
    private let server = LocalServer.shared

    var body: some View {
        Form {
            Section {
                Button("Fetch JSON") { perform(fetchJSON) }
                Button("Stream 4 MB") { perform(stream) }
                ProgressView(value: Double(received), total: Double(4 << 20))
                Button("Download to a File") { perform(download) }
            }
            Section("Results") {
                ForEach(log.indices.reversed(), id: \.self) { Text(log[$0]).font(.callout.monospaced()) }
            }
        }
        .formStyle(.grouped)
        .reportReady(after: fetchJSON)
    }

    /// A cookie set in the profile is sent with the profile's request.
    private func fetchJSON() async throws {
        let url = server.url(path: "echo.json")
        try await profile.setCookie(CefProfile.Cookie(name: "flavor", value: "oatmeal"), for: url)
        let (data, response) = try await profile.data(for: URLRequest(url: url))
        let echo = try JSONDecoder().decode(Echo.self, from: data)
        log.append("\(response.statusCode) \(echo.method) echo.json, Cookie: \(echo.headers["cookie"] ?? "none")")
    }

    private func stream() async throws {
        received = 0
        let (body, response) = try await profile.bytes(for: URLRequest(url: server.url(path: "stream?bytes=\(4 << 20)")))
        for try await chunk in body { received += Int64(chunk.count) }
        log.append("\(response.statusCode) streamed \(received.formatted(.byteCount(style: .memory)))")
    }

    private func download() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "gallery-request.bin")
        let response = try await profile.download(
            for: URLRequest(url: server.url(path: "stream?bytes=\(1 << 20)")), to: destination)
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        log.append("\(response.statusCode) saved \(size.formatted(.byteCount(style: .file))) to \(destination.lastPathComponent)")
    }

    private func perform(_ request: @escaping () async throws -> Void) {
        Task {
            do { try await request() } catch { log.append("✕ \(error)") }
        }
    }
}
